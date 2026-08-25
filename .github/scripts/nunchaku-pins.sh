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
set -euo pipefail

recipe=${1:-conda/components/isabelle-nunchaku/recipe.yaml}

RECIPE="$recipe" python3 - <<'PY'
import os, re, sys

text = open(os.environ["RECIPE"], encoding="utf-8").read()
for key, name in (("cvc5_version", "CVC5_VERSION"), ("smbc_version", "SMBC_VERSION")):
    # The context block's own spelling: two-space indent, a quoted scalar.
    m = re.search(rf'^  {key}: "([^"]+)"$', text, re.M)
    if not m:
        sys.exit(f"::error::{os.environ['RECIPE']} has no context.{key} line")
    print(f"{name}={m.group(1)}")
PY
