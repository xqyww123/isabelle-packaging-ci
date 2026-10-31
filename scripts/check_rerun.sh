#!/usr/bin/env bash
#
# The isabelle post-link re-runs the post-links of the packages that depend on isabelle
# (conda/rerun_post_links.py).  Check it end to end with a probe package whose post-link
# appends a line to $PREFIX/rerun-probe.log:
#
#   check_rerun.sh build <channel dir>                     build the probe into a local channel
#   check_rerun.sh run <conda> <channel url> <prefix>      install isabelle + probe, reinstall isabelle
#
# `build` needs rattler-build (Job B); `run` needs only conda, so Job E runs it on Windows.
# The probe never leaves CI: it is not in the conda-packages artifact.
set -euo pipefail

case "${1:-}" in
  build)
    CH=$2
    R=$(mktemp -d)
    cat > "$R/recipe.yaml" <<'EOF'
package:
  name: isabelle-rerun-probe
  version: "1.0"
build:
  noarch: generic
  script:
    interpreter: bash
    content: |
      mkdir -p "$PREFIX/bin" "$PREFIX/Scripts"
      printf '%s\n' '#!/bin/bash' 'echo ran >> "$PREFIX/rerun-probe.log"' > "$PREFIX/bin/.isabelle-rerun-probe-post-link.sh"
      printf '%s\r\n' '@echo off' '>>"%PREFIX%\rerun-probe.log" echo ran' > "$PREFIX/Scripts/.isabelle-rerun-probe-post-link.bat"
requirements:
  run:
    - isabelle
EOF
    rattler-build build --recipe "$R/recipe.yaml" --output-dir "$R/out" --no-build-id --test skip
    mkdir -p "$CH/noarch"
    cp "$R"/out/noarch/isabelle-rerun-probe-*.conda "$CH/noarch/"
    ;;
  run)
    CONDA=$2 CH=$3 ENV=$4
    lines() { [ -f "$ENV/rerun-probe.log" ] && wc -l < "$ENV/rerun-probe.log" | tr -d ' ' || echo 0; }
    "$CONDA" create -y -p "$ENV" -c "$CH" -c conda-forge --override-channels isabelle isabelle-rerun-probe
    before=$(lines)
    echo "probe post-link ran $before time(s) on install"
    [ "$before" -ge 1 ] || { echo "::error::the probe's own post-link did not run"; exit 1; }
    "$CONDA" install -y -p "$ENV" -c "$CH" -c conda-forge --override-channels --force-reinstall isabelle
    after=$(lines)
    echo "probe post-link ran $after time(s) after reinstalling isabelle"
    [ "$after" -eq $((before + 1)) ] || {
      echo "::error::reinstalling isabelle should re-run the probe's post-link once ($before -> $after)"; exit 1; }
    ;;
  *)
    sed -n '3,10p' "$0" >&2; exit 2 ;;
esac
