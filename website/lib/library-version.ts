import fs from 'node:fs';
import path from 'node:path';
import { findRepoRoot } from './repo-root.mjs';

// The library's release version has one authoritative source:
// `version = "x.y.z"` in the repository's lwpt.toml. Site surfaces
// that advertise an exact version read it from there at build time so
// a release can never leave them stale. Any failure to find or parse
// it throws — a loud build failure beats a quietly wrong citation card.
export function libraryVersion(): string {
  const manifest = path.join(findRepoRoot(process.cwd()), 'lwpt.toml');
  const match = /^version\s*=\s*"([^"]+)"/m.exec(fs.readFileSync(manifest, 'utf8'));
  if (!match) throw new Error(`no version = "..." line in ${manifest}`);
  return match[1];
}
