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

record() {
  local name="$1"
  rm -f "docs/casts/$name.cast"
  asciinema record \
    --headless \
    --window-size 80x24 \
    --idle-time-limit 2 \
    --command "bash tools/casts/demo-$name.sh" \
    --title "pascal-mcp-sdk: $name" \
    "docs/casts/$name.cast"
  echo "recorded docs/casts/$name.cast"
}

record hero
record quick-start
record images
record progress
