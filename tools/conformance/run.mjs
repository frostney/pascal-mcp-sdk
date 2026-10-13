// Runs the official MCP conformance suite (modelcontextprotocol/
// conformance, pinned on npm) in server mode against mcpdemo's
// Streamable HTTP binding, then compares the per-scenario outcome with
// the committed baseline (baseline.json). The suite only tests servers
// over HTTP, so the stdio binding is not covered here.
//
// Usage: node run.mjs <path-to-mcpdemo> [extra conformance args]
//   e.g. node run.mjs ../../build/mcpdemo --scenario server-initialize
//
// Results land in <repo>/build/conformance/results/ (checks.json per
// scenario). The exit code is non-zero ONLY when the run differs from
// the baseline: an unlisted failure (regression), a listed failure that
// now passes (stale baseline), or a scenario added or removed. Passing
// --scenario/--suite narrows the run, so the added/removed check is
// skipped then. Needs Node >= 22 (the 0.1.16 CLI uses fs.globSync).

import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { freePort, startDemo } from '../interop-ts/demo-http.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const baseline = JSON.parse(readFileSync(join(here, 'baseline.json'), 'utf8'));
// Exact pin, read from the baseline so the version and its expected
// results cannot drift apart.
const CONFORMANCE = `${baseline.suite}@${baseline.version}`;

const [demoArg, ...extra] = process.argv.slice(2);
if (!demoArg) {
  console.error('usage: node run.mjs <path-to-mcpdemo> [conformance args]');
  process.exit(2);
}
const demo = resolve(demoArg);
const root = resolve(here, '..', '..');
const resultsDir = resolve(root, 'build', 'conformance', 'results');
rmSync(resultsDir, { recursive: true, force: true });
mkdirSync(resultsDir, { recursive: true });

const port = await freePort();
const server = await startDemo(demo, port);
server.stderr.pipe(process.stderr);
const url = `http://127.0.0.1:${port}/mcp`;
console.log(`conformance: ${CONFORMANCE} server --url ${url}`);

const suiteCode = await new Promise((done) => {
  const suite = spawn(
    'npx',
    ['--yes', CONFORMANCE, 'server', '--url', url, '--output-dir', resultsDir, ...extra],
    { stdio: 'inherit', shell: process.platform === 'win32' },
  );
  suite.on('exit', (exitCode, signal) => done(signal ? 1 : (exitCode ?? 1)));
  suite.on('error', (error) => {
    console.error(`conformance: failed to start npx: ${error.message}`);
    done(127);
  });
});

server.removeAllListeners('exit');
server.kill();

// One directory per scenario: server-<scenario>-<ISO timestamp>.
const actual = new Map();
for (const entry of readdirSync(resultsDir)) {
  const match = /^server-(.+)-\d{4}-\d{2}-\d{2}T.*$/.exec(entry);
  if (!match) continue;
  let checks;
  try {
    checks = JSON.parse(readFileSync(join(resultsDir, entry, 'checks.json'), 'utf8'));
  } catch {
    checks = null;
  }
  const failed = !Array.isArray(checks) || checks.some((c) => c.status === 'FAILURE');
  actual.set(match[1], failed ? 'fail' : 'pass');
}

if (actual.size === 0) {
  console.error(`conformance: no scenario results found (suite exit ${suiteCode})`);
  process.exit(suiteCode || 1);
}

const expected = new Map(
  Object.entries(baseline.scenarios).map(([name, s]) => [name, s.expected]),
);
const narrowed = extra.some((a) => a === '--scenario' || a === '--suite');
const regressions = [];
const stale = [];
const added = [];
const removed = [];
for (const [name, outcome] of actual) {
  if (!expected.has(name)) {
    added.push(`${name} (${outcome})`);
    if (outcome === 'fail') regressions.push(`${name} (not in baseline)`);
  } else if (outcome === 'fail' && expected.get(name) === 'pass') {
    regressions.push(name);
  } else if (outcome === 'pass' && expected.get(name) === 'fail') {
    stale.push(`${name} (issue #${baseline.scenarios[name].issue})`);
  }
}
if (!narrowed)
  for (const name of expected.keys()) if (!actual.has(name)) removed.push(name);

const passing = [...actual.values()].filter((o) => o === 'pass').length;
console.log(
  `\nconformance baseline (${CONFORMANCE}): ${actual.size} scenarios run, ` +
    `${passing} passing, ${actual.size - passing} failing`,
);
const sections = [
  ['REGRESSION: failing, not expected to fail', regressions],
  ['STALE BASELINE: expected to fail, now passing (update baseline.json)', stale],
  ['ADDED: scenario not in baseline.json', added],
  ['REMOVED: in baseline.json, not run', removed],
];
let differs = false;
for (const [title, list] of sections) {
  if (list.length === 0) continue;
  differs = true;
  console.log(`\n${title}:`);
  for (const item of list) console.log(`  - ${item}`);
}
console.log(differs ? '\nconformance: results DIFFER from the baseline' : 'conformance: results match the baseline');
process.exit(differs ? 1 : 0);
