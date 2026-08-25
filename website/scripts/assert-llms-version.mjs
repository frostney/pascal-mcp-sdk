// Fail the export if the authored llms.txt citation card does not
// carry the exact version from lwpt.toml. Runs after next build.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findRepoRoot } from '../lib/repo-root.mjs';
import { basePath } from '../lib/site-identity.mjs';

const websiteRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const repoRoot = findRepoRoot(websiteRoot);
const manifest = path.join(repoRoot, 'lwpt.toml');
const match = /^version\s*=\s*"([^"]+)"/m.exec(fs.readFileSync(manifest, 'utf8'));
if (!match) throw new Error(`no version = "..." line in ${manifest}`);
const version = match[1];
const needle = `Version ${version}`;

const candidates = [
  path.join(websiteRoot, 'out', 'llms.txt'),
  path.join(websiteRoot, 'out', 'llms.txt', 'index.html'),
  path.join(websiteRoot, 'out', basePath.replace(/^\//, ''), 'llms.txt'),
];
const found = candidates.find((file) => fs.existsSync(file));
if (!found) {
  throw new Error(`exported llms.txt not found; looked in ${candidates.join(', ')}`);
}
const body = fs.readFileSync(found, 'utf8');
if (!body.includes(needle)) {
  throw new Error(`${found} does not contain ${JSON.stringify(needle)}`);
}
console.log(`llms.txt ${found} contains ${needle}`);
