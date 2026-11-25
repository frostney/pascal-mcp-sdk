// Copy docs/images/** into public/docs-images/ so the statically
// exported site can serve the same image files the markdown
// references relatively (GitHub renders the relative paths natively;
// remark-repo-links rewrites them to the synced public path for the
// site). Runs via the prebuild/predev npm hooks.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

function sync(sourceDir, targetDir, label) {
  const source = path.resolve(here, sourceDir);
  const target = path.resolve(here, targetDir);
  fs.rmSync(target, { recursive: true, force: true });
  if (fs.existsSync(source)) {
    fs.cpSync(source, target, { recursive: true });
    console.log(`${label}: synced ${fs.readdirSync(target).length} file(s)`);
  } else {
    console.log(`${label}: no source directory, nothing to sync`);
  }
}

sync('../../docs/images', '../public/docs-images', 'docs-images');
// Terminal recordings (real captured sessions — see tools/casts/).
sync('../../docs/casts', '../public/docs-casts', 'docs-casts');

// The site ships asciinema-player (Apache-2.0) in its JavaScript, and
// the licence asks that recipients get a copy of it: every player
// links this file (components/terminal-cast.tsx).
const licenses = path.resolve(here, '../public/licenses');
fs.mkdirSync(licenses, { recursive: true });
fs.copyFileSync(
  path.resolve(here, '../node_modules/asciinema-player/LICENSE'),
  path.join(licenses, 'asciinema-player.txt'),
);
console.log('licenses: copied asciinema-player LICENSE');
