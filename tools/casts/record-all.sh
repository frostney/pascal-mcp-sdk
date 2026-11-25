#!/usr/bin/env bash
# Record every documentation cast as a REAL terminal session of the
# built binaries (see CONTEXT.md: staged animations are not terminal
# recordings). Maintainer-local by design — the Pages build serves
# the committed .cast files and never records.
#
# Prerequisites: lwpt (repo-pinned version), asciinema >= 3, jq.
# Usage, from the repo root:
#   bash tools/casts/record-all.sh
set -euo pipefail

for tool in lwpt asciinema jq; do
  command -v "$tool" >/dev/null || {
    echo "record-all: $tool not found on PATH" >&2
    exit 1
  }
done

mkdir -p docs/casts
lwpt build --silent

# Records into a scratch file and replaces the committed cast only
# when the demo exited 0 (--return passes its status through).
record() {
  local name="$1"
  local scratch="docs/casts/$name.cast.recording"
  rm -f "$scratch"
  if ! asciinema record \
    --headless \
    --return \
    --window-size 80x24 \
    --idle-time-limit 2 \
    --command "bash tools/casts/demo-$name.sh" \
    --title "pascal-mcp-sdk: $name" \
    "$scratch"; then
    rm -f "$scratch"
    echo "record-all: demo-$name.sh failed; docs/casts/$name.cast left as it was" >&2
    exit 1
  fi
  mv "$scratch" "docs/casts/$name.cast"
  echo "recorded docs/casts/$name.cast"
}

record hero
record quick-start
record images
record progress
