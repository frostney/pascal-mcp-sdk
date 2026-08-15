#!/usr/bin/env bash
# Images-guide session: a tool answering with an image content block.
# Recorded by record-all.sh; run from repo root.
set -euo pipefail
source tools/casts/lib.sh

say 'the pixel tool returns an image content block (MCPImageResult)'
run 'printf '\''{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"pixel","arguments":{},'"$META"'}}\n'\'' | ./build/mcpdemo | jq .result.content'
say 'type, base64 data, and the mime type the handler chose'
sleep 1
