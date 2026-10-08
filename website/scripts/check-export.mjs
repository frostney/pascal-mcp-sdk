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
const docsSource = path.resolve(here, '../../docs');
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
// every exported docs page: every <h2> needs an id, and the page's TOC
// (the #nd-toc column, rendered after the article) must link to each.
// Build-time Mermaid on the same walk: every ```mermaid fence in the
// page's source renders to exactly one light and one dark SVG, and no
// raw fence survives.
const exportedDocs = [];
const docsRoot = path.join(out, 'docs');
const walk = (dir) =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? walk(path.join(dir, entry.name)) : [],
  ).concat(fs.existsSync(path.join(dir, 'index.html')) ? [dir] : []);
for (const dir of walk(docsRoot)) {
  const rel = path.relative(out, dir);
  const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
  const slug = rel.replace(/^docs\/?/, '');
  const sourceFile = (slug ? [`${slug}.md`, path.join(slug, 'index.md')] : ['index.md'])
    .map((candidate) => path.join(docsSource, candidate))
    .find((candidate) => fs.existsSync(candidate));
  if (sourceFile) {
    exportedDocs.push(`/${rel}`);
    const fences = (fs.readFileSync(sourceFile, 'utf8').match(/^```mermaid\s*$/gm) ?? []).length;
    const light = (html.match(/id="mermaid-light-\d+"/g) ?? []).length;
    const dark = (html.match(/id="mermaid-dark-\d+"/g) ?? []).length;
    assert(
      light === fences && dark === fences,
      `${rel}: ${fences} mermaid fence(s) but ${light} light / ${dark} dark SVGs`,
    );
    assert(!html.includes('language-mermaid'), `${rel}: unrendered mermaid fence`);
  }
  if (rel === 'docs') continue; // the docs index page has no h2 sections
  if (!html.includes('<h2')) continue;
  const tocStart = html.indexOf('id="nd-toc"');
  if (tocStart < 0) {
    failures.push(`${rel}: no TOC column rendered`);
    continue;
  }
  const toc = html.slice(tocStart);
  const article = html.slice(0, tocStart);
  const h2s = (article.match(/<h2[\s>]/g) ?? []).length;
  const ids = [...article.matchAll(/<h2 id="([^"]+)"/g)].map((m) => m[1]);
  assert(
    ids.length === h2s,
    `${rel}: ${h2s - ids.length} of ${h2s} <h2> without id — remarkHeading missing?`,
  );
  const missing = ids.filter((id) => !toc.includes(`href="#${id}"`));
  assert(
    missing.length === 0,
    `${rel}: TOC lacks links to ${missing.join(', ')} — rehypeToc missing?`,
  );
}

// Search index (remarkStructure → structuredData): every docs page in
// the static Orama export carries body text, not just its title.
const searchFile = path.join(out, 'api/search');
if (!fs.existsSync(searchFile)) {
  failures.push('api/search: static search index missing from export');
} else {
  const indexed = Object.values(JSON.parse(fs.readFileSync(searchFile, 'utf8')).docs.docs);
  const pages = new Set(indexed.filter((doc) => doc.type === 'page').map((doc) => doc.page_id));
  const withText = new Set(indexed.filter((doc) => doc.type === 'text').map((doc) => doc.page_id));
  const bare = [...pages].filter((id) => !withText.has(id));
  const unindexed = exportedDocs.filter((route) => !pages.has(route));
  assert(pages.size > 0, 'api/search: no pages indexed');
  assert(unindexed.length === 0, `api/search: exported pages missing from the index: ${unindexed.join(', ')}`);
  assert(bare.length === 0, `api/search: no body text indexed for ${bare.join(', ')}`);
}

// Repo-only records stay off the site.
assert(!fs.existsSync(path.join(out, 'docs/adr')), 'docs/adr rendered — loader exclusion lost');

// Build-time Mermaid is checked per page in the walk above; make sure
// the walk actually saw the diagram-heavy architecture page.
assert(
  exportedDocs.includes('/docs/internals/architecture'),
  'architecture: page not matched to its docs/ source — mermaid check skipped',
);

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
console.log('check-export: rendered output OK (tables, anchors, TOCs, search, mermaid, casts)');
