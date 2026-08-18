// Build-time repository-root discovery shared by everything on the
// site that reads the repository directly (docs link mapping, the
// llms.txt version). The root is the directory holding lwpt.toml;
// walk up from a caller-supplied anchor because bundlers rewrite
// import.meta paths.
import fs from 'node:fs';
import path from 'node:path';

export function findRepoRoot(from) {
  let dir = from;
  for (;;) {
    if (fs.existsSync(path.join(dir, 'lwpt.toml'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error(`repository root (lwpt.toml) not found above ${from}`);
    dir = parent;
  }
}
