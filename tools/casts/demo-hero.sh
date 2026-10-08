#!/usr/bin/env bash
# Homepage hero session: build the demo server, call a tool the way
# an MCP client does. Recorded by record-all.sh; run from repo root.
set -euo pipefail
source tools/casts/lib.sh

say 'a real MCP server, compiled from Pascal'
run 'lwpt build'
say 'speak the protocol to it — one JSON-RPC line in, one out'
run 'printf '\''{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello from Pascal"},'"$META"'}}\n'\'' | ./build/mcpdemo | jq .result.content'
sleep 1
