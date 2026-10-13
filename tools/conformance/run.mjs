// Runs the official MCP conformance suite (modelcontextprotocol/
// conformance, pinned on npm) in server mode against mcpdemo's
// Streamable HTTP binding. The suite only tests servers over HTTP, so
// the stdio binding is not covered here.
//
// Usage: node run.mjs <path-to-mcpdemo> [extra conformance args]
//   e.g. node run.mjs ../../build/mcpdemo --scenario server-initialize
//
// Results land in <repo>/build/conformance/results/ (checks.json per
// scenario). The exit code is the suite's own: non-zero when any
// scenario fails. Needs Node >= 22 (the 0.1.16 CLI uses fs.globSync).

import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { freePort, startDemo } from '../interop-ts/demo-http.mjs';

// Exact pin: the suite changes scenarios between releases, so a moving
// tag would turn this job's result into noise.
const CONFORMANCE = '@modelcontextprotocol/conformance@0.1.16';

const [demoArg, ...extra] = process.argv.slice(2);
if (!demoArg) {
  console.error('usage: node run.mjs <path-to-mcpdemo> [conformance args]');
  process.exit(2);
}
const demo = resolve(demoArg);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const outDir = resolve(root, 'build', 'conformance');
const resultsDir = resolve(outDir, 'results');
mkdirSync(resultsDir, { recursive: true });

const port = await freePort();
const server = await startDemo(demo, port);
server.stderr.pipe(process.stderr);
const url = `http://127.0.0.1:${port}/mcp`;
console.log(`conformance: ${CONFORMANCE} server --url ${url}`);

const code = await new Promise((done) => {
  const suite = spawn(
    'npx',
    ['--yes', CONFORMANCE, 'server', '--url', url, '--output-dir', resultsDir, ...extra],
    { cwd: outDir, stdio: 'inherit', shell: process.platform === 'win32' },
  );
  suite.on('exit', (exitCode, signal) => done(signal ? 1 : (exitCode ?? 1)));
  suite.on('error', (error) => {
    console.error(`conformance: failed to start npx: ${error.message}`);
    done(127);
  });
});

server.removeAllListeners('exit');
server.kill();
process.exit(code);
