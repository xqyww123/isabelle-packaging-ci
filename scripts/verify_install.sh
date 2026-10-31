#!/usr/bin/env bash
# Install-and-RUN check for a conda-installed Isabelle package.
#
#   verify_install.sh <conda-prefix>
#
# This is what separates "the package builds" from "the package works": the one
# install-and-run check for every package a runner can execute natively -- linux-64 in
# build.yml's `conda` job, osx-64, osx-arm64 and linux-aarch64 in its install-* jobs.
#
# The assertion that matters is the LAST one: build a real session on top of Main and
# require that HOL is not recompiled.  Do NOT be tempted to use `isabelle build -n`
# instead -- it is a FALSE PASS.  With the session databases (heaps/*/log/*.db) missing
# it cheerfully reports nothing to build, while a real build immediately rebuilds the
# whole of HOL.  That is how the missing-session-db bug hid in the first place.
set -euo pipefail

ENV_PREFIX="${1:?usage: verify_install.sh <conda-prefix>}"
isa() { "$ENV_PREFIX/bin/isabelle" "$@"; }

# A fresh HOME: never inherit an .isabelle profile from the runner image or a previous
# step, or a stale preferences file could silently select a different heap.
GUARD_HOME="$(mktemp -d)"
export HOME="$GUARD_HOME"

echo "########## 1. the package is installed and has an entry point ##########"
echo "prefix       : $ENV_PREFIX"
ls -l "$ENV_PREFIX/bin/isabelle"

echo
echo "########## 2. it runs ##########"
ver="$(isa version)"
echo "isabelle version -> $ver"
[ -n "$ver" ] || { echo "::error::isabelle version printed nothing"; exit 1; }
echo "ISABELLE_PLATFORM64 -> $(isa getenv -b ISABELLE_PLATFORM64)"

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
