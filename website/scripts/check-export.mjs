// Post-build assertions on the static export. The markdown pipeline
// can silently lose whole feature classes (macro-mode mdxOptions
// replaces the fumadocs preset — tables, heading anchors, and TOCs
// all shipped broken once without any gate noticing), so the build
// fails unless the rendered HTML actually contains what the docs
// rely on. Runs via the postbuild npm hook, locally and in CI.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, '../out');
const failures = [];

function page(rel) {
  const file = path.join(out, rel, 'index.html');
  if (!fs.existsSync(file)) {
    failures.push(`${rel}: page missing from export`);
    return '';
  }
  return fs.readFileSync(file, 'utf8');
}

function assert(cond, message) {
  if (!cond) failures.push(message);
}

// GFM tables (remarkGfm): the reference pages are table-heavy.
for (const rel of ['docs/reference/protocol-coverage', 'docs/reference/server']) {
  const html = page(rel);
  assert(html.includes('<table'), `${rel}: no <table> — remarkGfm missing?`);
  assert(!/<p>\|[^<]*\|/.test(html), `${rel}: literal pipe-row paragraph — table not parsed`);
}

// Heading anchors (remarkHeading) + populated TOCs (rehypeToc) on
// every exported docs page.
const docsRoot = path.join(out, 'docs');
const walk = (dir) =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? walk(path.join(dir, entry.name)) : [],
  ).concat(fs.existsSync(path.join(dir, 'index.html')) ? [dir] : []);
for (const dir of walk(docsRoot)) {
  const rel = path.relative(out, dir);
  if (rel === 'docs') continue; // the docs index page has no h2 sections
  const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
  if (!html.includes('<h2')) continue;
  assert(/<h2 id="/.test(html), `${rel}: <h2> without id — remarkHeading missing?`);
}

// Repo-only records stay off the site.
assert(!fs.existsSync(path.join(out, 'docs/adr')), 'docs/adr rendered — loader exclusion lost');

// Build-time Mermaid: the architecture page renders every fence
// twice (light + dark), nothing left as a raw fence.
const architecture = page('docs/internals/architecture');
const lightSvgs = (architecture.match(/id="mermaid-light-\d+"/g) ?? []).length;
const darkSvgs = (architecture.match(/id="mermaid-dark-\d+"/g) ?? []).length;
assert(lightSvgs > 0, 'architecture: no light Mermaid SVGs rendered');
assert(lightSvgs === darkSvgs, `architecture: ${lightSvgs} light vs ${darkSvgs} dark Mermaid SVGs`);
assert(!architecture.includes('language-mermaid'), 'architecture: unrendered mermaid fence');

// Terminal recordings: every page that embeds a cast has the player
// figure, and the referenced .cast files were synced into the export.
for (const rel of ['', 'docs/guides/quick-start', 'docs/guides/images', 'docs/guides/progress-and-logging']) {
  assert(page(rel).includes('terminal-cast'), `${rel || 'home'}: terminal-cast figure missing`);
}
for (const cast of ['hero', 'quick-start', 'images', 'progress']) {
  assert(
    fs.existsSync(path.join(out, 'docs-casts', `${cast}.cast`)),
    `docs-casts/${cast}.cast missing from export`,
  );
}

if (failures.length > 0) {
  console.error('check-export: FAILED');
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log('check-export: rendered output OK (tables, anchors, mermaid, casts)');
