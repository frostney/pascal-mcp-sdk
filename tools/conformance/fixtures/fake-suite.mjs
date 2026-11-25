// Stand-in for the conformance CLI in run.test.mjs. Records its
// arguments in FAKE_SUITE_ARGS, writes one checks.json per scenario of
// FAKE_SUITE_RESULTS ({ scenario: checks }) into --output-dir the way
// the suite names them, and exits with FAKE_SUITE_EXIT (default 0).
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
writeFileSync(process.env.FAKE_SUITE_ARGS, JSON.stringify(args));
const outputDir = args[args.indexOf('--output-dir') + 1];
for (const [scenario, checks] of Object.entries(JSON.parse(process.env.FAKE_SUITE_RESULTS ?? '{}'))) {
  const dir = join(outputDir, `server-${scenario}-2026-07-28T00-00-00-000Z`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'checks.json'), typeof checks === 'string' ? checks : JSON.stringify(checks));
}
process.exit(Number(process.env.FAKE_SUITE_EXIT ?? 0));
