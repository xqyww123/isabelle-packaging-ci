#!/usr/bin/env bash
# Install-and-RUN check for a conda-installed Isabelle package.
#
#   verify_install.sh <conda-prefix>
#   env: ARCH_PREFIX   optional launcher, e.g. "arch -x86_64" to exercise the osx-64
#                      package on an Apple Silicon runner through Rosetta.
#
# This is what separates "the package builds" from "the package works".  Job F can only
# run linux-64 (everything else is cross-built), so until Jobs G/H existed, osx-64,
# osx-arm64 and linux-aarch64 had never been executed at all.
#
# The assertion that matters is the LAST one: build a real session on top of Main and
# require that HOL is not recompiled.  Do NOT be tempted to use `isabelle build -n`
# instead -- it is a FALSE PASS.  With the session databases (heaps/*/log/*.db) missing
# it cheerfully reports nothing to build, while a real build immediately rebuilds the
# whole of HOL.  That is how the missing-session-db bug hid in the first place.
set -euo pipefail

ENV_PREFIX="${1:?usage: verify_install.sh <conda-prefix>}"
ARCH_PREFIX="${ARCH_PREFIX:-}"

# Run a command the way a user of THIS package would.  $ARCH_PREFIX is empty for a
# native install; for osx-64 on an arm Mac it is `arch -x86_64`, which makes uname -m
# report x86_64 -- and uname -m is exactly what lib/scripts/getsettings keys
# ISABELLE_PLATFORM off, so the Rosetta run takes the same path a real Intel Mac takes.
isa() { $ARCH_PREFIX "$ENV_PREFIX/bin/isabelle" "$@"; }

# A fresh HOME: never inherit an .isabelle profile from the runner image or a previous
# step, or a stale preferences file could silently select a different heap.
GUARD_HOME="$(mktemp -d)"
export HOME="$GUARD_HOME"

echo "########## 1. the package is installed and has an entry point ##########"
echo "prefix       : $ENV_PREFIX"
echo "arch prefix  : ${ARCH_PREFIX:-<native>}"
ls -l "$ENV_PREFIX/bin/isabelle"

echo
echo "########## 2. it runs ##########"
ver="$(isa version)"
echo "isabelle version -> $ver"
[ -n "$ver" ] || { echo "::error::isabelle version printed nothing"; exit 1; }

echo
echo "########## 2b. the run resolves to the INTENDED architecture ##########"
# Without this, the osx-64 leg is a false pass waiting to happen.  The osx-64 package
# ships BOTH heaps (arm64_32-darwin AND x86_64_32-darwin), so "HOL not rebuilt" (step 5)
# passes even if the run silently loaded the arm heap -- i.e. executed zero x86 code.
# The only thing that catches that is asserting the runtime-resolved platform, not the
# arch we *asked* for.  So when ARCH_PREFIX forces x86_64, ISABELLE_PLATFORM64 must
# come back x86_64-*; if `arch -x86_64` ever silently stops taking effect, this reddens.
case "$ARCH_PREFIX" in
  *x86_64*)
    plat="$(isa getenv -b ISABELLE_PLATFORM64)"
    echo "forced x86_64 -> ISABELLE_PLATFORM64 = $plat"
    case "$plat" in
      x86_64-*) echo "  OK: the run really is x86_64 (Rosetta took effect)" ;;
      *) echo "::error::ARCH_PREFIX forces x86_64 but ISABELLE_PLATFORM64 is '$plat' --"
         echo "::error::the run is NOT executing x86 code; osx-64 would be a false pass."
         exit 1 ;;
    esac
    ;;
  *)
    echo "native install -- no architecture is being forced, nothing to assert"
    ;;
esac

echo
echo "########## 3. ISABELLE_HOME resolves INSIDE the conda prefix ##########"
# $PREFIX/isa, not $PREFIX/opt/<release> -- those 15 characters are charged against
# Windows' MAX_PATH on every path in the package (see conda/recipe.yaml).  Isabelle does
# not care: ISABELLE_HOME comes from bin/isabelle's own location at run time.
home="$(isa getenv -b ISABELLE_HOME)"
echo "ISABELLE_HOME -> $home"
[ "$home" = "$ENV_PREFIX/isa" ] || {
  echo "::error::ISABELLE_HOME is '$home', expected '$ENV_PREFIX/isa'"; exit 1; }
echo "  OK"

echo
echo "########## 4. the prebuilt heaps shipped inside the package ##########"
ls -l "$ENV_PREFIX/isa/heaps/"*/
echo "--- session databases (without these the heap is ignored and HOL is rebuilt) ---"
ls -l "$ENV_PREFIX/isa/heaps/"*/log/

echo
echo "########## 5. a REAL build must NOT recompile HOL ##########"
P="$(mktemp -d)"
printf 'theory T imports Main begin\nlemma "(2::nat) + 2 = 4" by simp\nend\n' > "$P/T.thy"
printf 'session Vfy = HOL +\n  theories T\n' > "$P/ROOT"

log="$(mktemp)"
t0=$(date +%s)
isa build -d "$P" Vfy 2>&1 | tee "$log"
echo "elapsed: $(( $(date +%s) - t0 ))s"

if grep -q 'Building HOL' "$log"; then
  echo "::error::Isabelle REBUILT HOL -- the heap shipped in the package was not used."
  echo "::error::Either heaps/<ML_ID>/log/*.db is missing from the package, or the heap's"
  echo "::error::ML variant does not match the one this platform resolves to."
  exit 1
fi
grep -q 'Finished Vfy' "$log" || { echo "::error::the verification session did not build"; exit 1; }
echo "  OK: HOL was NOT rebuilt -- the prebuilt heap in the package was loaded."

echo
echo "##################### $(basename "$ENV_PREFIX"): INSTALL+RUN VERIFIED #####################"
