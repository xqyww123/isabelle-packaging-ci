#!/usr/bin/env bash
#
# Job F: replace the heaps of an official platform bundle with the natively-built ones
# and turn the result into a conda package.
#
#   ISA_RELEASE=Isabelle2026 ISA_BUILD_NUMBER=0 \
#   pack.sh --subdir linux-64 \
#           --bundle  <Isabelle2026_linux.tar.gz | Isabelle2026.exe | a directory> \
#           --heaps   <dir containing one <ML_IDENTIFIER>/ dir> \
#           --out     <output dir for the .conda file>
#
# It runs entirely on Linux, for every target platform -- including win-64: nothing
# here compiles anything; we only move files and zip them up.  Every change it makes to
# the official tree is one of those scripts/check_pristine.py allows, and the script
# checks the finished package against the tree as it was unpacked.
#
# The heap artifact is copied WHOLESALE: the <ML_IDENTIFIER>/ directory the heap job
# produced goes into the bundle's heaps/.  No platform->ML_IDENTIFIER mapping is
# hard-coded anywhere -- `isabelle getenv ML_IDENTIFIER` prints nothing (it is computed
# Scala-side, PACKAGING_DESIGN.md §5.1.1), so the directory name is the only source of
# truth and we simply propagate it.

set -euo pipefail

SUBDIR="" BUNDLE="" HEAPS="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --subdir) SUBDIR="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --heaps)  HEAPS="$2";  shift 2 ;;
    --out)    OUT="$2";    shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
for v in SUBDIR BUNDLE HEAPS OUT; do
  [ -n "${!v}" ] || { echo "::error::--${v,,} is required" >&2; exit 2; }
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="${ISA_RELEASE:?ISA_RELEASE is not set (e.g. Isabelle2026)}"
OFFICIAL_ID_FILE="$HERE/../releases/$RELEASE/ISABELLE_ID"
[ -f "$OFFICIAL_ID_FILE" ] || { echo "::error::$RELEASE is not registered: no releases/$RELEASE/ISABELLE_ID"; exit 1; }
# conda versions cannot contain '-':  Isabelle2026 -> 2026,  Isabelle2025-2 -> 2025.2
VERSION="${RELEASE#Isabelle}"; VERSION="${VERSION//-/.}"
PYTHON="${PYTHON:-python3}"           # needs zstandard (or Python >= 3.14) for check_pristine.py
WORK="${WORK:-$(mktemp -d)}"
STAGE="$WORK/stage"

echo "=============================================================="
echo " subdir  : $SUBDIR"
echo " bundle  : $BUNDLE"
echo " heaps   : $HEAPS"
echo " release : $RELEASE"
echo " work    : $WORK"
echo "=============================================================="

# ---------------------------------------------------------------------------
# 1. unpack the bundle  ->  $STAGE/<release>/
# ---------------------------------------------------------------------------
rm -rf "$STAGE"; mkdir -p "$STAGE"
# Say so plainly if the bundle is not there.  Otherwise a missing/failed Job A artifact
# surfaces as a bare `tar: Error is not recoverable: exiting now` (exit 2), which tells
# whoever reads the CI log nothing about what actually went wrong.
if [ ! -f "$BUNDLE" ] && [ ! -d "$BUNDLE" ]; then
  echo "::error::bundle not found: $BUNDLE"
  echo "          (is the Job A artifact for this platform missing from the download?)"
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

# The official bundle ships 32-bit-word heaps (x86_64_32-*, arm64_32-*); ours are the
# 64-bit ones (1e), built by Jobs B-E.  Drop the official ones.
for d in "$TREE"/heaps/*/; do
  [ -d "$d" ] || continue
  echo "removing the official heaps $(basename "$d")"
  rm -rf "$d"
done

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
# We put them back at step 5 by dropping a marker file in each.
#
# Recorded HERE, before the obj/ purge below, on purpose: purging obj/ leaves its
# parent directories empty, and those we do NOT want to resurrect -- they are build
# scaffolding, and they sit at exactly the deep paths we are trying to shorten.
# ---------------------------------------------------------------------------
EMPTY_DIRS="$WORK/empty_dirs.txt"
( cd "$TREE" && find . -type d -empty | sed 's|^\./||' | sort ) > "$EMPTY_DIRS"
echo "empty directories in the pristine bundle: $(wc -l < "$EMPTY_DIRS")"

# ---------------------------------------------------------------------------
# 1b. Drop VSCodium's MSBuild scratch (**/obj/**).
#
# node-pty's native addon ships its incremental-build state -- .tlog files and
# .lastbuildstate -- next to the compiled .node binary.  Nothing reads them at run
# time; they exist to let MSBuild skip work on a rebuild that will never happen here.
# They also own the single longest path in the bundle, at 212 characters, which is
# what actually broke `conda create` on Windows.  The compiled binary itself lives in
# Release/, not Release/obj/, and stays.
#
# We do NOT touch anything else in the Isabelle tree, and VSCodium itself stays --
# deleting it was considered and rejected: VS Code is the mainstream front end.
# ---------------------------------------------------------------------------
n_obj=0
while IFS= read -r d; do
  rm -rf "$d"; n_obj=$((n_obj + 1))
done < <(find "$TREE/contrib" -type d -name obj -path '*vscodium*' 2>/dev/null)
echo "purged $n_obj VSCodium obj/ directory(ies)"

# ---------------------------------------------------------------------------
# 1c. Windows: install the real launcher at <ISABELLE_HOME>\bin\isabelle.bat.
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
# 1d. Isolate ISABELLE_HOME_USER per conda environment.
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
# 1e. Default to 64-bit Poly/ML words (ML_system_64 = true).
#
# Stock Isabelle defaults ML_system_64 to false, i.e. the 31-bit-word Poly/ML
# (x86_64_32).  The AoA stack is developed and run on 64-bit words -- the user's own
# dev profile sets ML_system_64 = true in $ISABELLE_HOME_USER/etc/preferences -- and
# some of its ML does not fit 31-bit words (e.g. Performant_Isabelle_ML's Knuth hash
# constant 0x9E3779B9 overflowed there).
#
# This flip must move IN LOCKSTEP with the heap jobs: build.yml builds the heaps with
# `-o ML_system_64=true` (the x86_64-* / arm64-* variant), and this patch makes the
# runtime default select that variant.  Only ONE word-size heap ships per platform --
# flipping this default WITHOUT the matching 64-bit heap would point Isabelle at an
# absent dir and rebuild HOL on first use.  Covers `isabelle build` and jEdit alike.
# ---------------------------------------------------------------------------
OPTIONS="$TREE/etc/options"
grep -q '^public option ML_system_64 : bool = true' "$OPTIONS" && { echo "::error::etc/options ML_system_64 already true"; exit 1; }
grep -q '^public option ML_system_64 : bool = false' "$OPTIONS" || {
  echo "::error::etc/options anchor 'option ML_system_64 : bool = false' not found -- upstream layout changed"; exit 1; }
sed -i 's/^public option ML_system_64 : bool = false/public option ML_system_64 : bool = true/' "$OPTIONS"
echo "patched etc/options: ML_system_64 default -> true (64-bit words)"

# ---------------------------------------------------------------------------
# 1f. Unregister the dead bundled nunchaku component.
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
# 2. inject the heaps
# ---------------------------------------------------------------------------
mkdir -p "$TREE/heaps"
n=0
for d in "$HEAPS"/*/; do
  id="$(basename "$d")"
  echo "  injecting ML_IDENTIFIER = $id"
  cp -a "$d" "$TREE/heaps/$id"
  n=$((n + 1))
done
[ "$n" -eq 1 ] || { echo "::error::expected one <ML_IDENTIFIER>/ directory under $HEAPS, found $n"; ls -la "$HEAPS"; exit 1; }

echo "--- heaps now in the tree ---"
find "$TREE/heaps" -type f -printf '  %-64p %s bytes\n' | sed "s|$TREE/||"

for hd in "$TREE"/heaps/*/; do
  id="$(basename "$hd")"

  # a HOL heap is a few hundred MB; anything tiny means we injected the wrong thing
  h="$hd/HOL"
  [ -f "$h" ] || { echo "::error::no HOL heap in $id"; exit 1; }
  sz=$(stat -c %s "$h")
  [ "$sz" -gt 100000000 ] || { echo "::error::HOL heap $h is only $sz bytes"; exit 1; }

  # ---------------------------------------------------------------------------
  # log/*.db is NOT a build log -- it is the session DATABASE, and it must ship.
  #
  # Found the hard way: a package carrying only the heap files installs fine and
  # `isabelle version` works, but the first real build says "Building HOL ..." and
  # recompiles the whole of HOL (~20 min), because `isabelle build` decides whether
  # a session is finished-and-current by looking it up in heaps/<ML_ID>/log/<S>.db,
  # not by the heap file's existence.  No database => "not built" => rebuild, and the
  # entire point of shipping a prebuilt heap is lost.
  #
  # The official Isabelle bundle ships exactly these files (Pure.db/Pure.gz/HOL.db/
  # HOL.gz in heaps/<ML_ID>/log/), which is why an official release does not rebuild
  # HOL on first use.  We ship them too.
  # ---------------------------------------------------------------------------
  for s in Pure HOL Main; do
    db="$hd/log/$s.db"
    [ -f "$db" ] || {
      echo "::error::$id/log/$s.db is missing -- the heap job must NOT delete heaps/*/log."
      echo "          Without the session database Isabelle rebuilds $s from scratch and"
      echo "          the prebuilt heap is dead weight."
      exit 1
    }
    printf '  session db  %-24s %s\n' "$id/log/$s.db" "$(du -h "$db" | cut -f1)"
  done
done

# ---------------------------------------------------------------------------
# 5. Put the empty directories back (see 1a).
#
# conda only creates a directory as the parent of a file it unpacks, so the only way to
# ship an empty one is to make it non-empty.  A single marker file does that, and unlike
# a post-link `mkdir` it is TRACKED: it shows up in `conda list --explicit`, and
# `conda remove` takes it away again (PACKAGING_DESIGN.md §3.1).
#
# The markers are dotfiles, and every directory that gets one merely ignores them:
# Cygwin's /tmp, /home, /dev/shm and /var/tmp are scratch; /etc/fstab.d is looked up by
# user name; /etc/ssl, /etc/sasl2, /lib/security and /usr/share/pkgconfig are matched by
# extension or exact name.
#
# !! EXCEPT var/lib/rebase/*.d -- do NOT mark those. !!
# rebaselst builds its work list with
#     dynPaths="$( find ${db} ${lb} ${ub} -type f | sort -u )"   (cygwin/bin/rebaselst:45)
# and then `cat`s every file it finds, treating each line as a path to rebase.  `find
# -type f` matches dotfiles, so a marker there would be read as a DLL list and feed this
# sentence to rebaseall -- during cygwin_init, on the user's first `isabelle` call.
# They also do not need us: rebaselst re-creates its own directories if they are absent
# (`mkdir -p`, rebaselst:12-17), which is exactly why rebaseall succeeded on the Windows
# VM with all of them missing.
# ---------------------------------------------------------------------------
n_dirs=0 n_skip=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  case "$d" in
    */var/lib/rebase/*) n_skip=$((n_skip + 1)); continue ;;
  esac
  mkdir -p "$TREE/$d"
  # only mark it if it is STILL empty -- some of these get filled in by the heap
  # injection or by the launcher above, and those need no marker.
  if [ -z "$(ls -A "$TREE/$d" 2>/dev/null)" ]; then
    printf 'This file exists so that conda ships this otherwise-empty directory.\n' \
      > "$TREE/$d/.conda-keep"
    n_dirs=$((n_dirs + 1))
  fi
done < "$EMPTY_DIRS"
echo "restored $n_dirs empty directory(ies) via .conda-keep markers"
echo "  (skipped $n_skip rebase state dir(s) -- rebaselst re-creates those itself, and a"
echo "   marker there would be cat'd into rebaseall's DLL list)"

# ---------------------------------------------------------------------------
# 6. MAX_PATH.  Assert, do not assume.
#
# Windows' MAX_PATH is 259 usable characters, LongPathsEnabled is 0 by default on
# Windows 11, and turning it on needs admin + a reboot.  It cannot be worked around from
# inside the package either: `conda create` fails while unpacking into the pkgs cache,
# long before any post-link script could run.  Measured, before the fixes above:
#     InvalidArchiveError ... node_addon_api_except.lastbuildstate   (262 chars)
#
# conda lays the payload down at   <pkgs>\<name>-<version>-<build>\<path-in-package>
# so the assertion is on that whole path, for
#     C:\Users\<20 characters>\AppData\Local\miniconda3\pkgs\isabelle-<version>-<build>\
# -- a Windows local account name maxes out at 20 -- so that every normal user installs
# without touching the registry.  The budget for <path-in-package> follows from the
# version and build number: 180 for isabelle-2025.2-0, 182 for isabelle-2026-0..9.
# Isabelle2026's own VSCodium has a 182-character path in it, so 2026 fits with no
# margin; the owner accepted that (2026-10-31).
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
# so osx-64 measured 201 and Job F went red on a package that is perfectly fine on macOS.
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
# 7. conda package
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
# Only linux-64 can be honestly tested here, and Job F does that far more thoroughly
# anyway: it installs from a local channel and builds a real session (see build.yml).
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
# 8. The package's isa/ is the official tree plus the changes above, nothing else.
# ---------------------------------------------------------------------------
"$PYTHON" "$HERE/check_pristine.py" compare "$SUBDIR" "$OFFICIAL_MANIFEST" "$PACKAGE"
