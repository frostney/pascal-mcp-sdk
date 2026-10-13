// Pure comparison of conformance results against baseline.json. No I/O,
// so compare.test.mjs can feed it broken inputs directly.

// The statuses the pinned 0.1.16 suite emits. Anything else means the
// result file is not what this comparator understands.
export const KNOWN_STATUSES = new Set(['SUCCESS', 'FAILURE', 'WARNING', 'INFO']);

// Turns one parsed checks.json into { outcome, passing } or { error }.
// An empty array, a non-object entry, a missing or empty id, or an
// unknown status is invalid evidence, never a pass or an expected fail.
export function classifyChecks(checks) {
  if (!Array.isArray(checks)) return { error: 'checks.json is not an array' };
  if (checks.length === 0) return { error: 'checks.json is empty' };
  for (const [i, c] of checks.entries()) {
    if (c === null || typeof c !== 'object' || Array.isArray(c))
      return { error: `check ${i} is not an object` };
    if (typeof c.id !== 'string' || c.id === '')
      return { error: `check ${i} has no id` };
    if (!KNOWN_STATUSES.has(c.status))
      return { error: `check ${c.id} has unknown status ${JSON.stringify(c.status)}` };
  }
  return {
    outcome: checks.some((c) => c.status === 'FAILURE') ? 'fail' : 'pass',
    passing: new Set(checks.filter((c) => c.status === 'SUCCESS').map((c) => c.id)),
  };
}

// actual: Map<scenario, { outcome, passing } | { error }>.
// narrowed: the run was limited by --scenario/--suite/--spec-version, so
// scenarios outside the baseline, and baseline scenarios not run, are
// neither added nor removed; unlisted scenarios are reported, not judged.
export function compare(baseline, actual, narrowed) {
  const r = { unreadable: [], regressions: [], stale: [], added: [], removed: [], unjudged: [] };
  for (const [name, result] of actual) {
    if (result.error) {
      r.unreadable.push(`${name} (${result.error})`);
      continue;
    }
    const want = baseline.scenarios[name];
    if (!want) {
      if (narrowed) {
        r.unjudged.push(`${name} (${result.outcome})`);
        continue;
      }
      r.added.push(`${name} (${result.outcome})`);
      if (result.outcome === 'fail') r.regressions.push(`${name} (not in baseline)`);
      continue;
    }
    if (result.outcome === 'fail' && want.expected === 'pass') r.regressions.push(name);
    if (result.outcome === 'pass' && want.expected === 'fail')
      r.stale.push(`${name} (issue #${want.issue})`);
    // Check-level: a recorded passing check must still pass, even when
    // its scenario is an expected failure.
    const recorded = new Set(want.passingChecks ?? []);
    for (const id of recorded)
      if (!result.passing.has(id)) r.regressions.push(`${name}: check ${id} no longer passes`);
    if (want.expected === 'fail')
      for (const id of result.passing)
        if (!recorded.has(id))
          r.stale.push(`${name}: check ${id} now passes (add it to passingChecks)`);
  }
  if (!narrowed)
    for (const name of Object.keys(baseline.scenarios))
      if (!actual.has(name)) r.removed.push(name);
  return r;
}

export function differs(r) {
  return ['unreadable', 'regressions', 'stale', 'added', 'removed'].some((k) => r[k].length > 0);
}
