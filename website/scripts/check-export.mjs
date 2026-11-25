// Post-build check of the static export (npm's postbuild hook, so it
// runs on every `npm run build`, locally and in pages.yml). The
// Markdown pipeline and the site's URLs can break without failing the
// build: tables, heading ids and every anchor were once lost because
// the fumadocs preset was not applied (issue #74), and llms.txt, the
// Markdown copies and the sitemap named URLs that 404 or redirect on
// GitHub Pages (issues #75, #76, #77). This fails the build unless the
// export has them right.
//
// Usage: node scripts/check-export.mjs [export dir, default out/]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Mirrors basePath and siteUrl in lib/shared.ts.
const basePath = '/pascal-mcp-sdk';
const siteUrl = 'https://frostney.github.io/pascal-mcp-sdk';
const siteOrigin = new URL(siteUrl).origin;

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(process.argv[2] ?? path.join(here, '../out'));
const docsSource = path.resolve(here, '../../docs');
const failures = [];
const fail = (message) => failures.push(message);

const read = (file) => fs.readFileSync(file, 'utf8');
const walk = (dir) =>
  fs
    .readdirSync(dir, { withFileTypes: true })
    .flatMap((entry) =>
      entry.isDirectory() ? walk(path.join(dir, entry.name)) : [path.join(dir, entry.name)],
    );
const decode = (text) =>
  text
    .replace(/&quot;/g, '"')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
const ids = (html) => new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => decode(m[1])));
const idCache = new Map();

// The export file a site path is served from, exactly as GitHub Pages
// serves it: a directory only with its trailing slash (without it, the
// URL is a 301 to the slash). undefined when nothing is served there.
function served(sitePath) {
  if (sitePath !== basePath && !sitePath.startsWith(`${basePath}/`)) return undefined;
  const rel = decodeURIComponent(sitePath.slice(basePath.length));
  const file = path.join(out, rel.endsWith('/') || rel === '' ? `${rel}/index.html` : rel);
  return fs.existsSync(file) && fs.statSync(file).isFile() ? file : undefined;
}

// Checks that a URL on this site leads to an exported file and, with a
// fragment, to an element with that id. `where` names the referrer.
function checkSiteUrl(url, where, ownIds) {
  const parsed = new URL(url, `${siteOrigin}/`);
  if (parsed.origin !== siteOrigin) return;
  const fragment = decodeURIComponent(parsed.hash.slice(1));
  if (url.startsWith('#')) {
    if (fragment && !ownIds.has(fragment)) fail(`${where}: no element with id "${fragment}" for ${url}`);
    return;
  }
  const file = served(parsed.pathname);
  if (!file) {
    fail(`${where}: ${url} is not served by the export (missing, a redirect, or no basePath)`);
    return;
  }
  if (!fragment || !file.endsWith('.html')) return;
  if (!idCache.has(file)) idCache.set(file, ids(read(file)));
  if (!idCache.get(file).has(fragment)) fail(`${where}: no element with id "${fragment}" for ${url}`);
}

const htmlFiles = walk(out).filter((file) => file.endsWith('.html'));

// 1. Every href and src on every page is served, anchors included.
for (const file of htmlFiles) {
  const html = read(file);
  const where = path.relative(out, file);
  const own = ids(html);
  for (const [, raw] of html.matchAll(/\s(?:href|src)="([^"]*)"/g)) {
    const url = decode(raw);
    if (/^[a-z][a-z0-9+.-]*:/i.test(url) && !url.startsWith(siteOrigin)) continue;
    if (url.startsWith('//')) continue;
    checkSiteUrl(url, where, own);
  }
}

// 2. Each docs page renders its source's tables and gives every
// heading an id and a table-of-contents entry.
const docsPages = htmlFiles.filter((file) =>
  path.relative(out, file).match(/^docs\/(?:.*\/)?index\.html$/),
);
if (docsPages.length === 0) fail('no docs pages in the export');
for (const file of docsPages) {
  const where = path.relative(out, file);
  const slug = path.dirname(path.relative(path.join(out, 'docs'), file));
  const source = [slug === '.' ? 'index.md' : `${slug}.md`, path.join(slug, 'index.md')]
    .map((candidate) => path.join(docsSource, candidate))
    .find((candidate) => fs.existsSync(candidate));
  if (!source) {
    fail(`${where}: no docs/ source found for this page`);
    continue;
  }
  const markdown = read(source).replace(/^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}\1[^\n]*$/gm, '');
  const html = read(file);
  const tocStart = html.indexOf('id="nd-toc"');
  const article = tocStart < 0 ? html : html.slice(0, tocStart);
  const tables = (markdown.match(/^ {0,3}\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/gm) ?? []).length;
  const rendered = (article.match(/<table[\s>]/g) ?? []).length;
  if (rendered < tables) fail(`${where}: ${tables} table(s) in ${path.relative(docsSource, source)}, ${rendered} rendered`);
  if (/<p>\|[^<]*\|/.test(article)) fail(`${where}: a table row rendered as a paragraph of pipes`);
  const headings = [...article.matchAll(/<h([2-6])(\s[^>]*)?>/g)];
  const withoutId = headings.filter((m) => !/\sid="/.test(m[2] ?? '')).length;
  if (withoutId > 0) fail(`${where}: ${withoutId} of ${headings.length} heading(s) without an id`);
  const h2s = [...article.matchAll(/<h2\s[^>]*id="([^"]+)"/g)].map((m) => m[1]);
  if (h2s.length > 0) {
    if (tocStart < 0) fail(`${where}: ${h2s.length} <h2> but no table of contents`);
    else {
      const toc = html.slice(tocStart);
      const missing = h2s.filter((id) => !toc.includes(`href="#${id}"`));
      if (missing.length > 0) fail(`${where}: table of contents lacks ${missing.join(', ')}`);
    }
  }
}

// 3. The page actions fetch and link the page's Markdown copy under the
// basePath: fumadocs-ui adds it only under Vite.
for (const file of docsPages) {
  const where = path.relative(out, file);
  const html = read(file);
  const urls = [...html.matchAll(/"markdownUrl":"([^"]+)"|\\"markdownUrl\\":\\"([^"\\]+)\\"/g)].map(
    (m) => m[1] ?? m[2],
  );
  if (urls.length === 0) fail(`${where}: no markdownUrl for the page actions`);
  for (const url of new Set(urls)) checkSiteUrl(url, `${where} markdownUrl`, new Set());
}

// 4. llms.txt, llms-full.txt and the Markdown copies are read outside
// the site: every link in them is absolute, and the ones to this site
// are served. Code blocks are left out.
const markdownFiles = [
  path.join(out, 'llms.txt'),
  path.join(out, 'llms-full.txt'),
  ...walk(path.join(out, 'llms.mdx')).filter((file) => file.endsWith('.md')),
];
for (const file of markdownFiles) {
  const where = path.relative(out, file);
  if (!fs.existsSync(file)) {
    fail(`${where}: missing from the export`);
    continue;
  }
  const text = read(file).replace(/^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}\1[^\n]*$/gm, '');
  const targets = [
    ...[...text.matchAll(/\]\(\s*<?([^\s)>]+)/g)].map((m) => m[1]),
    ...[...text.matchAll(/^\s*\[[^\]]+\]:\s*<?(\S+?)>?$/gm)].map((m) => m[1]),
    ...[...text.matchAll(/^URL: (\S+)$/gm)].map((m) => m[1]),
  ];
  if (targets.length === 0) fail(`${where}: no links`);
  for (const target of targets) {
    if (!/^[a-z][a-z0-9+.-]*:/i.test(target)) fail(`${where}: ${target} is not an absolute URL`);
    else if (target.startsWith(`${siteOrigin}/`)) checkSiteUrl(target, where, new Set());
  }
}

// 5. The sitemap and the pages' JSON-LD name each page by the URL it is
// served at.
const sitemap = path.join(out, 'sitemap.xml');
const locs = fs.existsSync(sitemap) ? [...read(sitemap).matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]) : [];
if (locs.length < docsPages.length) fail(`sitemap.xml: ${locs.length} entries for ${docsPages.length} docs pages`);
for (const loc of locs) checkSiteUrl(decode(loc), 'sitemap.xml', new Set());
for (const file of docsPages) {
  const where = `${path.relative(out, file)} JSON-LD`;
  const script = read(file).match(/<script type="application\/ld\+json">([^<]+)<\/script>/);
  if (!script) {
    fail(`${where}: missing`);
    continue;
  }
  const data = JSON.parse(decode(script[1]));
  for (const url of [data.url, data.isPartOf?.url]) checkSiteUrl(url ?? '(none)', where, new Set());
}

if (failures.length > 0) {
  console.error(`check-export: ${failures.length} problem(s) in ${out}`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log(
  `check-export: ${htmlFiles.length} pages and ${markdownFiles.length} Markdown files OK ` +
    '(links, anchors, tables, heading ids, tables of contents, llms URLs, sitemap, JSON-LD)',
);
