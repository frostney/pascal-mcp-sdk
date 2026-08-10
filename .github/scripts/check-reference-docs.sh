#!/usr/bin/env bash
# Reference-docs drift gate: every public symbol MCP.Server.pas
# declares with an MCP or Register prefix must be mentioned somewhere
# in docs/reference/. The reference pages are hand-written; this keeps
# them honest the same way `lwpt agents --check` keeps AGENTS.md
# honest — additions to the public surface fail CI until documented.
set -euo pipefail

cd "$(dirname "$0")/../.."

UNIT=source/units/MCP.Server.pas
DOCS=docs/reference

# Public surface = the interface section, symbol names captured from
# function/procedure declarations, filtered to the consumer-facing
# prefixes (MCP* free functions and helpers, Register* methods).
symbols=$(awk '/^interface$/,/^implementation$/' "$UNIT" \
  | grep -oE '(function|procedure) +[A-Za-z0-9_]+' \
  | awk '{print $2}' \
  | grep -E '^(MCP[A-Z]|Register)' \
  | sort -u)

missing=0
for sym in $symbols; do
  if ! grep -rqw "$sym" "$DOCS"; then
    echo "undocumented public symbol: $sym (declared in $UNIT, absent from $DOCS/)"
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  echo
  echo "Add the symbol(s) to the appropriate page under $DOCS/."
  exit 1
fi

echo "reference docs cover all $(echo "$symbols" | wc -l | tr -d ' ') public MCP*/Register* symbols in $UNIT"
