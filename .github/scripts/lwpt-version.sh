#!/usr/bin/env bash
# Prints the lwpt release CI installs: the exact version of the
# `testing` dependency in lwpt.toml. testing resolves from the same
# release tag as the toolchain binary (AGENTS.md), so that one exact
# version pins both, and a bump edits lwpt.toml, not the workflows.
# Fails unless it finds exactly one MAJOR.MINOR.PATCH version there.
set -euo pipefail
manifest="${1:-lwpt.toml}"
versions=$(sed -n 's/^testing = { source = "frostney\/lwpt", version = "\([^"]*\)".*/\1/p' "$manifest")
if [ "$(printf '%s\n' "$versions" | grep -c .)" -ne 1 ] ||
   ! printf '%s\n' "$versions" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "lwpt-version: no single exact testing version in $manifest (found: '${versions}')" >&2
  exit 1
fi
printf '%s\n' "$versions"
