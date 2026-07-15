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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUDGE="$HERE/gui_judge.sh"   # shared theory/pin-ml/judge, so the criteria cannot drift

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

# Pin the ML variant to the shipped heap (shared guard -- prevents a silent HOL rebuild
# that would false-green this check; see gui_judge.sh:pin_ml for why).
HEAP_ID=$(bash "$JUDGE" pin-ml "$ENV_PREFIX/isa" "$GUI_HOME")
echo "=== shipped heap: $HEAP_ID ==="

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
bash "$JUDGE" theory "$WORK/Scratch.thy"

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
# Diagnostic only -- must never fail the step.  Under `set -euo pipefail` a zero-match
# `xdotool search` exits 1 and would red a run whose screenshot was already taken and
# whose AI verdict has not run yet.
{ xdotool search --onlyvisible --name '.' 2>/dev/null | while read -r w; do
    echo "  - $(xdotool getwindowname "$w" 2>/dev/null)"
  done; } || true

# Hand off to the shared judge (screenshot -> Claude -> verdict -> criteria), which is
# identical for every platform.  CRED_HOME points it at the real profile with the
# `claude` credentials, since we switched HOME to a clean one above.
CRED_HOME="$ORIG_HOME" bash "$JUDGE" judge "$SHOT" "$OUT_DIR"
