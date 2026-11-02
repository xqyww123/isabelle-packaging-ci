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
#   gui_judge.sh judge   <screenshot> <out-dir>   run Claude Code and apply the criteria
#
# A check Claude does not judge warns, or fails under REQUIRE_GUI_VERDICT=true, which
# release.yml sets (see unjudged).
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
# The judgement.  Screenshot in, PASS/FAIL out.  Identical on every platform.
#
# Auth: CLAUDE_CODE_OAUTH_TOKEN (a subscription token from `claude setup-token`).
# NEVER ANTHROPIC_API_KEY -- it outranks the OAuth token in Claude Code's auth chain and
# would silently move the cost onto the metered API.  Claude reads its credentials from
# $HOME/.claude, but the launcher has switched HOME to a clean profile so Isabelle does
# not inherit a stray one; so the launcher passes the ORIGINAL home in CRED_HOME and we
# run claude under that.
# --------------------------------------------------------------------------------------
# A check Claude did not judge -- no claude CLI or token, a used-up quota, an API error,
# or "unclear" on the bad/good pair -- says nothing about the package, so it only warns;
# but a release cannot be withdrawn, so under REQUIRE_GUI_VERDICT=true it fails (owner).
unjudged() {
  echo "::warning::$1 -- the GUI is NOT verified this run; the screenshot is uploaded, look at it."
  [ "${REQUIRE_GUI_VERDICT:-false}" = true ] || return 0
  echo "::error::a release needs a GUI verdict (REQUIRE_GUI_VERDICT); the warning above gives the reason -- see RELEASE_ISABELLE.md, \"A GUI check without a verdict\""
  return 1
}

judge() {
  local shot="$1" out_dir="$2"
  local cred_home="${CRED_HOME:-$HOME}"
  mkdir -p "$out_dir"

  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && ! command -v claude >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 || true
  fi
  if ! command -v claude >/dev/null 2>&1; then
    unjudged "no claude CLI and no CLAUDE_CODE_OAUTH_TOKEN"
    return
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

  # No verdict is not a bad verdict (see unjudged): a genuinely broken GUI comes back AS a
  # verdict (started="no").  claude reports why in the JSON body, not stderr.
  local verdict
  verdict=$(jq -r '.structured_output // "null"' "$out_dir/verdict.json" 2>/dev/null || echo null)
  if [ $rc -ne 0 ] || [ "$verdict" = null ]; then
    local why
    why=$(jq -r '.result // "no result field"' "$out_dir/verdict.json" 2>/dev/null || echo "unparseable output")
    cat "$out_dir/claude.err" 2>/dev/null || true
    unjudged "Claude Code returned no verdict (exit $rc): $why"
    return
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

  # The discriminating pair.  A "no" means the prover is demonstrably not checking, or
  # the heap is wrong.  "unclear" -- vision can fail to resolve a marker -- leaves the
  # check unjudged.
  if [ "$bad" = no ]; then
    echo "::error::the failing lemma (2+2=5) shows NO error marker -- the GUI rendered but"
    echo "::error::the prover is not actually checking the document."
    fail=1
  fi
  if [ "$good" = no ]; then
    echo "::error::the succeeding lemma (2+2=4) is flagged as an error -- something is wrong"
    echo "::error::with the shipped heap or the prover session."
    fail=1
  fi
  [ $fail -eq 0 ] || return 1
  if [ "$bad" != yes ] || [ "$good" != yes ]; then
    unjudged "Claude could not tell whether only the failing lemma is flagged (bad: $bad, good: $good)"
    return
  fi
  echo "  -> GUI verified: jEdit started, the prover is live, and it flagged exactly the bad proof."
}

case "${1:-}" in
  theory)  emit_theory > "${2:?usage: gui_judge.sh theory <out.thy>}" ;;
  judge)   judge "${2:?usage: gui_judge.sh judge <screenshot> <out-dir>}" "${3:?}" ;;
  *) echo "usage: gui_judge.sh {theory <out.thy> | judge <shot> <out-dir>}" >&2; exit 2 ;;
esac
