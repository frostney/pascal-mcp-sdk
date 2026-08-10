// Copy docs/images/** into public/docs-images/ so the statically
// exported site can serve the same image files the markdown
// references relatively (GitHub renders the relative paths natively;
// remark-repo-links rewrites them to the synced public path for the
// site). Runs via the prebuild/predev npm hooks.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const source = path.resolve(here, '../../docs/images');
const target = path.resolve(here, '../public/docs-images');

fs.rmSync(target, { recursive: true, force: true });
if (fs.existsSync(source)) {
  fs.cpSync(source, target, { recursive: true });
  console.log(`docs-images: synced ${fs.readdirSync(target).length} file(s)`);
} else {
  console.log('docs-images: no docs/images directory, nothing to sync');
}
