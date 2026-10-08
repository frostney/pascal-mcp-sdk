#!/usr/bin/env bash
# Quick-start session: build, list the tools, call one. Recorded by
# record-all.sh; run from repo root.
set -euo pipefail
source tools/casts/lib.sh

say 'build the library and the demo server'
run 'lwpt build'
say 'ask the server what it offers (tools/list)'
run 'printf '\''{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{'"$META"'}}\n'\'' | ./build/mcpdemo | jq "[.result.tools[].name]"'
say 'call the typed add tool'
run 'printf '\''{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":19,"b":23},'"$META"'}}\n'\'' | ./build/mcpdemo | jq "{text: .result.content[0].text, structured: .result.structuredContent}"'
sleep 1
