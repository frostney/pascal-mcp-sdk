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
// scenario). Once results exist, the exit code is 1 when the run differs
// from the baseline (rules in compare.mjs): an unlisted failure or a
// recorded passing check that no longer passes (regression), a listed
// failure or check that now passes (stale baseline), a scenario added or
// removed, or a checks.json that is missing, malformed or schema-invalid. The suite's own
// exit code is not used then. Before that, operational errors exit
// non-zero too: 2 for usage, 1 or the suite's code when no results were
// produced, and an uncaught error if mcpdemo fails to start. Passing
// --scenario, --suite or --spec-version (in either `--opt value` or
// `--opt=value` form) narrows the run: scenarios outside the baseline
// are then listed as not judged, and none count as added or removed. Needs Node >= 22 (the 0.1.16 CLI uses fs.globSync).

import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { freePort, startDemo } from '../interop-ts/demo-http.mjs';
import { classifyChecks, compare, differs } from './compare.mjs';

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
// A missing, malformed or schema-invalid checks.json is a broken run,
// never an ordinary failure: it would otherwise match an expected `fail`.
const actual = new Map();
for (const entry of readdirSync(resultsDir)) {
  const match = /^server-(.+)-\d{4}-\d{2}-\d{2}T.*$/.exec(entry);
  if (!match) continue;
  let checks;
  try {
    checks = JSON.parse(readFileSync(join(resultsDir, entry, 'checks.json'), 'utf8'));
  } catch (error) {
    actual.set(match[1], { error: error.message });
    continue;
  }
  actual.set(match[1], classifyChecks(checks));
}

if (actual.size === 0) {
  console.error(`conformance: no scenario results found (suite exit ${suiteCode})`);
  process.exit(suiteCode || 1);
}

// Commander accepts `--opt value` and `--opt=value`; each of these can
// shrink the scenario set.
const narrowed = extra.some((a) => /^--(scenario|suite|spec-version)(=|$)/.test(a));
const result = compare(baseline, actual, narrowed);

const outcomes = [...actual.values()].filter((v) => !v.error);
const passing = outcomes.filter((v) => v.outcome === 'pass').length;
console.log(
  `\nconformance baseline (${CONFORMANCE}): ${actual.size} scenarios run, ` +
    `${passing} passing, ${outcomes.length - passing} failing`,
);
const sections = [
  ['UNREADABLE: checks.json missing, malformed or schema-invalid', result.unreadable],
  ['REGRESSION: failing, or a recorded passing check no longer passes', result.regressions],
  ['STALE BASELINE: now passing (update baseline.json)', result.stale],
  ['ADDED: scenario not in baseline.json', result.added],
  ['REMOVED: in baseline.json, not run', result.removed],
];
for (const [title, list] of sections) {
  if (list.length === 0) continue;
  console.log(`\n${title}:`);
  for (const item of list) console.log(`  - ${item}`);
}
if (result.unjudged.length > 0) {
  console.log('\nNOT JUDGED (narrowed run, scenario not in baseline.json):');
  for (const item of result.unjudged) console.log(`  - ${item}`);
}
const bad = differs(result);
console.log(bad ? '\nconformance: results DIFFER from the baseline' : '\nconformance: results match the baseline');
process.exit(bad ? 1 : 0);
