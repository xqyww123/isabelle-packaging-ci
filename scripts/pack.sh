#!/usr/bin/env bash
#
# build.yml's `conda` job: turn an official platform bundle into a conda package.
#
#   ISA_RELEASE=Isabelle2026 ISA_BUILD_NUMBER=0 \
#   pack.sh --subdir linux-64 \
#           --bundle  <Isabelle2026_linux.tar.gz | Isabelle2026.exe | a directory> \
#           --out     <output dir for the .conda file>
#
#   ISA_RELEASE=Isabelle2026 pack.sh --conda-version      prints the conda version, 2026
#
# It runs entirely on Linux, for every target platform -- including win-64: nothing
# here compiles anything; we only move files and zip them up.  The bundle's own
# Pure/HOL heaps ship as they are.  Every change this script makes to the official tree
# is one of those scripts/check_pristine.py allows, and the script checks the finished
# package against the tree as it was unpacked.

set -euo pipefail

SUBDIR="" BUNDLE="" OUT="" PRINT_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --subdir) SUBDIR="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --out)    OUT="$2";    shift 2 ;;
    --conda-version) PRINT_VERSION=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

RELEASE="${ISA_RELEASE:?ISA_RELEASE is not set (e.g. Isabelle2026)}"
# conda versions cannot contain '-':  Isabelle2026 -> 2026,  Isabelle2025-2 -> 2025.2
VERSION="${RELEASE#Isabelle}"; VERSION="${VERSION//-/.}"
[ -z "$PRINT_VERSION" ] || { echo "$VERSION"; exit 0; }

for v in SUBDIR BUNDLE OUT; do
  [ -n "${!v}" ] || { echo "::error::--${v,,} is required" >&2; exit 2; }
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFICIAL_ID_FILE="$HERE/../releases/$RELEASE/ISABELLE_ID"
[ -f "$OFFICIAL_ID_FILE" ] || { echo "::error::$RELEASE is not registered: no releases/$RELEASE/ISABELLE_ID (RELEASE.md, step 0)"; exit 1; }
PYTHON="${PYTHON:-python3}"           # needs zstandard (or Python >= 3.14) for check_pristine.py
WORK="${WORK:-$(mktemp -d)}"
STAGE="$WORK/stage"

echo "=============================================================="
echo " subdir  : $SUBDIR"
echo " bundle  : $BUNDLE"
echo " release : $RELEASE"
echo " work    : $WORK"
echo "=============================================================="

# ---------------------------------------------------------------------------
# 1. unpack the bundle  ->  $STAGE/<release>/
# ---------------------------------------------------------------------------
rm -rf "$STAGE"; mkdir -p "$STAGE"
# Say so plainly if the bundle is not there.  Otherwise a missing bundle surfaces as a
# bare `tar: Error is not recoverable: exiting now` (exit 2), which tells whoever reads
# the CI log nothing about what actually went wrong.
if [ ! -f "$BUNDLE" ] && [ ! -d "$BUNDLE" ]; then
  echo "::error::bundle not found: $BUNDLE"
  echo "          (is it listed in releases/$RELEASE/SHA256SUMS?)"
  exit 1
fi
case "$BUNDLE" in
  *.tar.gz)
    tar xzf "$BUNDLE" -C "$STAGE"
    ;;
  *.exe)
    # The Windows bundle is a 7z self-extracting archive: sfx stub + config + a 7z
    # archive of the whole tree (Isabelle's build_release.scala).  7-Zip reads it directly.
    #
    # Do NOT hard-code `7zz`.  That is upstream 7-Zip's (and conda-forge's) name for the
    # binary; Debian/Ubuntu's `7zip` package installs it as `7z`.  Hard-coding 7zz made
    # this line die with "command not found" on ubuntu-latest AFTER the other four
    # packages had already been built.  Accept either name.
    SEVENZIP=$(command -v 7zz || command -v 7z) || {
      echo "::error::no 7-Zip binary found (tried 7zz and 7z)"; exit 1; }
    echo "7-Zip: $SEVENZIP"
    "$SEVENZIP" x -y -o"$STAGE" "$BUNDLE" > "$WORK/7z.log" || { tail -40 "$WORK/7z.log"; exit 1; }
    ;;
  *)
    [ -d "$BUNDLE" ] || { echo "::error::$BUNDLE is neither .tar.gz, .exe, nor a directory"; exit 1; }
    cp -a "$BUNDLE" "$STAGE/$(basename "$BUNDLE")"
    ;;
esac

# The tree is ISABELLE_HOME, which becomes isa/.  On macOS that is the Contents/Resources/
# of the app; the rest of the app (its launcher, Info.plist, and top-level symlinks into
# Contents/Resources/) stays out -- conda users start Isabelle with `isabelle`, not the app.
TREE="$STAGE/$RELEASE"
[ -d "$TREE" ] || TREE="$STAGE/$RELEASE.app/Contents/Resources"
[ -d "$TREE" ] || { echo "::error::no $RELEASE tree in the unpacked bundle"; ls -la "$STAGE"; exit 1; }
echo "tree: $TREE"

OFFICIAL_ID="$(cat "$OFFICIAL_ID_FILE")"
ISA_ID="$(cat "$TREE/etc/ISABELLE_ID")"
[ "$ISA_ID" = "$OFFICIAL_ID" ] || {
  echo "::error::etc/ISABELLE_ID is $ISA_ID, but the official $RELEASE changeset is $OFFICIAL_ID"; exit 1; }
echo "ISABELLE_ID = $ISA_ID (the official $RELEASE changeset)"

# The official tree as unpacked, for the check at the end.
OFFICIAL_MANIFEST="$WORK/official-$SUBDIR.json"
"$PYTHON" "$HERE/check_pristine.py" manifest "$TREE" "$OFFICIAL_MANIFEST"

# The bundle's prebuilt heaps, which ship as they are.  heaps/<ML_ID>/log/<S>.db is NOT
# a build log -- it is the session database, and `isabelle build` decides whether a
# session is finished-and-current by looking it up there, not by the heap file's
# existence.  A package carrying only the heap files once installed fine and then
# recompiled the whole of HOL on its first real build.
n=0
for hd in "$TREE"/heaps/*/; do
  [ -d "$hd" ] || continue
  for s in Pure HOL; do
    [ -f "$hd/$s" ] && [ -f "$hd/log/$s.db" ] || { echo "::error::no $s heap with its session db in $hd"; exit 1; }
  done
  echo "heaps: $(basename "$hd") (HOL $(stat -c %s "$hd/HOL") bytes)"
  n=$((n + 1))
done
[ "$n" -eq 1 ] || { echo "::error::expected one heaps/<ML_IDENTIFIER>/ in the bundle, found $n"; exit 1; }

# ---------------------------------------------------------------------------
# 1a. Remember the bundle's EMPTY directories, while the tree is still pristine.
#
# A conda payload carries FILES ONLY -- no directory entries (measured: 28706
# entries in our win-64 package, every one of them a regular file).  conda creates
# a directory only as the parent of some file it is unpacking, so every empty
# directory in the official bundle silently disappears on install.  For Cygwin that
# means /tmp, /var/tmp, /dev/shm, /home and the rebase state dirs are simply gone,
# and every `isabelle` call greets the user with
#     bash.exe: warning: could not find /tmp
# We put them back at step 2 by dropping a marker file in each.  Recorded here, before
# any step changes the tree, so that step 2 restores exactly the officially empty ones.
# ---------------------------------------------------------------------------
EMPTY_DIRS="$WORK/empty_dirs.txt"
( cd "$TREE" && find . -type d -empty | sed 's|^\./||' | sort ) > "$EMPTY_DIRS"
echo "empty directories in the pristine bundle: $(wc -l < "$EMPTY_DIRS")"

# ---------------------------------------------------------------------------
# 1b. Windows: install the real launcher at <ISABELLE_HOME>\bin\isabelle.bat.
#
# bin/isabelle is a Cygwin bash script and cmd.exe cannot run it, so without this the
# package has NO working entry point on Windows: $PREFIX\Scripts\isabelle.bat (written
# by the recipe) forwards here and would resolve to nothing.
#
# Copied BYTE FOR BYTE from windows/isabelle.bat, which was verified on a real Windows
# VM: it self-locates ISABELLE_HOME from %~dp0.. (so it survives being installed into an
# arbitrary conda $PREFIX), does not recurse into itself, and detaches a GUI `jedit` into
# its own hidden console.  Do not "improve" it here.
#
# Cygwin needs no help from us: build_release strips the symlinks and leaves an
# `uninitialized` marker, but the FIRST `isabelle` call restores them by itself --
# lib/scripts/getsettings:118 runs isabelle.setup.Setup on every invocation, which calls
# Environment.init -> cygwin_init.  Measured on the VM: 947 symlinks missing before,
# all present after one `isabelle version` (88s, rc=0), marker gone.  No post-link needed.
# ---------------------------------------------------------------------------
if [ "$SUBDIR" = win-64 ]; then
  BAT="$HERE/../windows/isabelle.bat"
  [ -f "$BAT" ] || { echo "::error::$BAT is missing -- the win-64 package would have no entry point"; exit 1; }
  cp "$BAT" "$TREE/bin/isabelle.bat"
  cmp -s "$BAT" "$TREE/bin/isabelle.bat" || { echo "::error::isabelle.bat was altered in transit"; exit 1; }
  echo "installed bin/isabelle.bat ($(stat -c %s "$TREE/bin/isabelle.bat") bytes, sha256 $(sha256sum "$TREE/bin/isabelle.bat" | cut -c1-16))"
fi

# ---------------------------------------------------------------------------
# 1c. Isolate ISABELLE_HOME_USER per conda environment.
#
# Stock etc/settings puts USER state -- config, component registrations and
# on-demand-built session heaps -- in ~/.isabelle/<release>, which is SHARED with any
# stock Isabelle of that release and with every other conda env.  Feature packages patch
# an env's isa/ in place, so a heap built in one env is not interchangeable with another's,
# and `isabelle process` does not check sources against a heap; the isabelle pre-unlink
# deletes the directory, so sharing it would also let one env's reinstall wipe another's.
# We append `-conda-<env>-<hash>`: <env> is the prefix's last component, readable, and
# <hash> is the CRC of the whole prefix path (`cksum`: POSIX, also in Isabelle's Cygwin),
# so ~/a/env and ~/b/env do not collide.  Both are derived from the install prefix
# ($ISABELLE_HOME = <prefix>/isa), so it is correct even without `conda activate`.
#
# Only ISABELLE_HOME_USER is touched: ISABELLE_HEAPS and everything else keyed off it are
# set AFTER it in etc/settings and follow along (the lines between are ISABELLE_TOOLS
# and ISABELLE_TMP_PREFIX, neither of which reads it -- verified).  ISABELLE_NAME and the
# rest of the identity stay "<release>".  The base pre-unlink (recipe.yaml) removes
# this directory on `conda remove`.
# ---------------------------------------------------------------------------
SETTINGS="$TREE/etc/settings"
HEAPS_LINE='ISABELLE_HEAPS="$ISABELLE_HOME_USER/heaps"'
USER_LINE='ISABELLE_HOME_USER="${ISABELLE_HOME_USER}-conda-$(basename "$(dirname "$ISABELLE_HOME")")-$(printf %08x "$(printf %s "$(dirname "$ISABELLE_HOME")" | cksum | cut -d" " -f1)")"'
grep -q -- '-conda-' "$SETTINGS" && { echo "::error::etc/settings already carries the conda HOME_USER patch"; exit 1; }
grep -q -x -F "$HEAPS_LINE" "$SETTINGS" || {
  echo "::error::etc/settings anchor '$HEAPS_LINE' not found -- upstream layout changed, re-check the patch"; exit 1; }
awk -v heaps="$HEAPS_LINE" -v user="$USER_LINE" '$0 == heaps { print user } { print }' "$SETTINGS" > "$WORK/settings"
cat "$WORK/settings" > "$SETTINGS"
echo "patched etc/settings: ISABELLE_HOME_USER -> ~/.isabelle/${RELEASE}-conda-<env>-<hash>"

# ---------------------------------------------------------------------------
# 1d. Unregister the dead bundled nunchaku component.
#
# The distribution ships contrib/nunchaku-0.5-1, still the 2017 binary (self-reported
# 0.1), whose --solvers knows cvc4, kodkod, paradox and smbc but not cvc5.  Nunchaku is
# not supported in our packages (owner, 2026-10-31), so we unregister it.  The directory
# itself stays -- unregistered, it is inert, and the tree keeps the official files.
# ---------------------------------------------------------------------------
COMPONENTS="$TREE/etc/components"
NUNCHAKU_LINE='contrib/nunchaku-0.5-1'
grep -q 'nunchaku' "$COMPONENTS" || { echo "::error::etc/components already lacks the nunchaku registration -- patch applied twice?"; exit 1; }
grep -q -x -F "$NUNCHAKU_LINE" "$COMPONENTS" || {
  echo "::error::etc/components anchor '$NUNCHAKU_LINE' not found -- upstream layout changed, re-check the patch"; exit 1; }
grep -v -x -F "$NUNCHAKU_LINE" "$COMPONENTS" > "$WORK/components"
cat "$WORK/components" > "$COMPONENTS"
echo "patched etc/components: dropped the $NUNCHAKU_LINE registration"

# ---------------------------------------------------------------------------
# 1e. Drop the libtool archives (*.la).
#
# rattler-build leaves every *.la out of a package anyway (conda's convention: they
# record absolute build paths, here the upstream build machine's temp dir).  Nothing
# reads them at run time -- they describe libraries for linking other programs against
# (Poly/ML's static libpolyml.a, Cygwin's SASL plugins, whose DLLs stay).  Dropping them
# here makes the staged tree exactly what ships, which step 3 relies on.
# ---------------------------------------------------------------------------
n_la=$(find "$TREE" -type f -name '*.la' -print -delete | wc -l)
echo "dropped $n_la libtool archive(s) (*.la)"

# ---------------------------------------------------------------------------
# 2. Put the empty directories back (see 1a).
#
# conda only creates a directory as the parent of a file it unpacks, so the only way to
# ship an empty one is to make it non-empty.  An EMPTY marker file does that, and unlike
# a post-link `mkdir` it is TRACKED: it shows up in `conda list --explicit`, and
# `conda remove` takes it away again (PACKAGING_DESIGN.md §3.1).  Every directory that
# gets one ignores it, the Cygwin rebase state dirs included: rebaselst reads each file
# there as a list of paths and skips empty content (rebaselst:47-48, 54-55).
# ---------------------------------------------------------------------------
n_dirs=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  mkdir -p "$TREE/$d"
  : > "$TREE/$d/.conda-keep"
  n_dirs=$((n_dirs + 1))
done < "$EMPTY_DIRS"
echo "restored $n_dirs empty directory(ies) via .conda-keep markers"

# ---------------------------------------------------------------------------
# 3. Windows: Cygwin's permission lists name only what ships.
#
# On the first `isabelle` call, Isabelle's Cygwin runs contrib/cygwin/isabelle/postinstall,
# which under `set -e` runs setfacl/chmod on every path in permissions/*.gz -- lists of
# every directory and file of the official tree (each one there, measured).  A listed
# path the package lacks (the *.la of 1e) fails it, and with it the user's first call.
# So each list keeps only what ships (owner, 2026-10-31).
# ---------------------------------------------------------------------------
if [ "$SUBDIR" = win-64 ]; then
  "$PYTHON" "$HERE/check_pristine.py" permissions "$TREE"
fi

# ---------------------------------------------------------------------------
# 4. MAX_PATH.  Assert, do not assume.
#
# Windows' MAX_PATH is 259 usable characters, LongPathsEnabled is 0 by default on
# Windows 11, and turning it on needs admin + a reboot.  It cannot be worked around from
# inside the package either: `conda create` fails while unpacking into the pkgs cache,
# long before any post-link script could run.  Measured on Isabelle2025-2, under the
# package's old opt/Isabelle2025-2/ root:
#     InvalidArchiveError ... node_addon_api_except.lastbuildstate   (262 chars)
#
# conda lays the payload down at   <pkgs>\<name>-<version>-<build>\<path-in-package>
# so the assertion is on that whole path, for
#     C:\Users\<20 characters>\AppData\Local\miniconda3\pkgs\isabelle-<version>-<build>\
# -- a Windows local account name maxes out at 20 -- so that every normal user installs
# without touching the registry.  The budget for <path-in-package> follows from the
# version and build number: 181 for isabelle-2025.2-0, 183 for isabelle-2026-0..9,
# 182 for isabelle-2026-10..99.  Isabelle2026's own VSCodium has a 182-character path in
# it, so 2026 fits with a margin of one character, or none from build 10 on; the owner
# accepted that (2026-10-31).
#
# ENFORCED FOR win-64 ONLY.  Measured and printed for every platform, but only Windows
# can fail on it, because only Windows has the limit: PATH_MAX is 1024 on macOS and 4096
# on Linux.
#
# An earlier revision of this script enforced 180 everywhere, on the theory that "a
# regression that only bites Windows is one we would not notice".  That reasoning is
# wrong, and it broke the build: the macOS bundle nests VSCodium inside an app bundle
#     isa/contrib/vscodium-.../x86_64-darwin/VSCodium.app/Contents/Resources/vscodium/...
# which is ~20 characters deeper than the Windows layout's .../resources/vscodium/...,
# so osx-64 measured 201 and the packaging job went red on a package that is perfectly fine on macOS.
# The premise was false anyway: win-64 is built and asserted in this very same job, so a
# Windows regression is caught on win-64 itself.  Do not "restore" the global check.
# ---------------------------------------------------------------------------
# NB: `sed -n 1p`, never `head -1`.  Under `set -o pipefail`, `head` closes the pipe
# after one line, `sort` (28k lines) dies of SIGPIPE=141, and the whole script exits --
# silently, right here, with the package never built.  `sed -n` reads its input to the end.
ISA_BUILD_NUMBER="${ISA_BUILD_NUMBER:?ISA_BUILD_NUMBER is not set}"
PKGS_DIR='C:\Users\12345678901234567890\AppData\Local\miniconda3\pkgs\'"isabelle-$VERSION-$ISA_BUILD_NUMBER\\"
MAX_REL=$(( 259 - ${#PKGS_DIR} ))
path_lengths() {
  ( cd "$TREE" && find . -mindepth 1 | sed 's|^\./||' \
      | awk -v p="isa/" '{ print length(p $0), p $0 }' | sort -rn )
}
longest=$(path_lengths | sed -n 1p)
longest_len=${longest%% *}
longest_path=${longest#* }

if [ "$SUBDIR" = win-64 ]; then
  echo "longest path in the package: $longest_len chars (budget $MAX_REL under $PKGS_DIR, ENFORCED for win-64)"
  echo "  $longest_path"
  echo "  so an environment prefix (and a pkgs dir) may be up to $(( 259 - longest_len )) characters, incl. its trailing backslash"
  if [ "$longest_len" -gt "$MAX_REL" ]; then
    echo "::error::longest in-package path is $longest_len characters, over the $MAX_REL limit under $PKGS_DIR."
    echo "          Windows (MAX_PATH=259, long paths off by default) will fail to unpack this."
    echo "          The ten longest:"
    path_lengths | sed -n 1,10p | while read -r l q; do echo "::error::  $l  $q"; done
    exit 1
  fi
  echo "  OK: within the $MAX_REL-character budget"
else
  # Informational only.  There is no path-length limit worth enforcing on this platform.
  echo "longest path in the package: $longest_len chars (not enforced -- $SUBDIR has no MAX_PATH)"
  echo "  $longest_path"
fi

# ---------------------------------------------------------------------------
# 5. conda package
# ---------------------------------------------------------------------------
# The official changeset (checked above) does not go into the build string -- every
# character there costs us MAX_PATH on Windows (recipe.yaml); it is carried in the
# package's about.description, and in the tree itself at isa/etc/ISABELLE_ID.
mkdir -p "$OUT"
export ISA_STAGE="$TREE"
export ISA_RELEASE="$RELEASE"
export ISA_VERSION="$VERSION"
export ISA_ID
export ISA_BUILD_NUMBER

# --test native: run the recipe's tests only when the target IS this machine.
#
# The default (native-and-emulated) runs them for EVERY target, which is wrong in both
# directions when cross-packaging from Linux:
#   win-64  -> the test takes the non-unix branch, `isabelle.bat version`, which exits
#              127 on a Linux builder; rattler-build then quarantines a perfectly good
#              package into <output-dir>/broken/.
#   osx-*   -> the test takes the unix branch and PASSES, but it passed by running the
#              macOS package's bash script on Linux.  A false pass is worse than no test.
# Only linux-64 can be honestly tested here, and the `conda` job does that far more
# thoroughly anyway: it installs from a local channel and builds a real session.
rattler-build build \
  --recipe "$HERE/../conda/recipe.yaml" \
  --target-platform "$SUBDIR" \
  --output-dir "$OUT" \
  --no-build-id \
  --test native

PACKAGE="$OUT/$SUBDIR/isabelle-$VERSION-$ISA_BUILD_NUMBER.conda"
[ -f "$PACKAGE" ] || { echo "::error::rattler-build did not produce $PACKAGE"; find "$OUT" -name '*.conda'; exit 1; }
echo "=== produced: $PACKAGE ($(stat -c %s "$PACKAGE") bytes) ==="

# ---------------------------------------------------------------------------
# 6. The package's isa/ is the official tree plus the changes above, nothing else.
# ---------------------------------------------------------------------------
"$PYTHON" "$HERE/check_pristine.py" compare "$SUBDIR" "$OFFICIAL_MANIFEST" "$PACKAGE"
