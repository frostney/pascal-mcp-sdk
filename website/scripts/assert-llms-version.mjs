// Fail the export if the authored llms.txt citation card does not
// carry the exact version from lwpt.toml. Runs after next build.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { libraryVersion } from '../lib/library-version.mjs';
import { basePath } from '../lib/site-identity.mjs';

const websiteRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const version = libraryVersion(websiteRoot);

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Exact token: "Version 2.0.0" must not accept "Version 2.0.0-beta".
// Sentence punctuation after the token is allowed; semver
// pre-release or build suffixes are not.
const token = new RegExp(
  `(^|[\\s>])Version ${escapeRegExp(version)}(?![0-9A-Za-z+-])`,
);

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
if (!token.test(body)) {
  throw new Error(`${found} does not advertise the exact token Version ${JSON.stringify(version)}`);
}
console.log(`llms.txt ${found} contains Version ${version}`);
