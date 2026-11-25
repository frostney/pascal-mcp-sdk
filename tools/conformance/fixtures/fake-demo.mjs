#!/usr/bin/env node
// Stand-in for mcpdemo in run.test.mjs: `fake-demo.mjs --http <port>`.
// Writes its pid to FAKE_DEMO_PID, prints the banner mcpdemo prints,
// and listens on the port unless FAKE_DEMO_MODE is `never-listen`.
import { writeFileSync } from 'node:fs';
import { createServer } from 'node:net';

const port = Number(process.argv[process.argv.indexOf('--http') + 1]);
if (process.env.FAKE_DEMO_PID) writeFileSync(process.env.FAKE_DEMO_PID, String(process.pid));
process.stderr.write(`mcpdemo listening on http://127.0.0.1:${port}/mcp\n`);
if (process.env.FAKE_DEMO_MODE === 'never-listen') setInterval(() => {}, 1000);
else createServer((socket) => socket.end()).listen(port, '127.0.0.1');
