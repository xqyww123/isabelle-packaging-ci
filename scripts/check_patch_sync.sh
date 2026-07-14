#!/usr/bin/env bash
# Does the PyPI version we are about to SHIP contain the patches you have been
# DEVELOPING against?
#
# CI installs my-better-isabelle-prover from PyPI at the version pinned in
# build.yml.  It never looks at your working copy.  So a patch you added locally
# and forgot to publish is a patch your users will not get -- and nothing else
# catches it: CI goes green, the packages build, they install, they run.  The
# Isabelle you ship is simply not the one you tested against.  "Works on my
# machine", with a release attached.
#
# Comparing version STRINGS would not catch it.  That is not hypothetical: the
# pide_control retirement landed on git while the version stayed 0.3.0.  So this
# compares the patch files themselves.
#
# Usage: check_patch_sync.sh [path-to-my_better_isabelle_prover-checkout]
#        (default: ../my_better_isabelle_prover, i.e. the sibling submodule)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="${1:-$HERE/../my_better_isabelle_prover}"
BUILD_YML="$HERE/.github/workflows/build.yml"

[ -d "$LOCAL" ] || { echo "::error::no checkout at $LOCAL -- pass one as \$1"; exit 1; }

# The single source of truth for what we ship.
VERSION=$(sed -n 's/^ *MBI_VERSION="\([^"]*\)".*/\1/p' "$BUILD_YML" | head -1)
[ -n "$VERSION" ] || { echo "::error::could not read MBI_VERSION from $BUILD_YML"; exit 1; }
echo "build.yml ships:  my-better-isabelle-prover==$VERSION"
echo "comparing against: $LOCAL"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pip download --no-deps --quiet "my-better-isabelle-prover==$VERSION" -d "$TMP" 2>/dev/null || {
  echo "::error::PyPI has no my-better-isabelle-prover==$VERSION."
  echo "::error::You bumped MBI_VERSION but never published it."
  exit 1
}
( cd "$TMP" && for f in *.whl *.tar.gz; do [ -e "$f" ] || continue; python3 -m zipfile -e "$f" pkg 2>/dev/null || tar xzf "$f" -C . ; done )

# What decides the Isabelle we ship, and nothing else:
#   *.patch            the patches themselves
#   categories.toml    which of them `--category user` selects
#   *.py               how they are selected and applied
#
# NOT the .md files.  patches/*.md are prose explaining each patch to a human,
# and pyproject.toml deliberately leaves them out of the distribution
# (package-data ships only patches/**/*.patch, patches/categories.toml,
# AGENTS.md).  Hashing them would fail this check on every docs edit and force a
# pointless PyPI release -- and it did, the first time this script ran.
hash_payload() {
  find "$1" -type f \( -name '*.patch' -o -name 'categories.toml' -o -name '*.py' \) \
       -not -path '*/__pycache__/*' -printf '%P\n' \
    | LC_ALL=C sort \
    | while read -r rel; do printf '%s  %s\n' "$(sha256sum "$1/$rel" | cut -d' ' -f1)" "$rel"; done
}

PYPI_PKG=$(find "$TMP" -type d -name my_better_isabelle_prover -not -path '*/patches/*' | head -1)
LOCAL_PKG="$LOCAL/my_better_isabelle_prover"
[ -n "$PYPI_PKG" ] || { echo "::error::the PyPI artifact has no my_better_isabelle_prover/ package"; exit 1; }
[ -d "$LOCAL_PKG" ] || { echo "::error::no my_better_isabelle_prover/ in $LOCAL"; exit 1; }

if diff <(hash_payload "$PYPI_PKG") <(hash_payload "$LOCAL_PKG") > "$TMP/diff"; then
  echo "  -> in sync: PyPI $VERSION ships exactly the patches and code in your checkout."
  exit 0
fi

echo "::error::The patch set you develop against is NOT the one that would ship."
echo "::error::PyPI $VERSION and your checkout differ:"
sed 's/^/    /' "$TMP/diff" | head -30
echo
echo "  Publish a NEW version to PyPI, bump MBI_VERSION in build.yml, and bump"
echo "  ISA_BUILD_NUMBER -- the content changed, so the package must not reuse a"
echo "  published filename."
exit 1
