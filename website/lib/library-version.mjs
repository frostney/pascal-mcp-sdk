import fs from 'node:fs';
import path from 'node:path';

// The library's release version has one authoritative source:
// `version = "x.y.z"` in the repository's lwpt.toml. Site surfaces
// that advertise a version read it from there at build time so a
// release can never leave them stale. Any failure to find or parse it
// throws — a loud build failure beats a quietly wrong citation card.
// JavaScript so the build-time card and the postbuild assertion share
// one parser.
export function libraryVersion(from = process.cwd()) {
  const manifest = path.join(findRepoRoot(from), 'lwpt.toml');
  const match = /^version\s*=\s*"([^"]+)"/m.exec(fs.readFileSync(manifest, 'utf8'));
  if (!match) throw new Error(`no version = "..." line in ${manifest}`);
  return match[1];
}

// Walk up from the build's working directory to the directory holding
// lwpt.toml (`next build` runs from website/, but do not assume it).
function findRepoRoot(from) {
  let dir = from;
  for (;;) {
    if (fs.existsSync(path.join(dir, 'lwpt.toml'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error(`repository root (lwpt.toml) not found above ${from}`);
    dir = parent;
  }
}
