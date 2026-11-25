// End-to-end tests of run.mjs: argument handling, the default
// requirement set, result discovery, exit codes and process cleanup,
// with a stand-in mcpdemo and a stand-in suite (fixtures/).
// Run: node --test tools/conformance/run.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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

function runConformance({ results = matching, baselineValue = baseline, demoMode, extra = [] } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'conformance-run-'));
  try {
    const baselineFile = join(dir, 'baseline.json');
    writeFileSync(baselineFile, JSON.stringify(baselineValue));
    const argsFile = join(dir, 'suite-args.json');
    const pidFile = join(dir, 'demo.pid');
    const child = spawnSync(process.execPath, [join(here, 'run.mjs'), fakeDemo, ...extra], {
      encoding: 'utf8',
      timeout: 30000,
      env: {
        ...process.env,
        CONFORMANCE_BASELINE: baselineFile,
        CONFORMANCE_RESULTS: join(dir, 'results'),
        CONFORMANCE_SUITE_COMMAND: JSON.stringify([process.execPath, fakeSuite]),
        FAKE_SUITE_ARGS: argsFile,
        FAKE_SUITE_RESULTS: JSON.stringify(results),
        FAKE_DEMO_PID: pidFile,
        ...(demoMode ? { FAKE_DEMO_MODE: demoMode } : {}),
      },
    });
    const read = (file) => {
      try {
        return readFileSync(file, 'utf8');
      } catch {
        return undefined;
      }
    };
    const suiteArgs = read(argsFile);
    return {
      code: child.status,
      output: `${child.stdout}${child.stderr}`,
      suiteArgs: suiteArgs === undefined ? undefined : JSON.parse(suiteArgs),
      demoPid: Number(read(pidFile)),
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
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
  assert.equal(alive(r.demoPid), false, 'mcpdemo still running after the run');
});

test('a regression exits 1 and names it', () => {
  const r = runConformance({ results: { ...matching, 'tools-list': [bad('tools-list')] } });
  assert.equal(r.code, 1, r.output);
  assert.match(r.output, /REGRESSION[\s\S]*tools-list/);
});

test('a contradictory checks.json exits 1 as unreadable', () => {
  const r = runConformance({
    results: { ...matching, 'tools-list': [ok('tools-list'), bad('tools-list')] },
  });
  assert.equal(r.code, 1, r.output);
  assert.match(r.output, /UNREADABLE[\s\S]*tools-list/);
});

test('an unparseable checks.json exits 1 as unreadable', () => {
  const r = runConformance({ results: { ...matching, 'tools-list': '{not json' } });
  assert.equal(r.code, 1, r.output);
  assert.match(r.output, /UNREADABLE[\s\S]*tools-list/);
});

test('no results at all is an operational failure', () => {
  const r = runConformance({ results: {} });
  assert.equal(r.code, 1, r.output);
  assert.match(r.output, /no scenario results found/);
});

test('an invalid baseline exits 2 before the suite runs', () => {
  const r = runConformance({
    baselineValue: { ...baseline, scenarios: { 'tools-list': { expected: 'fial' } } },
  });
  assert.equal(r.code, 2, r.output);
  assert.match(r.output, /is invalid/);
  assert.equal(r.suiteArgs, undefined, 'the suite ran despite an invalid baseline');
});

test('a scenario selection replaces the requirement set and judges no additions', () => {
  const r = runConformance({
    results: { ping: [ok('ping')] },
    extra: ['--scenario', 'ping'],
  });
  assert.equal(r.code, 0, r.output);
  assert.equal(r.suiteArgs.includes('--requirements'), false);
  assert.match(r.output, /NOT JUDGED[\s\S]*ping/);
});

test('mcpdemo that never listens fails the run and is stopped', () => {
  const r = runConformance({ demoMode: 'never-listen' });
  assert.equal(r.code, 1, r.output);
  assert.match(r.output, /never listened/);
  assert.equal(r.suiteArgs, undefined, 'the suite ran without a server');
  assert.ok(r.demoPid > 0, 'the stand-in mcpdemo did not start');
  assert.equal(alive(r.demoPid), false, 'mcpdemo left running after a failed start');
});
