// Broken-input tests for the conformance baseline comparator.
// Run: node --test tools/conformance/compare.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyChecks, compare, differs } from './compare.mjs';

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
