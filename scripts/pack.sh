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
# 3. conda package
# ---------------------------------------------------------------------------
# etc/ISABELLE_ID is the hg changeset of OUR patch commit -- the provenance that
# goes into the build string (the conda version cannot carry it: '-' is the field
# separator in name-version-build, and the id is not a version anyway).
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
