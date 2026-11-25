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

// The site's JavaScript carries asciinema-player (Apache-2.0) and the
// Solid runtime it bundles (MIT); both licences ask that recipients
// get a copy of them. Every player links this one file
// (components/terminal-cast.tsx).
const licenses = path.resolve(here, '../public/licenses');
fs.mkdirSync(licenses, { recursive: true });
const notice = [
  ['asciinema-player', '../node_modules/asciinema-player/LICENSE'],
  ['solid-js (bundled by asciinema-player)', '../node_modules/solid-js/LICENSE'],
]
  .map(([name, file]) => `${name}\n${'='.repeat(name.length)}\n\n${fs.readFileSync(path.resolve(here, file), 'utf8').trim()}\n`)
  .join('\n\n');
fs.writeFileSync(path.join(licenses, 'terminal-player.txt'), notice);
console.log('licenses: wrote the terminal player notices');
