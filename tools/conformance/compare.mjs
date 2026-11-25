// Pure comparison of conformance results against baseline.json. No I/O,
// so compare.test.mjs can feed it broken inputs directly.

// The check statuses the pinned suite emits. Anything else means the
// result file is not what this comparator understands. Only FAILURE
// fails a scenario.
export const KNOWN_STATUSES = new Set(['SUCCESS', 'FAILURE', 'WARNING', 'INFO', 'SKIPPED']);

// pass: at least one check succeeded and none failed; fail: a check
// failed; skip: the suite ran the scenario but every check was skipped
// or informational, so it proved nothing either way.
const EXPECTED = new Set(['pass', 'fail', 'skip']);
// An exact SemVer version, pre-releases included, as npm reads one:
// numeric parts without leading zeros and within Number.MAX_SAFE_INTEGER,
// at most 256 characters (npm treats anything else as a dist-tag, which
// can float).
const EXACT_VERSION =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?$/;
function isExactVersion(version) {
  // npm reads a longer string as a tag, whatever its shape.
  if (version.length > 256) return false;
  const match = EXACT_VERSION.exec(version);
  return match !== null && match.slice(1, 4).every((part) => Number(part) <= Number.MAX_SAFE_INTEGER);
}

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
  if (typeof baseline.version === 'string' && baseline.version !== '' && !isExactVersion(baseline.version))
    problems.push(`"version" ${JSON.stringify(baseline.version)} is not an exact version`);
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
      problems.push(`${name}: expected is ${JSON.stringify(want.expected)}, not "pass", "fail" or "skip"`);
    if (want.expected !== 'pass' && !(Number.isInteger(want.issue) && want.issue > 0))
      problems.push(`${name}: an expected failure or skip needs its tracking issue number`);
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
// The suite can report a check id several times, once per probe or
// subcase; as in the suite itself, the id fails when any report fails
// and passes only when some report succeeded and none failed. An empty
// array, a non-object entry, a missing or empty id, or an unknown status
// is invalid evidence, never an outcome.
export function classifyChecks(checks) {
  if (!Array.isArray(checks)) return { error: 'checks.json is not an array' };
  if (checks.length === 0) return { error: 'checks.json is empty' };
  const succeeded = new Set();
  const failed = new Set();
  for (const [i, c] of checks.entries()) {
    if (c === null || typeof c !== 'object' || Array.isArray(c))
      return { error: `check ${i} is not an object` };
    if (typeof c.id !== 'string' || c.id === '')
      return { error: `check ${i} has no id` };
    if (!KNOWN_STATUSES.has(c.status))
      return { error: `check ${c.id} has unknown status ${JSON.stringify(c.status)}` };
    if (c.status === 'SUCCESS') succeeded.add(c.id);
    if (c.status === 'FAILURE') failed.add(c.id);
  }
  const passing = new Set([...succeeded].filter((id) => !failed.has(id)));
  const outcome = failed.size > 0 ? 'fail' : succeeded.size > 0 ? 'pass' : 'skip';
  return { outcome, passing };
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
    const want = Object.hasOwn(baseline.scenarios, name) ? baseline.scenarios[name] : undefined;
    if (!want) {
      if (narrowed) {
        r.unjudged.push(`${name} (${result.outcome})`);
        continue;
      }
      r.added.push(`${name} (${result.outcome})`);
      if (result.outcome !== 'pass') r.regressions.push(`${name} (${result.outcome}, not in baseline)`);
      continue;
    }
    // A scenario that now passes where the baseline expects a failure
    // or a skip is stale; any other change of outcome loses coverage
    // or adds a failure, so it is a regression.
    if (result.outcome !== want.expected && result.outcome !== 'pass')
      r.regressions.push(`${name} (${result.outcome}, expected ${want.expected})`);
    // Check-level: a recorded passing check must still pass, even when
    // its scenario is an expected failure.
    const recorded = new Set(want.passingChecks ?? []);
    for (const id of recorded)
      if (!result.passing.has(id)) r.regressions.push(`${name}: check ${id} no longer passes`);
    if (want.expected !== 'pass') {
      if (result.outcome === 'pass') {
        // The whole scenario recovered: one entry says so; listing each
        // newly passing check as well would only repeat it.
        r.stale.push(`${name} (issue #${want.issue}): now passes`);
        continue;
      }
      // Only an expected failure that still fails can record more
      // passing checks; a skip that now fails is a regression above.
      if (want.expected === 'fail' && result.outcome === 'fail')
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
