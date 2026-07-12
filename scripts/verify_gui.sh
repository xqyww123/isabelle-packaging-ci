#!/usr/bin/env bash
# Verify that the conda-installed Isabelle can actually start its GUI (jEdit) and
# check a proof through it.
#
# A GUI is the one thing no headless assertion can reach: `isabelle version` and
# `isabelle build` both pass on a package whose jEdit dies on startup.  So we take a
# screenshot and let Claude Code look at it.
#
# The screenshot is not judged on "did a window appear" -- that is satisfied by an
# empty frame.  We open a theory holding one lemma that MUST succeed and one that MUST
# fail, and require the error marker to land on exactly the failing line.  That upgrades
# the check from "the window rendered" to "the prover is really checking through it".
#
# Usage: verify_gui.sh <conda-prefix> <out-dir>
# Env:   CLAUDE_CODE_OAUTH_TOKEN -- if unset, the screenshot is still produced and
#        uploaded, and the AI judgement is skipped with a warning (so the pipeline is
#        not blocked on the secret).  Never set ANTHROPIC_API_KEY here: it outranks the
#        OAuth token and would silently bill the metered API instead of the subscription.
set -euo pipefail

ENV_PREFIX="${1:?usage: verify_gui.sh <conda-prefix> <out-dir>}"
OUT_DIR="${2:?usage: verify_gui.sh <conda-prefix> <out-dir>}"
mkdir -p "$OUT_DIR"

SHOT="$OUT_DIR/jedit.png"
DISP=":99"

export PATH="$ENV_PREFIX/bin:$PATH"
export DISPLAY="$DISP"
# jEdit is an X11 app; a stray Wayland handle in the environment makes the JVM pick the
# wrong toolkit and it never maps a window.
unset WAYLAND_DISPLAY XDG_SESSION_TYPE || true

# A fresh HOME: the .isabelle profile must not be inherited from whoever ran this.
# Keep the real one, though: `claude` reads its credentials from $HOME/.claude, so the
# judgement below must run under the original HOME or it fails with "Not logged in".
ORIG_HOME="$HOME"
GUI_HOME="$OUT_DIR/home"
rm -rf "$GUI_HOME"; mkdir -p "$GUI_HOME"
export HOME="$GUI_HOME"

# ---------------------------------------------------------------------------------
# Pin the ML variant to the one the SHIPPED heap was built for.
#
# This is not a nicety.  Isabelle keys its heaps by ML_IDENTIFIER, and ML_system_64
# flips that identifier (`..._x86_64-linux` for 64-bit ML, `..._x86_64_32-linux` for
# 32-bit).  If the running preference disagrees with the shipped heap, Isabelle does
# not warn -- it just silently rebuilds HOL from source.  jEdit does that in a GUI
# dialog whose output never reaches jedit.log, so the screenshot check would come up
# green (window renders, prover ready, bad lemma flagged) while the 350 MB heap in the
# package went completely unused.  A false pass, and exactly the one this whole step
# exists to prevent.  Derive the preference from the artifact instead of assuming.
# ---------------------------------------------------------------------------------
REL=$(basename "$(ls -d "$ENV_PREFIX"/opt/*/ | head -1)")
HEAP_ID=$(basename "$(ls -d "$ENV_PREFIX/opt/$REL/heaps/"*/ | head -1)")
case "$HEAP_ID" in
  *_32-*) ML64=false ;;
  *)      ML64=true  ;;
esac
mkdir -p "$GUI_HOME/.isabelle/$REL/etc"
echo "ML_system_64 = \"$ML64\"" > "$GUI_HOME/.isabelle/$REL/etc/preferences"
echo "=== shipped heap: $HEAP_ID  ->  ML_system_64 = $ML64 ==="

echo "=== starting Xvfb on $DISP ==="
Xvfb "$DISP" -screen 0 1600x1000x24 >"$OUT_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!
cleanup() {
  [ -n "${JEDIT_PID:-}" ] && kill "$JEDIT_PID" 2>/dev/null || true
  sleep 2
  kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT
sleep 3
xdpyinfo -display "$DISP" >/dev/null 2>&1 || { echo "::error::Xvfb did not come up"; cat "$OUT_DIR/xvfb.log"; exit 1; }

# One lemma that must go through, one that cannot.  `2 + 2 = 5` is not a stylistic
# choice: it must fail under `simp` on any sane HOL, so a clean screenshot here means
# the prover is NOT running, however healthy the window looks.
WORK="$OUT_DIR/thy"; mkdir -p "$WORK"
cat > "$WORK/Scratch.thy" <<'THY'
theory Scratch imports Main begin
lemma good: "(2::nat) + 2 = 4" by simp
lemma bad: "(2::nat) + 2 = 5" by simp
end
THY

echo "=== launching: isabelle jedit -l HOL Scratch.thy ==="
isabelle jedit -l HOL "$WORK/Scratch.thy" >"$OUT_DIR/jedit.log" 2>&1 &
JEDIT_PID=$!

# jEdit needs ~90s to map its window on an idle machine, and far longer on a loaded one.
# Be generous: a timeout here is indistinguishable from a real failure, and a flaky red
# on a slow runner is worse than waiting.
WAIT_TICKS=120   # x 5s = 10 min
for i in $(seq 1 $WAIT_TICKS); do
  sleep 5
  if xdotool search --onlyvisible --name 'Scratch.thy' >/dev/null 2>&1; then
    echo "  window mapped after ~$((i * 5))s"
    break
  fi
  kill -0 "$JEDIT_PID" 2>/dev/null || { echo "::error::jEdit exited before mapping a window"; tail -40 "$OUT_DIR/jedit.log"; exit 1; }
  if [ "$i" = "$WAIT_TICKS" ]; then
    # Say what WAS on screen. A bare "no window" is undiagnosable after the fact -- the
    # Xvfb is gone by the time anyone reads the log.
    echo "::error::no jEdit window after $((WAIT_TICKS * 5))s.  Windows actually present:"
    xdotool search --onlyvisible --name '.' 2>/dev/null | while read -r w; do
      echo "::error::  - '$(xdotool getwindowname "$w" 2>/dev/null)'"
    done
    echo "::error::load average:$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    import -window root -display "$DISP" "$SHOT" || true
    tail -40 "$OUT_DIR/jedit.log"
    exit 1
  fi
done

# If the shipped heap is being used, jEdit goes straight to the editor.  A visible
# "Isabelle build" dialog means it is recompiling HOL -- i.e. the heap did not match and
# is dead weight.  Catch it here: this is invisible to every other assertion in the job.
if xdotool search --onlyvisible --name '^Isabelle build' >/dev/null 2>&1; then
  echo "::error::jEdit opened an 'Isabelle build' dialog -- it is REBUILDING HOL rather"
  echo "::error::than loading the heap shipped in the package.  Either the session"
  echo "::error::databases (heaps/*/log/*.db) are missing, or the heap's ML variant"
  echo "::error::($HEAP_ID) does not match the one the session resolves to."
  import -window root -display "$DISP" "$SHOT" || true
  exit 1
fi

# Let continuous checking settle, or the verdict describes a half-processed buffer.
echo "=== waiting 60s for continuous checking to settle ==="
sleep 60

import -window root -display "$DISP" "$SHOT"
echo "=== screenshot: $(du -h "$SHOT" | cut -f1) ==="
echo "=== window titles ==="
xdotool search --onlyvisible --name '.' 2>/dev/null | while read -r w; do
  echo "  - $(xdotool getwindowname "$w" 2>/dev/null)"
done

# ---------------------------------------------------------------------------------
# The AI judgement.
# ---------------------------------------------------------------------------------
# On a runner, auth comes from CLAUDE_CODE_OAUTH_TOKEN (a Claude subscription token from
# `claude setup-token`).  Deliberately NOT ANTHROPIC_API_KEY: it outranks the OAuth token
# in Claude Code's auth chain, so setting it would silently move the cost onto the
# metered API.  Run this script locally and an interactive login serves instead, which is
# why the gate below is "can claude actually run", not "is the variable set".
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code >/dev/null 2>&1
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "::warning::no claude CLI and no CLAUDE_CODE_OAUTH_TOKEN -- the screenshot was taken"
  echo "::warning::and will be uploaded, but NOT judged.  The GUI is UNVERIFIED this run."
  exit 0
fi
echo "=== claude $(claude --version) ==="

SCHEMA='{
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

read -r -d '' PROMPT <<PROMPT_EOF || true
Look at the screenshot $SHOT. It is supposed to show the Isabelle/jEdit IDE, opened on a
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
HOME="$ORIG_HOME" claude -p "$PROMPT" \
  --allowedTools Read \
  --output-format json \
  --json-schema "$SCHEMA" > "$OUT_DIR/verdict.json" 2>"$OUT_DIR/claude.err"
rc=$?
set -e

# ---------------------------------------------------------------------------------
# No verdict is not the same thing as a bad verdict.
#
# The token is a *subscription* token, so this call shares a quota with whatever the
# owner is doing interactively.  Hitting the session limit, or an expired login, or any
# API hiccup, makes claude exit non-zero -- and none of that says anything about the
# package.  Failing the build on it would train everyone to ignore a red Job F.
#
# A genuinely broken GUI always comes back AS a verdict (started="no").  So: only a
# verdict can turn this red.  A missing one is a loud warning and the screenshot is
# still uploaded for a human to look at.  (claude reports these failures in the JSON
# body, not on stderr -- read .result or the cause is invisible.)
# ---------------------------------------------------------------------------------
verdict=$(jq -r '.structured_output // "null"' "$OUT_DIR/verdict.json" 2>/dev/null || echo null)
if [ $rc -ne 0 ] || [ "$verdict" = null ]; then
  why=$(jq -r '.result // "no result field"' "$OUT_DIR/verdict.json" 2>/dev/null || echo "unparseable output")
  echo "::warning::Claude Code returned no verdict (exit $rc): $why"
  echo "::warning::The GUI is therefore UNVERIFIED this run.  This is NOT a package failure --"
  echo "::warning::it is an auth/quota/API problem.  The screenshot is uploaded; look at it."
  cat "$OUT_DIR/claude.err" 2>/dev/null || true
  exit 0
fi

echo "=== verdict ==="
jq '.structured_output' "$OUT_DIR/verdict.json"

v() { jq -r ".structured_output.$1" "$OUT_DIR/verdict.json"; }
started=$(v started); ready=$(v prover_ready)
bad=$(v bad_lemma_flagged); good=$(v good_lemma_clean)

fail=0
[ "$started" = yes ] || { echo "::error::jEdit did not start: $(v evidence)"; fail=1; }
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
exit $fail
