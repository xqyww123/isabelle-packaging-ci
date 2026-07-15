#!/usr/bin/env bash
# macOS jEdit GUI check for a conda-installed Isabelle package.
#
#   verify_gui_macos.sh <conda-prefix> <out-dir>
#
# Same judgement as Linux -- it calls the SHARED scripts/gui_judge.sh for the theory, the
# ML-variant pinning, and the Claude verdict + criteria, so the standard cannot drift.
# What differs is only the LAUNCH: macOS has a real window server (the runner's
# screencapture probe proved it), so there is no Xvfb; jEdit renders through Quartz and
# we grab the screen with `screencapture -x`.  There is no xdotool either, so window
# state is queried best-effort through AppleScript and, when that is not available, we
# fall back on a generous wait and let the screenshot itself be the evidence.
#
# Nothing about macOS behaviour is assumed here -- file-path convention, whether jEdit
# blocks or detaches, whether AppleScript can enumerate windows -- it is all probed and
# logged, and the real gate is the shared Claude judgement of the screenshot.
set -euo pipefail

ENV_PREFIX="${1:?usage: verify_gui_macos.sh <conda-prefix> <out-dir>}"
OUT_DIR="${2:?usage: verify_gui_macos.sh <conda-prefix> <out-dir>}"
mkdir -p "$OUT_DIR"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUDGE="$HERE/gui_judge.sh"
SHOT="$OUT_DIR/jedit.png"

export PATH="$ENV_PREFIX/bin:$PATH"

# A fresh HOME so Isabelle never inherits a stray .isabelle profile.  Keep the real one
# in ORIG_HOME: `claude` reads its credentials from there.
ORIG_HOME="$HOME"
GUI_HOME="$OUT_DIR/home"
rm -rf "$GUI_HOME"; mkdir -p "$GUI_HOME"
export HOME="$GUI_HOME"

# Shared guard: pin ML_system_64 to the shipped heap, or Isabelle silently rebuilds HOL
# in a dialog and the screenshot false-greens.  (gui_judge.sh:pin_ml.)
HEAP_ID=$(bash "$JUDGE" pin-ml "$ENV_PREFIX/isa" "$GUI_HOME")
echo "=== shipped heap: $HEAP_ID ==="

# Sanity: the screen really is capturable here (the job's probe asserts this too, but if
# it is not, say so instead of producing a black PNG that Claude would rightly fail).
if ! screencapture -x "$OUT_DIR/_precheck.png" 2>"$OUT_DIR/screencapture.err" || [ ! -s "$OUT_DIR/_precheck.png" ]; then
  echo "::error::screencapture cannot grab this runner's screen -- no usable window server."
  cat "$OUT_DIR/screencapture.err" 2>/dev/null || true
  exit 1
fi
rm -f "$OUT_DIR/_precheck.png"

WORK="$OUT_DIR/thy"; mkdir -p "$WORK"
bash "$JUDGE" theory "$WORK/Scratch.thy"

# macOS is plain Unix: a normal filesystem path should open like on Linux (unlike the
# Windows cygwin/native split).  We do NOT assume the buffer loaded, though -- the shared
# judge requires the screenshot to actually show the theory text ("started"), which is
# exactly the check that would catch an empty same-named buffer.
echo "=== launching: isabelle jedit -l HOL Scratch.thy ==="
isabelle jedit -l HOL "$WORK/Scratch.thy" >"$OUT_DIR/jedit.log" 2>&1 &
JEDIT_PID=$!
cleanup() {
  [ -n "${JEDIT_PID:-}" ] && kill "$JEDIT_PID" 2>/dev/null || true
  # jEdit on macOS may re-exec via a launcher, so also sweep any java it left behind.
  pkill -f 'isabelle.jedit' 2>/dev/null || true
}
trap cleanup EXIT

# Best-effort window enumeration via AppleScript.  On a runner without Accessibility
# permission this returns an error, not a window list -- that is fine, we only use it to
# END THE WAIT EARLY and for diagnostics.  It NEVER gates the result (`|| true`), and its
# failure is not the package's fault.
list_windows() {
  osascript -e 'tell application "System Events" to get name of every window of (every process whose background only is false)' 2>/dev/null || true
}

echo "=== waiting for the jEdit window (up to 10 min) ==="
WAIT_TICKS=120   # x 5s
mapped=""
for i in $(seq 1 $WAIT_TICKS); do
  sleep 5
  wins="$(list_windows)"
  case "$wins" in
    *Scratch*) echo "  window mapped after ~$((i * 5))s: $wins"; mapped=1; break ;;
  esac
  # If jEdit's process is gone AND no window ever appeared, it crashed.  (If a window is
  # up, a dead launcher process is fine -- macOS apps often detach from the launcher.)
  if ! kill -0 "$JEDIT_PID" 2>/dev/null && [ -z "$wins" ]; then
    # give AppleScript-less runners a floor before declaring death
    if [ "$i" -ge 6 ]; then
      echo "::warning::jEdit launcher exited and AppleScript sees no windows after ~$((i*5))s;"
      echo "::warning::continuing to the screenshot anyway -- the shot is the real evidence."
      break
    fi
  fi
  [ $((i % 6)) -eq 0 ] && echo "  ...still waiting (${i}x5s); windows now: ${wins:-<none/appllescript-unavailable>}"
done

if [ -z "$mapped" ]; then
  echo "::warning::never confirmed a 'Scratch' window via AppleScript (it may be unavailable"
  echo "::warning::on this runner).  Taking the screenshot regardless; Claude judges the pixels."
fi

# Secondary guard against a silent HOL rebuild (primary is the ML pinning above): if
# AppleScript can see windows and one is an 'Isabelle build' progress dialog, the heap is
# not being used.  Only acted on when we actually have a window list.
wins="$(list_windows)"
case "$wins" in
  *"Isabelle build"*)
    echo "::error::an 'Isabelle build' window is open -- jEdit is REBUILDING HOL instead of"
    echo "::error::loading the shipped heap ($HEAP_ID).  Session dbs missing, or ML variant mismatch."
    screencapture -x "$SHOT" || true
    exit 1 ;;
esac

echo "=== waiting 90s for continuous checking to settle ==="
sleep 90

screencapture -x "$SHOT"
[ -s "$SHOT" ] || { echo "::error::screencapture produced no image"; exit 1; }
echo "=== screenshot: $(du -h "$SHOT" | cut -f1) ==="
echo "=== windows at screenshot time ==="
list_windows | tr ',' '\n' | sed 's/^ */  - /'

# Shared judge -- identical criteria to every other platform.
CRED_HOME="$ORIG_HOME" bash "$JUDGE" judge "$SHOT" "$OUT_DIR"
