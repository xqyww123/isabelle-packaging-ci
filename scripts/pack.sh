#!/usr/bin/env bash
#
# Job F, step 1+2: inject the natively-built heaps into a platform bundle and turn
# the result into a conda package.
#
#   pack.sh --subdir linux-64 \
#           --bundle  <Isabelle2025-2_linux.tar.gz | Isabelle2025-2.exe | a directory> \
#           --heaps   <dir containing one or more <ML_IDENTIFIER>/ dirs> \
#           --out     <output dir for the .conda file>
#
# It runs entirely on Linux, for every target platform -- including win-64.  That is
# forced, not chosen: the tools that make a Windows bundle are Unix-only, so Job A
# already cross-builds the .exe on Linux (PACKAGING_DESIGN.md §5.0 rule 1).  Nothing
# here compiles anything; we only move files and zip them up.
#
# The heap artifacts are copied WHOLESALE: every <ML_IDENTIFIER>/ directory the heap
# job produced goes into the bundle's heaps/.  No platform->ML_IDENTIFIER mapping is
# hard-coded anywhere -- `isabelle getenv ML_IDENTIFIER` prints nothing (it is computed
# Scala-side, PACKAGING_DESIGN.md §5.1.1), so the directory name is the only source of
# truth and we simply propagate it.  For macOS that means both the x86_64 and the arm64
# heap ride along in both osx packages; the macOS bundle is universal anyway, and it
# costs a few hundred MB to be certain that whichever ML_PLATFORM a given Mac resolves
# to at run time, its heap is there.

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
RELEASE="${ISA_RELEASE:-Isabelle2025-2}"
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
    # archive of the whole tree (build_release.scala:820-841).  7-Zip reads it directly.
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

# macOS bundles are renamed to <release>.app by build_release (build_release.scala:722).
TREE="$STAGE/$RELEASE"
[ -d "$TREE" ] || TREE="$STAGE/$RELEASE.app"
[ -d "$TREE" ] || { echo "::error::no $RELEASE tree in the unpacked bundle"; ls -la "$STAGE"; exit 1; }
echo "tree: $TREE"

# The bundle must arrive WITHOUT heaps -- Job A builds with no -b flag on purpose.
# If it ever ships heaps, they would be cross-built garbage; fail loudly.
if [ -d "$TREE/heaps" ] && [ -n "$(ls -A "$TREE/heaps" 2>/dev/null)" ]; then
  echo "::error::the bundle already contains heaps -- Job A must not pass -b"
  ls -R "$TREE/heaps" | head; exit 1
fi

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
# Stock etc/settings puts USER state -- config and on-demand-built session heaps --
# in ~/.isabelle/Isabelle2025-2, which is SHARED with any stock Isabelle2025-2 the user
# also has.  Our Pure is patched (pide_control, expose_foreign, ...), so a heap built
# here is not interchangeable with a stock one; sharing the directory makes the two
# clobber each other and churn.  We append `-conda-<env>` so each conda env gets its own
# ~/.isabelle/Isabelle2025-2-conda-<env>.  The env is derived from the install prefix
# ($ISABELLE_HOME = <prefix>/isa), so it is correct even without `conda activate`.
#
# Only ISABELLE_HOME_USER is touched: ISABELLE_HEAPS and everything else keyed off it are
# set AFTER it in etc/settings and follow along (the 15 lines between are ISABELLE_TOOLS
# and ISABELLE_TMP_PREFIX, neither of which reads it -- verified).  ISABELLE_NAME and the
# rest of the identity stay "Isabelle2025-2".  The base pre-unlink (recipe.yaml) removes
# this directory on `conda remove`.
# ---------------------------------------------------------------------------
SETTINGS="$TREE/etc/settings"
grep -q 'conda-\$(basename' "$SETTINGS" && { echo "::error::etc/settings already carries the conda HOME_USER patch"; exit 1; }
grep -q '^ISABELLE_HEAPS="\$ISABELLE_HOME_USER/heaps"$' "$SETTINGS" || {
  echo "::error::etc/settings anchor 'ISABELLE_HEAPS=\$ISABELLE_HOME_USER/heaps' not found -- upstream layout changed, re-check the patch"; exit 1; }
sed -i 's#^ISABELLE_HEAPS="\$ISABELLE_HOME_USER/heaps"$#ISABELLE_HOME_USER="${ISABELLE_HOME_USER}-conda-$(basename "$(dirname "$ISABELLE_HOME")")"\n&#' "$SETTINGS"
echo "patched etc/settings: ISABELLE_HOME_USER -> ~/.isabelle/${RELEASE}-conda-<env>"

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
[ "$n" -gt 0 ] || { echo "::error::no <ML_IDENTIFIER>/ directory found under $HEAPS"; ls -la "$HEAPS"; exit 1; }

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
# so what we control is the length of <path-in-package>.  180 leaves room for
#     C:\Users\<name>\AppData\Local\miniconda3\pkgs\isabelle-2025.2-0\
# with a user name of up to ~21 characters -- and a Windows local account name maxes out
# at 20.  So: every normal user installs without touching the registry.
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
MAX_REL=180
path_lengths() {
  ( cd "$TREE" && find . -mindepth 1 | sed 's|^\./||' \
      | awk -v p="isa/" '{ print length(p $0), p $0 }' | sort -rn )
}
longest=$(path_lengths | sed -n 1p)
longest_len=${longest%% *}
longest_path=${longest#* }

if [ "$SUBDIR" = win-64 ]; then
  echo "longest path in the package: $longest_len chars (budget $MAX_REL, ENFORCED for win-64)"
  echo "  $longest_path"
  if [ "$longest_len" -gt "$MAX_REL" ]; then
    echo "::error::longest in-package path is $longest_len characters, over the $MAX_REL limit."
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
# etc/ISABELLE_ID is the hg changeset of OUR patch commit.  It no longer goes into the
# build string (every character there costs us MAX_PATH on Windows -- see recipe.yaml);
# it is carried in the package's about.description instead, and lives authoritatively
# in the tree itself at isa/etc/ISABELLE_ID.
ISA_ID="$(cat "$TREE/etc/ISABELLE_ID" 2>/dev/null || echo unknown)"
echo "ISABELLE_ID = $ISA_ID"

mkdir -p "$OUT"
export ISA_STAGE="$TREE"
export ISA_RELEASE="$RELEASE"
export ISA_ID
export ISA_BUILD_NUMBER="${ISA_BUILD_NUMBER:-0}"

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

echo "=== produced ==="
find "$OUT" -name '*.conda' -newer "$TREE/etc/ISABELLE_ID" -printf '%p  %s bytes\n' 2>/dev/null || \
  find "$OUT" -name '*.conda' -printf '%p  %s bytes\n'
