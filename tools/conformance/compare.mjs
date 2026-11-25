// Pure comparison of conformance results against baseline.json. No I/O,
// so compare.test.mjs can feed it broken inputs directly.

// The check statuses the pinned suite emits. Anything else means the
// result file is not what this comparator understands. Only FAILURE
// fails a scenario.
export const KNOWN_STATUSES = new Set(['SUCCESS', 'FAILURE', 'WARNING', 'INFO', 'SKIPPED']);

const EXPECTED = new Set(['pass', 'fail']);

// Checks the shape of a parsed baseline.json and returns the list of
// problems, empty when it is usable. A malformed expectation would
// otherwise compare as neither pass nor fail and hide every difference.
export function validateBaseline(baseline) {
  if (baseline === null || typeof baseline !== 'object' || Array.isArray(baseline))
    return ['baseline is not an object'];
  const problems = [];
  for (const key of ['suite', 'version', 'requirements'])
    if (typeof baseline[key] !== 'string' || baseline[key] === '')
      problems.push(`"${key}" is not a non-empty string`);
  const scenarios = baseline.scenarios;
  if (scenarios === null || typeof scenarios !== 'object' || Array.isArray(scenarios)) {
    problems.push('"scenarios" is not an object');
    return problems;
  }
  if (Object.keys(scenarios).length === 0) problems.push('"scenarios" is empty');
  for (const [name, want] of Object.entries(scenarios)) {
    if (want === null || typeof want !== 'object' || Array.isArray(want)) {
      problems.push(`${name}: not an object`);
      continue;
    }
    if (!EXPECTED.has(want.expected))
      problems.push(`${name}: expected is ${JSON.stringify(want.expected)}, not "pass" or "fail"`);
    if (want.expected === 'fail' && !(Number.isInteger(want.issue) && want.issue > 0))
      problems.push(`${name}: an expected failure needs its tracking issue number`);
    if (want.expected === 'pass' && want.issue !== undefined)
      problems.push(`${name}: an expected pass has no tracking issue`);
    if (want.passingChecks !== undefined) {
      if (want.expected !== 'fail')
        problems.push(`${name}: passingChecks only belong to an expected failure`);
      else if (
        !Array.isArray(want.passingChecks) ||
        want.passingChecks.some((id) => typeof id !== 'string' || id === '') ||
        new Set(want.passingChecks).size !== want.passingChecks.length
      )
        problems.push(`${name}: passingChecks is not a list of distinct check ids`);
    }
  }
  return problems;
}

// Turns one parsed checks.json into { outcome, passing } or { error }.
// An empty array, a non-object entry, a missing or empty id, an unknown
// status, or one id reported both as SUCCESS and as FAILURE is invalid
// evidence, never a pass or an expected fail. (The suite may report a
// check id several times, once per probe; that is fine while every
// report agrees on passing or failing.)
export function classifyChecks(checks) {
  if (!Array.isArray(checks)) return { error: 'checks.json is not an array' };
  if (checks.length === 0) return { error: 'checks.json is empty' };
  const passed = new Set();
  const failed = new Set();
  for (const [i, c] of checks.entries()) {
    if (c === null || typeof c !== 'object' || Array.isArray(c))
      return { error: `check ${i} is not an object` };
    if (typeof c.id !== 'string' || c.id === '')
      return { error: `check ${i} has no id` };
    if (!KNOWN_STATUSES.has(c.status))
      return { error: `check ${c.id} has unknown status ${JSON.stringify(c.status)}` };
    if (c.status === 'SUCCESS') passed.add(c.id);
    if (c.status === 'FAILURE') failed.add(c.id);
  }
  const contradictory = [...passed].filter((id) => failed.has(id));
  if (contradictory.length > 0)
    return { error: `check ${contradictory.join(', ')} reported as both SUCCESS and FAILURE` };
  return { outcome: failed.size > 0 ? 'fail' : 'pass', passing: passed };
}

// actual: Map<scenario, { outcome, passing } | { error }>.
// narrowed: the run covered fewer scenarios than the baseline's
// requirement set, so scenarios outside the baseline, and baseline
// scenarios not run, are neither added nor removed; unlisted scenarios
// are reported, not judged.
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
    // Check-level: a recorded passing check must still pass, even when
    // its scenario is an expected failure.
    const recorded = new Set(want.passingChecks ?? []);
    for (const id of recorded)
      if (!result.passing.has(id)) r.regressions.push(`${name}: check ${id} no longer passes`);
    if (want.expected === 'fail') {
      if (result.outcome === 'pass') {
        // The whole scenario recovered: one entry says so; listing each
        // newly passing check as well would only repeat it.
        r.stale.push(`${name} (issue #${want.issue}): now passes`);
        continue;
      }
      for (const id of result.passing)
        if (!recorded.has(id))
          r.stale.push(`${name}: check ${id} now passes (add it to passingChecks)`);
    }
  }
  if (!narrowed)
    for (const name of Object.keys(baseline.scenarios))
      if (!actual.has(name)) r.removed.push(name);
  return r;
}

export function differs(r) {
  return ['unreadable', 'regressions', 'stale', 'added', 'removed'].some((k) => r[k].length > 0);
}
