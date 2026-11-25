// Stand-in for the conformance CLI in run.test.mjs. Records its
// arguments in FAKE_SUITE_ARGS, exits 3 unless the --url it was given
// answers, then records its pid in FAKE_SUITE_PID. It then writes one checks.json
// per scenario of FAKE_SUITE_RESULTS ({ scenario: checks }) into
// --output-dir the way the suite names them; with --scenario NAME (either
// form) only that scenario. FAKE_SUITE_DUPLICATE names a scenario to
// write twice. FAKE_SUITE_SLEEP keeps it running that many ms before it
// writes anything; FAKE_SUITE_SIGNAL ends it with that signal after
// writing; otherwise it exits with FAKE_SUITE_EXIT (default 0).
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
writeFileSync(process.env.FAKE_SUITE_ARGS, JSON.stringify(args));
const value = (name) => {
  const i = args.indexOf(`--${name}`);
  if (i >= 0) return args[i + 1];
  return args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
};
try {
  await fetch(value('url'), { method: 'POST', body: '{}' });
} catch {
  process.exit(3);
}
// Written once it is genuinely running against the server, so a test
// that waits for it interrupts a live suite.
if (process.env.FAKE_SUITE_PID) writeFileSync(process.env.FAKE_SUITE_PID, String(process.pid));
if (process.env.FAKE_SUITE_SLEEP) await new Promise((r) => setTimeout(r, Number(process.env.FAKE_SUITE_SLEEP)));
const outputDir = value('output-dir');
const only = value('scenario');
const write = (scenario, checks, stamp) => {
  const dir = join(outputDir, `server-${scenario}-2026-07-28T00-00-0${stamp}-000Z`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'checks.json'), typeof checks === 'string' ? checks : JSON.stringify(checks));
};
for (const [scenario, checks] of Object.entries(JSON.parse(process.env.FAKE_SUITE_RESULTS ?? '{}'))) {
  if (only && scenario !== only) continue;
  write(scenario, checks, 0);
  if (scenario === process.env.FAKE_SUITE_DUPLICATE) write(scenario, checks, 1);
}
if (process.env.FAKE_SUITE_SIGNAL) process.kill(process.pid, process.env.FAKE_SUITE_SIGNAL);
else process.exit(Number(process.env.FAKE_SUITE_EXIT ?? 0));
