#!/usr/bin/env bash
# Progress-and-logging session: the notification stream a request
# gets when it opts in with progressToken + logLevel. Recorded by
# record-all.sh; run from repo root.
set -euo pipefail
source tools/casts/lib.sh

say 'opt in with progressToken + logLevel, and the response is a stream'
run 'printf '\''{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"noisy hello"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"cast-demo","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/logLevel":"info","progressToken":"demo-1"}}}\n'\'' | ./build/mcpdemo | jq -c "{method: (.method // \"response\"), params: (.params // .result.content[0])}"'
say 'progress and log notifications first, the response last — same order over SSE'
sleep 1
