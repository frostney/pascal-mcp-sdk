# Shared helpers for the cast demo scripts. Sourced, not executed.
#
# Every command shown is executed for real against the binaries
# lwpt build produced — the recordings are genuine terminal sessions
# (CONTEXT.md: staged or synthesized animations are not terminal
# recordings). The helpers only handle presentation: printing the
# command line the way a prompt would, and pacing so playback is
# readable.

# Print a dim comment line.
say() {
  printf '\033[2m# %s\033[0m\n' "$*"
  sleep 1.2
}

# Print the command like a prompt line, then execute it for real. The
# child shell fails on any failing pipeline stage, so a failing mcpdemo
# behind a successful jq stops the demo (the demo scripts run under
# `set -e`) instead of being recorded as a working example.
# The command is kept for `expect`.
run() {
  CAST_LAST_COMMAND="$*"
  printf '\033[1;32m❯\033[0m %s\n' "$*"
  sleep 0.9
  bash -o pipefail -c "$*"
  sleep 1.4
}

# Fail the demo unless the server's raw response to the last command
# satisfies a jq filter over its JSON-RPC lines (slurped into one
# array). It runs that command again without its display projection
# (the trailing `| jq ...`), because a JSON-RPC error or an isError
# result exits 0 and the projection hides it. Prints nothing on
# success, so it adds nothing to the recording.
expect() {
  local raw="${CAST_LAST_COMMAND%| jq*}"
  if ! bash -o pipefail -c "$raw" | jq -e -s "$1" >/dev/null; then
    echo "cast demo: the response does not satisfy: $1" >&2
    exit 1
  fi
}

# The modern per-request _meta envelope every 2026-07-28 request
# carries (see docs/internals/architecture.md).
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"cast-demo","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}'
