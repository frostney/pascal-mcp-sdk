import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { libraryVersion } from '../lib/library-version.mjs';

// Postbuild gate: the exported citation card must advertise exactly
// the version lwpt.toml declares. The card derives the value at build
// time, so this catches the remaining failure mode — a stale or
// missing export shipping under a newer manifest.
const websiteDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const cardPath = path.join(websiteDir, 'out', 'llms.txt');
const card = fs.readFileSync(cardPath, 'utf8');
const expected = `Version ${libraryVersion(websiteDir)}.`;
if (!card.includes(expected)) {
  throw new Error(`${cardPath} does not advertise "${expected}"`);
}
console.log(`llms.txt advertises ${expected}`);
