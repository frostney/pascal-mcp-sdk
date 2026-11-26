// Runs the official MCP conformance suite (modelcontextprotocol/
// conformance, pinned on npm) in server mode against the Streamable
// HTTP binding of a server program started with `--http <port>`: in CI
// the conformance fixture, build/mcpconformance, which registers the
// suite's reference surface through the library's public API, then compares the per-scenario outcome with
// the committed baseline (baseline.json). By default it runs the
// suite's requirement set for the spec revision the baseline names
// (`--requirements 2026-07-28`): the scenarios that revision requires,
// at its stateless wire, plus the ones the suite runs for visibility
// without scoring. The suite only tests servers over HTTP, so the
// stdio binding is not covered here.
//
// Usage: node run.mjs <path-to-server> [extra conformance args]
//   e.g. node run.mjs build/mcpconformance --scenario tools-list
//
// Each run writes into a fresh directory of its own,
// <repo>/build/conformance/<timestamp>-<pid>/ (checks.json per
// scenario), and prints it; nothing is ever deleted, so concurrent runs
// cannot touch each other's evidence. Once results exist, the exit code
// is 1 when the run differs from the baseline (rules in compare.mjs):
// an unlisted failure or a recorded passing check that no longer passes
// (regression), a listed failure or check that now passes (stale
// baseline), a scenario added or removed, or a checks.json that is
// missing, malformed or duplicated. The suite's own exit code then
// counts only when it is neither 0 nor 1 (its two ordinary results):
// anything else, a signal included, means the suite was interrupted
// or could not run, and fails the run. Before that, operational errors
// exit non-zero too: 2 for usage or an invalid baseline or suite
// command, and 1 when the server does not start (it is stopped first)
// or no results were produced. When the runner itself is interrupted
// (SIGINT, SIGTERM, SIGHUP) it stops the suite and the server first.
//
// Selection: --scenario (in `--opt value` or `--opt=value` form) runs
// those scenarios at the baseline's revision, extensions included
// (`--force`, as the requirement set runs them); --suite runs a suite at
// that revision, which leaves out extension scenarios. Scenarios outside
// the baseline are then listed as not judged, and none count as added or
// removed. --requirements and --spec-version may only name the
// baseline's revision, and --requirements does not combine with a
// selection. The runner owns --url, --output-dir/-o and
// --expected-failures. Needs Node >= 22 (the suite's CLI uses
// fs.globSync).
//
// Test seams (run.test.mjs): CONFORMANCE_BASELINE names another
// baseline file, CONFORMANCE_RESULTS a results directory that must not
// exist yet, and CONFORMANCE_SUITE_COMMAND, a JSON array, replaces the
// `npx --yes <suite>@<version>` prefix of the suite command.

import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { constants } from 'node:os';
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
if (!demoArg) usage('usage: node run.mjs <path-to-server> [conformance args]');

// Commander accepts `--opt value` and `--opt=value`.
const has = (name) => extra.some((a) => a === `--${name}` || a.startsWith(`--${name}=`));
function optionValues(name) {
  const values = [];
  extra.forEach((arg, i) => {
    if (arg === `--${name}`) values.push(extra[i + 1] ?? '');
    else if (arg.startsWith(`--${name}=`)) values.push(arg.slice(name.length + 3));
  });
  return values;
}
const owned = extra.filter((a) => /^(--url|--output-dir|--expected-failures)(=|$)/.test(a) || /^-o/.test(a));
if (owned.length > 0)
  usage(`the runner sets the server URL, the results directory and the baseline; drop ${owned.join(' ')}`);
const revisions = [...optionValues('requirements'), ...optionValues('spec-version')];
const foreign = revisions.filter((r) => r !== baseline.requirements);
if (foreign.length > 0)
  usage(
    `baseline.json describes ${baseline.requirements}; run the suite directly (npx ${CONFORMANCE}) ` +
      `for ${foreign.join(', ')}`,
  );
if (has('requirements') && (has('scenario') || has('suite') || has('spec-version')))
  usage('--requirements runs the whole requirement set and does not combine with --scenario, --suite or --spec-version');
const narrowed = has('scenario') || has('suite') || has('spec-version');
// A narrowed run stays at the baseline's revision; without one the
// suite would pick each scenario's latest dated revision for itself.
// --force runs a selected extension scenario as the requirement set
// does instead of skipping it under the dated filter.
const selection = [];
if (!narrowed && !has('requirements')) selection.push('--requirements', baseline.requirements);
if (narrowed && !has('spec-version')) selection.push('--spec-version', baseline.requirements);
if (has('scenario') && !extra.includes('--force')) selection.push('--force');

const demo = resolve(demoArg);
const root = resolve(here, '..', '..');
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const resultsDir = process.env.CONFORMANCE_RESULTS
  ? resolve(process.env.CONFORMANCE_RESULTS)
  : resolve(root, 'build', 'conformance', `${stamp}-${process.pid}`);
mkdirSync(dirname(resultsDir), { recursive: true });
try {
  // Not recursive: the directory must be new, so it holds nothing but
  // this run's results.
  mkdirSync(resultsDir);
} catch (error) {
  usage(`cannot create a fresh results directory ${resultsDir}: ${error.message}`);
}

let server;
let suite;
let stopping = false;

// The suite runs in a process group of its own (POSIX), so stopping it
// reaches whatever it launched (npx starts the suite's binary through a
// shell, and a wrapper may add more): SIGTERM to the group, SIGKILL to
// the group if the leader has not exited after two seconds. On Windows,
// taskkill stops the tree.
function stopSuite(child) {
  return new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      if (process.platform !== 'win32') {
        try {
          process.kill(-child.pid, 'SIGTERM');
        } catch {
          // the group is already gone
        }
      }
      resolve();
      return;
    }
    const signalGroup = (signal) => {
      if (process.platform === 'win32') {
        spawnSync('taskkill', ['/pid', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
        return;
      }
      try {
        process.kill(-child.pid, signal);
      } catch {
        child.kill(signal);
      }
    };
    const force = setTimeout(() => signalGroup('SIGKILL'), 2000);
    child.once('exit', () => {
      clearTimeout(force);
      resolve();
    });
    signalGroup('SIGTERM');
  });
}
// Interrupted: stop the suite and the server, then exit with the signal's
// conventional status.
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(signal, async () => {
    if (stopping) return;
    stopping = true;
    console.error(`conformance: interrupted by ${signal}; stopping the suite and the server`);
    await Promise.all([suite && stopSuite(suite), server && stopChild(server)].filter(Boolean));
    process.exit(128 + constants.signals[signal]);
  });
}

const port = await freePort();
try {
  server = await startDemo(demo, port, 10000, (child) => {
    server = child;
  });
} catch (error) {
  // An interrupt during startup stops the server, which rejects here too;
  // the signal handler owns that exit.
  if (stopping) await new Promise(() => {});
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
    suite = spawn(command, [...prefixArgs, ...suiteArgs], {
      stdio: 'inherit',
      detached: process.platform !== 'win32',
    });
    suite.on('exit', (exitCode, signal) => {
      suiteSignal = signal;
      done(exitCode);
    });
    suite.on('error', (error) => {
      console.error(`conformance: failed to start the suite: ${error.message}`);
      done(127);
    });
  });
} finally {
  // startDemo's own exit listener is inert once it has settled; the
  // signal handler may be waiting on another, so none is removed.
  // After a normal finish, the suite's group is signalled too, so
  // nothing it launched outlives the run.
  if (!stopping) {
    if (suite) await stopSuite(suite);
    await stopChild(server);
  }
}
if (stopping) await new Promise(() => {}); // the signal handler exits
// 0 and 1 are the suite's ordinary results (all passed, some failed);
// anything else, a signal included (even when a wrapper turns it into
// 128 + n), means the run was cut short or never ran.
if (suiteSignal || (suiteCode !== 0 && suiteCode !== 1)) {
  console.error(`conformance: the suite did not finish normally (${suiteSignal ?? `exit ${suiteCode}`})`);
  process.exit(1);
}

// One directory per scenario: server-<scenario>-<ISO timestamp>.
// A missing, malformed or duplicated checks.json is a broken run,
// never an ordinary failure: it would otherwise match an expected `fail`.
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
console.log(`conformance: results in ${resultsDir}`);

if (actual.size === 0) {
  console.error(`conformance: no scenario results found (suite exit ${suiteCode})`);
  process.exit(1);
}

const result = compare(baseline, actual, narrowed);

const outcomes = [...actual.values()].filter((v) => !v.error);
const tally = (o) => outcomes.filter((v) => v.outcome === o).length;
console.log(
  `\nconformance baseline (${CONFORMANCE}): ${actual.size} scenarios run, ` +
    `${tally('pass')} passing, ${tally('fail')} failing, ${tally('skip')} skipped`,
);
const sections = [
  ['UNREADABLE: checks.json missing, malformed or duplicated', result.unreadable],
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
