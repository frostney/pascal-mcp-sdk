// The landing page's "Protocol coverage" table, parsed at build time
// from the repository README.md — the single source of truth. This
// replaces the hand-mirrored array the page used to carry (which had
// already drifted); a README table change now flows to the site on
// the next build, and a missing/renamed section fails the build.
import fs from 'node:fs';
import path from 'node:path';

export type CoverageRow = {
  surface: string;
  marker: string;
  status: string;
};

// Walk up to the repository root (the directory holding lwpt.toml) —
// the same anchor rule remark-repo-links.mjs uses.
function findRepoRoot(from: string): string {
  let dir = from;
  for (;;) {
    if (fs.existsSync(path.join(dir, 'lwpt.toml'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir)
      throw new Error(`repository root not found above ${from}`);
    dir = parent;
  }
}

function cleanCell(cell: string): string {
  return cell.trim().replace(/`/g, '').replace(/\*\*/g, '');
}

export function readmeCoverage(): CoverageRow[] {
  const repoRoot = findRepoRoot(process.cwd());
  const readme = fs.readFileSync(path.join(repoRoot, 'README.md'), 'utf8');

  const afterHeading = readme.split(/^## Protocol coverage\s*$/m)[1];
  if (!afterHeading)
    throw new Error(
      'README.md: "## Protocol coverage" section not found — the landing page table is built from it',
    );
  const section = afterHeading.split(/^## /m)[0];

  const rows: CoverageRow[] = [];
  for (const line of section.split('\n')) {
    const match = line.match(/^\s*\|(.+)\|(.+)\|\s*$/);
    if (!match) continue;
    const surface = cleanCell(match[1]);
    const statusCell = cleanCell(match[2]);
    if (surface === 'Surface') continue; // header row
    if (/^[-\s:]+$/.test(surface)) continue; // separator row
    const statusMatch = statusCell.match(/^(\S+)\s*(.*)$/s);
    if (!statusMatch) continue;
    rows.push({
      surface,
      marker: statusMatch[1],
      status: statusMatch[2],
    });
  }

  if (rows.length === 0)
    throw new Error(
      'README.md: "## Protocol coverage" table parsed to zero rows',
    );
  return rows;
}
