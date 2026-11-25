// End-to-end tests of run.mjs: argument handling, the default
// requirement set, result discovery, exit codes and process cleanup,
// with a stand-in mcpdemo and a stand-in suite (fixtures/). The stand-in
// suite only writes results after reaching the URL run.mjs gives it, so
// a run that never started mcpdemo, or pointed the suite elsewhere,
// cannot pass.
// Run: node --test tools/conformance/run.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const fakeDemo = join(here, 'fixtures', 'fake-demo.mjs');
const fakeSuite = join(here, 'fixtures', 'fake-suite.mjs');

const baseline = {
  suite: '@modelcontextprotocol/conformance',
  version: '0.2.0-alpha.12',
  requirements: '2026-07-28',
  scenarios: {
    'tools-list': { expected: 'pass' },
    'completion-complete': { expected: 'fail', issue: 81, passingChecks: ['wire-schema-valid'] },
  },
};
const ok = (id) => ({ id, status: 'SUCCESS' });
const bad = (id) => ({ id, status: 'FAILURE' });
const matching = {
  'tools-list': [ok('tools-list')],
  'completion-complete': [bad('completion-complete'), ok('wire-schema-valid')],
};

const read = (file) => {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return undefined;
  }
};

// The environment and files of one runner invocation in a fresh
// directory; `results` must not exist yet, as run.mjs requires.
function setUp({ results = matching, baselineValue = baseline, demoMode, env = {} }) {
  const dir = mkdtempSync(join(tmpdir(), 'conformance-run-'));
  const baselineFile = join(dir, 'baseline.json');
  writeFileSync(baselineFile, JSON.stringify(baselineValue));
  const files = {
    dir,
    results: join(dir, 'results'),
    suiteArgs: join(dir, 'suite-args.json'),
    suitePid: join(dir, 'suite.pid'),
    demoPid: join(dir, 'demo.pid'),
  };
  files.env = {
    ...process.env,
    CONFORMANCE_BASELINE: baselineFile,
    CONFORMANCE_RESULTS: files.results,
    CONFORMANCE_SUITE_COMMAND: JSON.stringify([process.execPath, fakeSuite]),
    FAKE_SUITE_ARGS: files.suiteArgs,
    FAKE_SUITE_PID: files.suitePid,
    FAKE_SUITE_RESULTS: JSON.stringify(results),
    FAKE_DEMO_PID: files.demoPid,
    ...(demoMode ? { FAKE_DEMO_MODE: demoMode } : {}),
    ...env,
  };
  return files;
}

function observe(files, child) {
  const suiteArgs = read(files.suiteArgs);
  return {
    code: child.status,
    output: `${child.stdout}${child.stderr}`,
    suiteArgs: suiteArgs === undefined ? undefined : JSON.parse(suiteArgs),
    demoPid: Number(read(files.demoPid) ?? 0),
    suitePid: Number(read(files.suitePid) ?? 0),
  };
}

function runConformance({ extra = [], before, after, ...options } = {}) {
  const files = setUp(options);
  try {
    before?.(files);
    const child = spawnSync(process.execPath, [join(here, 'run.mjs'), fakeDemo, ...extra], {
      encoding: 'utf8',
      timeout: 30000,
      env: files.env,
    });
    after?.(files);
    return observe(files, child);
  } finally {
    rmSync(files.dir, { recursive: true, force: true });
  }
}

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

test('results that match the baseline exit 0 and run its requirement set', () => {
  const r = runConformance();
  assert.equal(r.code, 0, r.output);
  assert.match(r.output, /results match the baseline/);
  const at = r.suiteArgs.indexOf('--requirements');
  assert.equal(r.suiteArgs[at + 1], '2026-07-28');
  assert.ok(r.demoPid > 0, 'the stand-in mcpdemo did not start');
  assert.equal(alive(r.demoPid), false, 'mcpdemo still running after the run');
});

test('a regression exits 1 and names it', () => {
  const r = runConformance({ results: { ...matching, 'tools-list': [bad('tools-list')] } });
  assert.equal(r.code, 1, r.output);
  assert.match(r.output, /REGRESSION[\s\S]*tools-list/);
});

test('an unparseable checks.json exits 1 as unreadable', () => {
  const r = runConformance({ results: { ...matching, 'tools-list': '{not json' } });
  assert.equal(r.code, 1, r.output);
  assert.match(r.output, /UNREADABLE[\s\S]*tools-list/);
});

test('two result directories for one scenario are unreadable', () => {
  const r = runConformance({ env: { FAKE_SUITE_DUPLICATE: 'tools-list' } });
  assert.equal(r.code, 1, r.output);
  assert.match(r.output, /UNREADABLE[\s\S]*tools-list \(more than one result directory/);
});

test('no results at all is an operational failure', () => {
  const r = runConformance({ results: {} });
  assert.equal(r.code, 1, r.output);
  assert.match(r.output, /no scenario results found/);
});

test("the suite's ordinary failure exit is judged by the baseline", () => {
  const r = runConformance({ env: { FAKE_SUITE_EXIT: '1' } });
  assert.equal(r.code, 0, r.output);
});

for (const [label, env] of [
  ['a signal', { FAKE_SUITE_SIGNAL: 'SIGTERM' }],
  ['a wrapped signal (exit 143)', { FAKE_SUITE_EXIT: '143' }],
  ['a usage error (exit 2)', { FAKE_SUITE_EXIT: '2' }],
]) {
  test(`a suite ended by ${label} fails the run even when its results match`, () => {
    const r = runConformance({ env });
    assert.equal(r.code, 1, r.output);
    assert.match(r.output, /did not finish normally/);
    assert.ok(r.demoPid > 0);
    assert.equal(alive(r.demoPid), false, 'mcpdemo left running');
  });
}

test('an invalid baseline exits 2 before the suite runs', () => {
  const r = runConformance({ baselineValue: { ...baseline, scenarios: { 'tools-list': { expected: 'fial' } } } });
  assert.equal(r.code, 2, r.output);
  assert.match(r.output, /is invalid/);
  assert.equal(r.suiteArgs, undefined, 'the suite ran despite an invalid baseline');
});

test('an invalid suite command is refused before mcpdemo starts', () => {
  const r = runConformance({ env: { CONFORMANCE_SUITE_COMMAND: '[]' } });
  assert.equal(r.code, 2, r.output);
  assert.equal(r.demoPid, 0, 'mcpdemo was started');
});

test('a results directory that already exists is refused and left alone', () => {
  let kept;
  const r = runConformance({
    before: (files) => {
      mkdirSync(files.results);
      writeFileSync(join(files.results, 'keep.txt'), "not the runner's");
    },
    after: (files) => {
      kept = read(join(files.results, 'keep.txt'));
    },
  });
  assert.equal(r.code, 2, r.output);
  assert.match(r.output, /fresh results directory/);
  assert.equal(kept, "not the runner's", 'the existing directory was touched');
  assert.equal(r.suiteArgs, undefined);
  assert.equal(r.demoPid, 0);
});

for (const extra of [['--scenario', 'tools-list'], ['--scenario=tools-list']]) {
  test(`a scenario selection (${extra.join(' ')}) runs at the baseline's revision, extensions included`, () => {
    const r = runConformance({ extra });
    assert.equal(r.code, 0, r.output);
    assert.equal(r.suiteArgs.includes('--requirements'), false);
    const at = r.suiteArgs.indexOf('--spec-version');
    assert.equal(r.suiteArgs[at + 1], '2026-07-28');
    assert.ok(r.suiteArgs.includes('--force'), 'the selection was not forced past the dated filter');
    assert.ok(extra.every((a) => r.suiteArgs.includes(a)), 'the selector was not forwarded');
    assert.match(r.output, /1 scenarios run/);
  });
}

test('a suite selection runs at the baseline revision without forcing extensions', () => {
  const r = runConformance({ extra: ['--suite', 'core'] });
  assert.equal(r.code, 0, r.output);
  const at = r.suiteArgs.indexOf('--spec-version');
  assert.equal(r.suiteArgs[at + 1], '2026-07-28');
  assert.equal(r.suiteArgs.includes('--force'), false);
});

test('a scenario outside the baseline is listed as not judged in a narrowed run', () => {
  const r = runConformance({ results: { ping: [ok('ping')] }, extra: ['--scenario', 'ping'] });
  assert.equal(r.code, 0, r.output);
  assert.match(r.output, /NOT JUDGED[\s\S]*ping/);
});

for (const extra of [
  ['--spec-version', '2025-11-25'],
  ['--requirements=2025-11-25'],
  ['--requirements', '2026-07-28', '--scenario', 'tools-list'],
  ['--requirements=2026-07-28', '--spec-version=2026-07-28'],
  ['--url', 'http://elsewhere/mcp'],
  ['--output-dir=/somewhere'],
  ['-o', 'somewhere'],
  ['--expected-failures', 'list.yml'],
  ['--expected-failures=list.yml'],
]) {
  test(`${extra.join(' ')} is refused before anything starts`, () => {
    const r = runConformance({ extra });
    assert.equal(r.code, 2, r.output);
    assert.equal(r.suiteArgs, undefined);
    assert.equal(r.demoPid, 0, 'mcpdemo was started');
  });
}

test('mcpdemo that never listens fails the run and is stopped', () => {
  const r = runConformance({ demoMode: 'never-listen' });
  assert.equal(r.code, 1, r.output);
  assert.match(r.output, /never listened/);
  assert.equal(r.suiteArgs, undefined, 'the suite ran without a server');
  assert.ok(r.demoPid > 0, 'the stand-in mcpdemo did not start');
  assert.equal(alive(r.demoPid), false, 'mcpdemo left running after a failed start');
});

test('a runner interrupted while the suite runs stops the suite and mcpdemo', async () => {
  const files = setUp({ env: { FAKE_SUITE_SLEEP: '20000' } });
  try {
    const child = spawn(process.execPath, [join(here, 'run.mjs'), fakeDemo], { env: files.env, stdio: 'ignore' });
    const deadline = Date.now() + 15000;
    while (!existsSync(files.suitePid) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
    assert.ok(existsSync(files.suitePid), 'the suite never started');
    const exited = new Promise((resolve) => child.on('exit', (code) => resolve(code)));
    child.kill('SIGTERM');
    const code = await exited;
    assert.equal(code, 143);
    const demoPid = Number(read(files.demoPid));
    const suitePid = Number(read(files.suitePid));
    assert.ok(demoPid > 0 && suitePid > 0);
    assert.equal(alive(demoPid), false, 'mcpdemo left running');
    assert.equal(alive(suitePid), false, 'the suite left running');
  } finally {
    rmSync(files.dir, { recursive: true, force: true });
  }
});

// Sends SIGTERM to a runner once `ready` exists, then returns its exit
// code and the stand-ins' pids.
async function interruptWhen(files, ready) {
  const child = spawn(process.execPath, [join(here, 'run.mjs'), fakeDemo], { env: files.env, stdio: 'ignore' });
  const deadline = Date.now() + 15000;
  while (!existsSync(ready) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
  assert.ok(existsSync(ready), `${ready} never appeared`);
  const exited = new Promise((resolve) => child.on('exit', (code) => resolve(code)));
  child.kill('SIGTERM');
  return {
    code: await exited,
    demoPid: Number(read(files.demoPid) ?? 0),
    suitePid: Number(read(files.suitePid) ?? 0),
  };
}

test('a runner interrupted before mcpdemo is ready stops it', async () => {
  const files = setUp({ demoMode: 'never-listen' });
  try {
    const r = await interruptWhen(files, files.demoPid);
    assert.equal(r.code, 143);
    assert.ok(r.demoPid > 0);
    assert.equal(alive(r.demoPid), false, 'mcpdemo left running');
  } finally {
    rmSync(files.dir, { recursive: true, force: true });
  }
});

test('a runner interrupted while a wrapper runs the suite stops the suite behind it', async () => {
  // A shell between the runner and the suite, as npx puts one there.
  const wrapper = JSON.stringify(['/bin/sh', '-c', `"${process.execPath}" "${fakeSuite}" "$@"; true`, 'sh']);
  const files = setUp({ env: { FAKE_SUITE_SLEEP: '20000', CONFORMANCE_SUITE_COMMAND: wrapper } });
  try {
    const r = await interruptWhen(files, files.suitePid);
    assert.equal(r.code, 143);
    assert.ok(r.suitePid > 0 && r.demoPid > 0);
    // The group is signalled at once; give the suite its moment to exit.
    const deadline = Date.now() + 5000;
    while (alive(r.suitePid) && Date.now() < deadline) await new Promise((res) => setTimeout(res, 50));
    assert.equal(alive(r.suitePid), false, 'the suite behind the wrapper left running');
    assert.equal(alive(r.demoPid), false, 'mcpdemo left running');
  } finally {
    rmSync(files.dir, { recursive: true, force: true });
  }
});
