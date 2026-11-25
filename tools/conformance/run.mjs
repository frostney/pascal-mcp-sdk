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
//   e.g. node run.mjs build/mcpdemo --scenario tools-list
//
// Results land in <repo>/build/conformance/results/ (checks.json per
// scenario). Once results exist, the exit code is 1 when the run differs
// from the baseline (rules in compare.mjs): an unlisted failure or a
// recorded passing check that no longer passes (regression), a listed
// failure or check that now passes (stale baseline), a scenario added or
// removed, or a checks.json that is missing, malformed, contradictory or
// duplicated. The suite's own exit code is not used then, unless a signal
// ended it. Before that, operational errors exit non-zero too: 2 for
// usage, an invalid baseline or suite command, or a results directory
// another run holds; 1 when mcpdemo does not start (it is stopped first),
// when a signal ended the suite, and 1 or the suite's code when no results
// were produced.
//
// Selection: --scenario or --suite (in `--opt value` or `--opt=value`
// form) narrows the run to fewer scenarios, still at the baseline's spec
// revision; scenarios outside the baseline are then listed as not
// judged, and none count as added or removed. --requirements or
// --spec-version may only name the baseline's own revision: another
// revision runs a different wire that this baseline does not describe.
// The runner owns --url and --output-dir/-o. Needs Node >= 22 (the
// suite's CLI uses fs.globSync).
//
// Test seams (run.test.mjs): CONFORMANCE_BASELINE names another
// baseline file, CONFORMANCE_RESULTS another results directory, and
// CONFORMANCE_SUITE_COMMAND, a JSON array, replaces the
// `npx --yes <suite>@<version>` prefix of the suite command.

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync, writeSync, closeSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { freePort, startDemo, stopChild } from '../interop-ts/demo-http.mjs';
import { classifyChecks, compare, differs, validateBaseline } from './compare.mjs';

const usage = (message) => {
  console.error(`conformance: ${message}`);
  process.exit(2);
};

const here = dirname(fileURLToPath(import.meta.url));
const baselineFile = process.env.CONFORMANCE_BASELINE ?? join(here, 'baseline.json');
let baseline;
try {
  baseline = JSON.parse(readFileSync(baselineFile, 'utf8'));
} catch (error) {
  usage(`cannot read ${baselineFile}: ${error.message}`);
}
const problems = validateBaseline(baseline);
if (problems.length > 0) usage(`${baselineFile} is invalid:\n${problems.map((p) => `  - ${p}`).join('\n')}`);
// Exact pin, read from the baseline so the version and its expected
// results cannot drift apart.
const CONFORMANCE = `${baseline.suite}@${baseline.version}`;

// The npm CLI that ships with this node, run as `node npx-cli.js ...`
// so no shell ever parses the arguments (on Windows npx is a .cmd file,
// which needs one). Falls back to `npx` on PATH elsewhere.
function suiteCommand() {
  if (process.env.CONFORMANCE_SUITE_COMMAND) {
    let command;
    try {
      command = JSON.parse(process.env.CONFORMANCE_SUITE_COMMAND);
    } catch {
      command = undefined;
    }
    if (!Array.isArray(command) || command.length === 0 || command.some((a) => typeof a !== 'string' || a === ''))
      usage('CONFORMANCE_SUITE_COMMAND is not a JSON array of non-empty strings');
    return command;
  }
  const bin = dirname(process.execPath);
  const npxCli = [
    join(bin, 'node_modules', 'npm', 'bin', 'npx-cli.js'),
    join(bin, '..', 'lib', 'node_modules', 'npm', 'bin', 'npx-cli.js'),
  ].find((candidate) => existsSync(candidate));
  if (npxCli) return [process.execPath, npxCli, '--yes', CONFORMANCE];
  if (process.platform === 'win32') usage(`npm's npx-cli.js not found next to ${process.execPath}`);
  return ['npx', '--yes', CONFORMANCE];
}
const suitePrefix = suiteCommand();

const [demoArg, ...extra] = process.argv.slice(2);
if (!demoArg) usage('usage: node run.mjs <path-to-mcpdemo> [conformance args]');

// Commander accepts `--opt value` and `--opt=value`.
function optionValues(name) {
  const values = [];
  extra.forEach((arg, i) => {
    if (arg === `--${name}`) values.push(extra[i + 1] ?? '');
    else if (arg.startsWith(`--${name}=`)) values.push(arg.slice(name.length + 3));
  });
  return values;
}
const owned = extra.filter((a) => /^(--url|--output-dir)(=|$)/.test(a) || /^-o/.test(a));
if (owned.length > 0) usage(`the runner sets the server URL and results directory; drop ${owned.join(' ')}`);
const revisions = [...optionValues('requirements'), ...optionValues('spec-version')];
const foreign = revisions.filter((r) => r !== baseline.requirements);
if (foreign.length > 0)
  usage(
    `baseline.json describes ${baseline.requirements}; run the suite directly (npx ${CONFORMANCE}) ` +
      `for ${foreign.join(', ')}`,
  );
const narrowed = extra.some((a) => /^--(scenario|suite|spec-version)(=|$)/.test(a));
// A narrowed run still runs at the baseline's revision; without one the
// suite would pick each scenario's latest dated revision for itself.
const selection = narrowed
  ? revisions.length > 0
    ? []
    : ['--spec-version', baseline.requirements]
  : revisions.length > 0
    ? []
    : ['--requirements', baseline.requirements];

const demo = resolve(demoArg);
const root = resolve(here, '..', '..');
const resultsDir = process.env.CONFORMANCE_RESULTS
  ? resolve(process.env.CONFORMANCE_RESULTS)
  : resolve(root, 'build', 'conformance', 'results');

// One run per results directory: each run clears it first, so a second
// run would erase the first one's evidence. The lock names its owner's
// pid; a lock whose owner has exited is taken over.
const lockFile = `${resultsDir}.lock`;
mkdirSync(dirname(lockFile), { recursive: true });
function takeLock() {
  try {
    const fd = openSync(lockFile, 'wx');
    writeSync(fd, String(process.pid));
    closeSync(fd);
    return true;
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
  const owner = Number(readFileSync(lockFile, 'utf8'));
  try {
    if (owner > 0) process.kill(owner, 0);
    return false;
  } catch {
    rmSync(lockFile, { force: true });
    return takeLock();
  }
}
if (!takeLock()) usage(`another run is using ${resultsDir} (${lockFile})`);
process.on('exit', () => rmSync(lockFile, { force: true }));

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

let suiteCode;
let suiteSignal = null;
try {
  suiteCode = await new Promise((done) => {
    const [command, ...prefixArgs] = suitePrefix;
    const suite = spawn(command, [...prefixArgs, ...suiteArgs], { stdio: 'inherit' });
    suite.on('exit', (exitCode, signal) => {
      suiteSignal = signal;
      done(exitCode ?? 1);
    });
    suite.on('error', (error) => {
      console.error(`conformance: failed to start the suite: ${error.message}`);
      done(127);
    });
  });
} finally {
  server.removeAllListeners('exit');
  await stopChild(server);
}
if (suiteSignal) {
  // Interrupted: whatever results exist are incomplete.
  console.error(`conformance: the suite was ended by ${suiteSignal}`);
  process.exit(1);
}

// One directory per scenario: server-<scenario>-<ISO timestamp>.
// A missing, malformed, contradictory or duplicated checks.json is a
// broken run, never an ordinary failure: it would otherwise match an
// expected `fail`.
const actual = new Map();
for (const entry of readdirSync(resultsDir).sort()) {
  const match = /^server-(.+)-\d{4}-\d{2}-\d{2}T.*$/.exec(entry);
  if (!match) continue;
  if (actual.has(match[1])) {
    actual.set(match[1], { error: 'more than one result directory for this scenario' });
    continue;
  }
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
const tally = (o) => outcomes.filter((v) => v.outcome === o).length;
console.log(
  `\nconformance baseline (${CONFORMANCE}): ${actual.size} scenarios run, ` +
    `${tally('pass')} passing, ${tally('fail')} failing, ${tally('skip')} skipped`,
);
const sections = [
  ['UNREADABLE: checks.json missing, malformed, contradictory or duplicated', result.unreadable],
  ['REGRESSION: failing or no longer tested, or a recorded passing check no longer passes', result.regressions],
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
