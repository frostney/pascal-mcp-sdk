// Broken-input tests for the conformance baseline comparator.
// Run: node --test tools/conformance/compare.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyChecks, compare, differs, validateBaseline } from './compare.mjs';

const ok = (id) => ({ id, status: 'SUCCESS' });
const bad = (id) => ({ id, status: 'FAILURE' });

const baseline = {
  scenarios: {
    ping: { expected: 'fail', issue: 70 },
    'dns-rebinding-protection': {
      expected: 'fail',
      issue: 70,
      passingChecks: ['localhost-host-rebinding-rejected'],
    },
  },
};

const run = (results, narrowed = false) =>
  compare(baseline, new Map(Object.entries(results).map(([k, v]) => [k, classifyChecks(v)])), narrowed);

const current = {
  ping: [bad('ping')],
  'dns-rebinding-protection': [ok('localhost-host-rebinding-rejected'), bad('localhost-host-valid-accepted')],
};

test('current results match the baseline', () => {
  assert.equal(differs(run(current)), false);
});

test('invalid checks.json content is unreadable, not an outcome', () => {
  for (const [label, checks] of [
    ['not an array', { status: 'FAILURE' }],
    ['empty', []],
    ['null entry', [null]],
    ['empty object', [{}]],
    ['missing id', [{ status: 'FAILURE' }]],
    ['missing status', [{ id: 'x' }]],
    ['unknown status', [{ id: 'x', status: 'PASSED' }]],
    ['mixed valid and invalid', [bad('ping'), { notStatus: 'corrupt' }]],
    ['one id both passing and failing', [bad('ping'), ok('ping')]],
  ]) {
    const r = run({ ...current, ping: checks });
    assert.equal(r.unreadable.length, 1, label);
    assert.equal(differs(r), true, label);
  }
});

test('narrowed runs report no added or removed scenarios', () => {
  const r = run({ 'json-schema-2020-12': [ok('schema')], ping: [bad('ping')] }, true);
  assert.deepEqual([r.added, r.removed], [[], []]);
  assert.equal(r.unjudged.length, 1);
  assert.equal(differs(r), false);
});

test('full runs still report added and removed scenarios', () => {
  const r = run({ 'json-schema-2020-12': [ok('schema')], ping: [bad('ping')] });
  assert.equal(r.added.length, 1);
  assert.deepEqual(r.removed, ['dns-rebinding-protection']);
  assert.equal(differs(r), true);
});

test('a recorded passing check that fails is a regression', () => {
  const r = run({
    ...current,
    'dns-rebinding-protection': [bad('localhost-host-rebinding-rejected'), bad('localhost-host-valid-accepted')],
  });
  assert.equal(r.regressions.length, 1);
  assert.equal(differs(r), true);
});

test('a newly passing check in an expected-fail scenario is stale', () => {
  const r = run({ ...current, ping: [bad('ping'), ok('new-check')] });
  assert.equal(r.stale.length, 1);
  assert.equal(differs(r), true);
});

test('an expected-fail scenario that passes is stale', () => {
  const r = run({ ...current, ping: [ok('ping')] });
  assert.ok(r.stale.some((s) => s.startsWith('ping (')));
});

test('an expected-fail scenario that fully recovers is one stale entry', () => {
  const r = run({
    ...current,
    'dns-rebinding-protection': [ok('localhost-host-rebinding-rejected'), ok('localhost-host-valid-accepted')],
  });
  assert.deepEqual(r.stale, ['dns-rebinding-protection (issue #70): now passes']);
});

test('repeated reports of a check that agree are fine, and SKIPPED does not fail', () => {
  const r = classifyChecks([ok('probe'), ok('probe'), { id: 'later', status: 'SKIPPED' }]);
  assert.equal(r.outcome, 'pass');
  assert.deepEqual([...r.passing], ['probe']);
});

const valid = {
  suite: '@modelcontextprotocol/conformance',
  version: '0.2.0-alpha.12',
  requirements: '2026-07-28',
  scenarios: {
    'tools-list': { expected: 'pass' },
    ping: { expected: 'fail', issue: 70, passingChecks: ['a'] },
  },
};

test('a well-formed baseline has no problems', () => {
  assert.deepEqual(validateBaseline(valid), []);
});

test('a malformed baseline is rejected before any comparison', () => {
  const withScenario = (scenario) => ({ ...valid, scenarios: { ...valid.scenarios, x: scenario } });
  for (const [label, baselineValue] of [
    ['not an object', []],
    ['no version', { ...valid, version: undefined }],
    ['no requirement set', { ...valid, requirements: '' }],
    ['no scenarios', { ...valid, scenarios: {} }],
    ['misspelled expectation', withScenario({ expected: 'fial', issue: 70 })],
    ['null expectation', withScenario({ expected: null })],
    ['expected failure without issue', withScenario({ expected: 'fail' })],
    ['expected pass with issue', withScenario({ expected: 'pass', issue: 70 })],
    ['passingChecks not a list', withScenario({ expected: 'fail', issue: 70, passingChecks: 'a' })],
    ['passingChecks on a pass', withScenario({ expected: 'pass', passingChecks: ['a'] })],
    ['duplicate passingChecks', withScenario({ expected: 'fail', issue: 70, passingChecks: ['a', 'a'] })],
  ]) {
    assert.notDeepEqual(validateBaseline(baselineValue), [], label);
  }
});
