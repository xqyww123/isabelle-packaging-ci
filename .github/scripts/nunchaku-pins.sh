#!/bin/bash
# Print the isabelle-nunchaku solver pins as KEY=value lines, for $GITHUB_ENV.
#
#   .github/scripts/nunchaku-pins.sh >> "$GITHUB_ENV"
#
# WHERE THE VALUES COME FROM, and why this script exists.  The two bundled
# solver versions used to be literals in release-nunchaku.yml -- `0\.6\.1` in
# the staging step, `cvc5 1.3.4` twice in the post-publish smoke -- with no
# relation to the recipe's own `context:` values, and none of the four had any
# relation to the fork's pins either.  cvc5 1.3.4 was ten independent literals
# across the two repositories with nothing comparing them.
#
# The chain is now one-directional and every link is asserted:
#
#   xqyww123/nunchaku component/solvers.pins   (the source of truth)
#     ^-- asserted, digest for digest and version for version, by the recipe's
#         build script against its own `context:` values, on every leg
#   conda/components/isabelle-nunchaku/recipe.yaml `context:`
#     ^-- read here
#   release-nunchaku.yml's assertions
#
# So a solver bump applied to the fork alone reddens the build; applied to the
# recipe alone it reddens the build too; and the workflow can no longer disagree
# with the recipe at all.
#
# sed and grep only, deliberately.  This runs in the post-publish smoke as well
# as in the build job, and that job's shell is Git-Bash on windows-latest, where
# `python3` is not something to bet a release gate on.
set -euo pipefail

recipe=${1:-conda/components/isabelle-nunchaku/recipe.yaml}
[ -f "$recipe" ] || { echo "::error::$recipe not found" >&2; exit 1; }

# The `tr -d '\r'`: on Windows the checkout can arrive with CRLF, and the `"$`
# anchor below would then never match -- a Windows-only failure of exactly the
# class this repository has a whole probe workflow about.
body=$(tr -d '\r' < "$recipe")

emit () {  # <context key> <environment variable name>
  local v n
  # Anchored on the context block's own spelling: two-space indent, a quoted
  # scalar.  Exactly one match, or fail -- a renamed key and a half-applied edit
  # that left two are both errors, and both are silent if the first match wins.
  v=$(printf '%s\n' "$body" | sed -n "s/^  $1: \"\\([^\"]*\\)\"\$/\\1/p")
  n=$(printf '%s' "$v" | grep -c '' || true)
  if [ "$n" -ne 1 ]; then
    echo "::error::$recipe has $n context.$1 lines, expected exactly one" >&2
    exit 1
  fi
  printf '%s=%s\n' "$2" "$v"
}

emit cvc5_version CVC5_VERSION
emit smbc_version SMBC_VERSION
