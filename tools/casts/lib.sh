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
run() {
  printf '\033[1;32m❯\033[0m %s\n' "$*"
  sleep 0.9
  bash -o pipefail -c "$*"
  sleep 1.4
}

# The modern per-request _meta envelope every 2026-07-28 request
# carries (see docs/internals/architecture.md).
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"cast-demo","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}'
