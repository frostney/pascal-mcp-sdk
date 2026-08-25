// One JavaScript-compatible reader for the exact library version
// in lwpt.toml. The citation card and the postbuild assertion both
// import this so they cannot parse the manifest differently.
import fs from 'node:fs';
import path from 'node:path';
import { findRepoRoot } from './repo-root.mjs';

export function libraryVersion(from = process.cwd()) {
  const manifest = path.join(findRepoRoot(from), 'lwpt.toml');
  const match = /^version\s*=\s*"([^"]+)"/m.exec(fs.readFileSync(manifest, 'utf8'));
  if (!match) throw new Error(`no version = "..." line in ${manifest}`);
  return match[1];
}
