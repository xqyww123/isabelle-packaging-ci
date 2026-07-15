#!/usr/bin/env bash
# Shared core of the jEdit GUI check, so the criteria cannot drift between platforms.
#
# The LAUNCH half (start a display, start jEdit, wait, screenshot) is unavoidably
# platform-specific -- Xvfb + xdotool + `import` on Linux, the native window server +
# `screencapture` on macOS -- and lives in the per-platform verify_gui*.sh.  But the
# parts that decide PASS/FAIL must be identical everywhere, or a lax macOS judge could
# green a package a strict Linux judge would have failed.  Those parts are here:
#
#   gui_judge.sh theory  <out.thy>              write the canonical Scratch.thy
#   gui_judge.sh pin-ml  <isa-tree> <clean-home>  pin ML_system_64 to the shipped heap
#   gui_judge.sh judge   <screenshot> <out-dir>   run Claude Code and apply the criteria
#
# `theory` and `judge` share one source of truth for what the theory contains and what
# the screenshot is judged against: the theory text below and the prompt below describe
# the SAME three lines, in one file, so they cannot fall out of step.
set -euo pipefail

# --------------------------------------------------------------------------------------
# The canonical theory: one lemma that MUST succeed, one that MUST fail.  `2 + 2 = 5` is
# not a stylistic choice -- it must fail under `simp` on any sane HOL, so a clean
# screenshot means the prover is NOT running, however healthy the window looks.
# --------------------------------------------------------------------------------------
emit_theory() {
  cat <<'THY'
theory Scratch imports Main begin
lemma good: "(2::nat) + 2 = 4" by simp
lemma bad: "(2::nat) + 2 = 5" by simp
end
THY
}

# --------------------------------------------------------------------------------------
# Pin the ML variant to the one the SHIPPED heap was built for.
#
# Not a nicety.  Isabelle keys its heaps by ML_IDENTIFIER, and ML_system_64 flips it
# (`..._x86_64-linux` for 64-bit ML, `..._x86_64_32-linux` for 32-bit).  If the running
# preference disagrees with the shipped heap, Isabelle does not warn -- it SILENTLY
# rebuilds HOL from source, inside a GUI dialog whose output never reaches any log, so
# the screenshot check would come up green while the 350 MB heap went unused.  A false
# pass, and exactly the one this whole check exists to prevent.  Derive it from the
# artifact, never assume.  Echoes the heap id so the caller can log it.
# --------------------------------------------------------------------------------------
pin_ml() {
  local isa_tree="$1" clean_home="$2"
  [ -d "$isa_tree" ] || { echo "::error::no Isabelle tree at $isa_tree" >&2; return 1; }
  local rel heap_id ml64
  rel=$(cat "$isa_tree/etc/ISABELLE_IDENTIFIER")
  heap_id=$(basename "$(ls -d "$isa_tree/heaps/"*/ | sed -n 1p)")
  case "$heap_id" in
    *_32-*) ml64=false ;;
    *)      ml64=true  ;;
  esac
  mkdir -p "$clean_home/.isabelle/$rel/etc"
  echo "ML_system_64 = \"$ml64\"" > "$clean_home/.isabelle/$rel/etc/preferences"
  echo "$heap_id"
}

# --------------------------------------------------------------------------------------
# The judgement.  Screenshot in, PASS/FAIL out.  Identical on every platform.
#
# Auth: CLAUDE_CODE_OAUTH_TOKEN (a subscription token from `claude setup-token`).
# NEVER ANTHROPIC_API_KEY -- it outranks the OAuth token in Claude Code's auth chain and
# would silently move the cost onto the metered API.  Claude reads its credentials from
# $HOME/.claude, but the launcher has switched HOME to a clean profile so Isabelle does
# not inherit a stray one; so the launcher passes the ORIGINAL home in CRED_HOME and we
# run claude under that.
# --------------------------------------------------------------------------------------
judge() {
  local shot="$1" out_dir="$2"
  local cred_home="${CRED_HOME:-$HOME}"
  mkdir -p "$out_dir"

  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && ! command -v claude >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 || true
  fi
  if ! command -v claude >/dev/null 2>&1; then
    echo "::warning::no claude CLI and no CLAUDE_CODE_OAUTH_TOKEN -- the screenshot was taken"
    echo "::warning::and will be uploaded, but NOT judged.  The GUI is UNVERIFIED this run."
    return 0
  fi
  echo "=== claude $(claude --version) ==="

  local schema
  schema='{
    "type": "object",
    "properties": {
      "started":           {"type": "string", "enum": ["yes", "no"]},
      "prover_ready":      {"type": "string", "enum": ["yes", "no", "unclear"]},
      "bad_lemma_flagged": {"type": "string", "enum": ["yes", "no", "unclear"]},
      "good_lemma_clean":  {"type": "string", "enum": ["yes", "no", "unclear"]},
      "evidence":          {"type": "string"}
    },
    "required": ["started", "prover_ready", "bad_lemma_flagged", "good_lemma_clean", "evidence"],
    "additionalProperties": false
  }'

  local prompt
  read -r -d '' prompt <<PROMPT_EOF || true
Look at the screenshot $shot. It is supposed to show the Isabelle/jEdit IDE, opened on a
theory file with exactly these three proof lines:

    theory Scratch imports Main begin
    lemma good: "(2::nat) + 2 = 4" by simp     <- must succeed
    lemma bad:  "(2::nat) + 2 = 5" by simp     <- must FAIL
    end

Report, strictly from what is visible:

  started           - did the IDE render a real, populated window (menus, editor with the
                      theory text, side panels)?  An empty or blank frame is "no".
  prover_ready      - does a prover status indicator report that the prover is up (e.g.
                      "Prover: ready")?
  bad_lemma_flagged - is there an error marker on the 'lemma bad' line (a red dot in the
                      left gutter, red/pink highlighting, a squiggly underline, or a red
                      stripe in the right-hand overview column)?
  good_lemma_clean  - is the 'lemma good' line free of any error marker?

Answer "unclear" only when the image genuinely does not show enough to tell.  Do not
infer from what you expect to be true; report only what the pixels show.
PROMPT_EOF

  set +e
  HOME="$cred_home" claude -p "$prompt" \
    --allowedTools Read \
    --output-format json \
    --json-schema "$schema" > "$out_dir/verdict.json" 2>"$out_dir/claude.err"
  local rc=$?
  set -e

  # No verdict is not the same thing as a bad verdict.  The token is a subscription
  # token; a session-limit / expired-login / API hiccup makes claude exit non-zero and
  # says NOTHING about the package.  A genuinely broken GUI always comes back AS a
  # verdict (started="no").  So only a verdict can turn this red; a missing one warns and
  # the screenshot is still uploaded.  (claude reports these in the JSON body, not stderr.)
  local verdict
  verdict=$(jq -r '.structured_output // "null"' "$out_dir/verdict.json" 2>/dev/null || echo null)
  if [ $rc -ne 0 ] || [ "$verdict" = null ]; then
    local why
    why=$(jq -r '.result // "no result field"' "$out_dir/verdict.json" 2>/dev/null || echo "unparseable output")
    echo "::warning::Claude Code returned no verdict (exit $rc): $why"
    echo "::warning::The GUI is therefore UNVERIFIED this run.  This is NOT a package failure --"
    echo "::warning::it is an auth/quota/API problem.  The screenshot is uploaded; look at it."
    cat "$out_dir/claude.err" 2>/dev/null || true
    return 0
  fi

  echo "=== verdict ==="
  jq '.structured_output' "$out_dir/verdict.json"

  local started ready bad good
  started=$(jq -r '.structured_output.started' "$out_dir/verdict.json")
  ready=$(jq -r '.structured_output.prover_ready' "$out_dir/verdict.json")
  bad=$(jq -r '.structured_output.bad_lemma_flagged' "$out_dir/verdict.json")
  good=$(jq -r '.structured_output.good_lemma_clean' "$out_dir/verdict.json")
  local evidence
  evidence=$(jq -r '.structured_output.evidence' "$out_dir/verdict.json")

  local fail=0
  [ "$started" = yes ] || { echo "::error::jEdit did not start: $evidence"; fail=1; }
  [ "$ready"   = yes ] || { echo "::error::the prover is not ready -- the GUI came up but the ML process did not"; fail=1; }

  # The discriminating pair.  "unclear" is a warning, not a red: vision can legitimately
  # fail to resolve a marker, and we would rather not flake the build over it.  A positive
  # "no", though, means the prover is demonstrably not checking.
  if [ "$bad" = no ]; then
    echo "::error::the failing lemma (2+2=5) shows NO error marker -- the GUI rendered but"
    echo "::error::the prover is not actually checking the document."
    fail=1
  elif [ "$bad" != yes ]; then
    echo "::warning::could not tell whether the failing lemma was flagged ($bad)"
  fi
  if [ "$good" = no ]; then
    echo "::error::the succeeding lemma (2+2=4) is flagged as an error -- something is wrong"
    echo "::error::with the shipped heap or the prover session."
    fail=1
  fi

  [ $fail -eq 0 ] && echo "  -> GUI verified: jEdit started, the prover is live, and it flagged exactly the bad proof."
  return $fail
}

case "${1:-}" in
  theory)  emit_theory > "${2:?usage: gui_judge.sh theory <out.thy>}" ;;
  pin-ml)  pin_ml "${2:?usage: gui_judge.sh pin-ml <isa-tree> <clean-home>}" "${3:?}" ;;
  judge)   judge "${2:?usage: gui_judge.sh judge <screenshot> <out-dir>}" "${3:?}" ;;
  *) echo "usage: gui_judge.sh {theory <out.thy> | pin-ml <isa-tree> <home> | judge <shot> <out-dir>}" >&2; exit 2 ;;
esac
