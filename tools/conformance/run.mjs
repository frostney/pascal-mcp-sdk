// Runs the official MCP conformance suite (modelcontextprotocol/
// conformance, pinned on npm) in server mode against mcpdemo's
// Streamable HTTP binding, then compares the per-scenario outcome with
// the committed baseline (baseline.json). By default it runs the
// suite's requirement set for the spec revision the baseline names
// (`--requirements 2026-07-28`): the scenarios that revision requires,
// at its stateless wire, plus the ones the suite runs for visibility
// without scoring. The suite only tests servers over HTTP, so the
// stdio binding is not covered here.
//
// Usage: node run.mjs <path-to-mcpdemo> [extra conformance args]
//   e.g. node run.mjs ../../build/mcpdemo --scenario tools-list
//
// Results land in <repo>/build/conformance/results/ (checks.json per
// scenario). Once results exist, the exit code is 1 when the run differs
// from the baseline (rules in compare.mjs): an unlisted failure or a
// recorded passing check that no longer passes (regression), a listed
// failure or check that now passes (stale baseline), a scenario added or
// removed, or a checks.json that is missing, malformed or contradictory.
// The suite's own exit code is not used then. Before that, operational
// errors exit non-zero too: 2 for usage or an invalid baseline.json, 1
// when mcpdemo does not start (it is stopped first), and 1 or the
// suite's code when no results were produced. Passing --scenario,
// --suite, --spec-version or --requirements (in either `--opt value` or
// `--opt=value` form) replaces the default requirement set and narrows
// the run: scenarios outside the baseline are then listed as not
// judged, and none count as added or removed. Needs Node >= 22 (the
// suite's CLI uses fs.globSync).
//
// Test seams (run.test.mjs): CONFORMANCE_BASELINE names another
// baseline file, CONFORMANCE_RESULTS another results directory, and
// CONFORMANCE_SUITE_COMMAND, a JSON array, replaces the
// `npx --yes <suite>@<version>` prefix of the suite command.

import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { freePort, startDemo } from '../interop-ts/demo-http.mjs';
import { classifyChecks, compare, differs, validateBaseline } from './compare.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const baselineFile = process.env.CONFORMANCE_BASELINE ?? join(here, 'baseline.json');
let baseline;
try {
  baseline = JSON.parse(readFileSync(baselineFile, 'utf8'));
} catch (error) {
  console.error(`conformance: cannot read ${baselineFile}: ${error.message}`);
  process.exit(2);
}
const problems = validateBaseline(baseline);
if (problems.length > 0) {
  console.error(`conformance: ${baselineFile} is invalid:`);
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(2);
}
// Exact pin, read from the baseline so the version and its expected
// results cannot drift apart.
const CONFORMANCE = `${baseline.suite}@${baseline.version}`;
const suitePrefix = process.env.CONFORMANCE_SUITE_COMMAND
  ? JSON.parse(process.env.CONFORMANCE_SUITE_COMMAND)
  : ['npx', '--yes', CONFORMANCE];

const [demoArg, ...extra] = process.argv.slice(2);
if (!demoArg) {
  console.error('usage: node run.mjs <path-to-mcpdemo> [conformance args]');
  process.exit(2);
}
// Commander accepts `--opt value` and `--opt=value`; each of these
// chooses its own scenario set instead of the baseline's.
const narrowed = extra.some((a) => /^--(scenario|suite|spec-version|requirements)(=|$)/.test(a));
const selection = narrowed ? [] : ['--requirements', baseline.requirements];

const demo = resolve(demoArg);
const root = resolve(here, '..', '..');
const resultsDir = process.env.CONFORMANCE_RESULTS
  ? resolve(process.env.CONFORMANCE_RESULTS)
  : resolve(root, 'build', 'conformance', 'results');
rmSync(resultsDir, { recursive: true, force: true });
mkdirSync(resultsDir, { recursive: true });

const port = await freePort();
let server;
try {
  server = await startDemo(demo, port);
} catch (error) {
  console.error(`conformance: ${error.message}`);
  process.exit(1);
}
server.stderr.pipe(process.stderr);
const url = `http://127.0.0.1:${port}/mcp`;
const suiteArgs = ['server', '--url', url, '--output-dir', resultsDir, ...selection, ...extra];
console.log(`conformance: ${CONFORMANCE} ${suiteArgs.join(' ')}`);

const suiteCode = await new Promise((done) => {
  const [command, ...prefixArgs] = suitePrefix;
  const suite = spawn(command, [...prefixArgs, ...suiteArgs], {
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });
  suite.on('exit', (exitCode, signal) => done(signal ? 1 : (exitCode ?? 1)));
  suite.on('error', (error) => {
    console.error(`conformance: failed to start the suite: ${error.message}`);
    done(127);
  });
});

server.removeAllListeners('exit');
server.kill();

// One directory per scenario: server-<scenario>-<ISO timestamp>.
// A missing, malformed or contradictory checks.json is a broken run,
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

const result = compare(baseline, actual, narrowed);

const outcomes = [...actual.values()].filter((v) => !v.error);
const passing = outcomes.filter((v) => v.outcome === 'pass').length;
console.log(
  `\nconformance baseline (${CONFORMANCE}): ${actual.size} scenarios run, ` +
    `${passing} passing, ${outcomes.length - passing} failing`,
);
const sections = [
  ['UNREADABLE: checks.json missing, malformed or contradictory', result.unreadable],
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
