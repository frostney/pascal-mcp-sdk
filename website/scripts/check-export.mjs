// Post-build check of the static export (npm's postbuild hook, so it
// runs on every `npm run build`, locally and in pages.yml). The
// Markdown pipeline and the site's URLs can break without failing the
// build: tables, heading ids and every anchor were once lost because
// the fumadocs preset was not applied (issue #74), and llms.txt, the
// Markdown copies and the sitemap named URLs that 404 or redirect on
// GitHub Pages (issues #75, #76, #77). This fails the build unless
// each page's output is what its docs/ source says it should be.
//
// Usage: node scripts/check-export.mjs [export dir, default out/]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fromMarkdown } from 'mdast-util-from-markdown';
import { gfmFromMarkdown } from 'mdast-util-gfm';
import { gfm } from 'micromark-extension-gfm';
import { visit } from 'unist-util-visit';

// Mirrors basePath, siteUrl and docsContentRoute in lib/shared.ts.
const basePath = '/pascal-mcp-sdk';
const siteUrl = 'https://frostney.github.io/pascal-mcp-sdk';
const docsContentRoute = '/llms.mdx/docs';
const siteOrigin = new URL(siteUrl).origin;

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(process.argv[2] ?? path.join(here, '../out'));
const docsSource = path.resolve(here, '../../docs');
const failures = [];
const fail = (message) => failures.push(message);

const read = (file) => fs.readFileSync(file, 'utf8');
// A path relative to `from`, with / separators on every platform.
const rel = (from, file) => path.relative(from, file).split(path.sep).join('/');
const walk = (dir) =>
  fs.existsSync(dir)
    ? fs
        .readdirSync(dir, { withFileTypes: true })
        .flatMap((entry) =>
          entry.isDirectory() ? walk(path.join(dir, entry.name)) : [path.join(dir, entry.name)],
        )
    : [];
const decode = (text) =>
  text
    .replace(/&quot;/g, '"')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
const ids = (html) => new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => decode(m[1])));
const parse = (markdown) =>
  fromMarkdown(markdown, { extensions: [gfm()], mdastExtensions: [gfmFromMarkdown()] });
// The URLs of a Markdown document's links, images and definitions.
function markdownUrls(markdown) {
  const urls = [];
  visit(parse(markdown), ['link', 'image', 'definition'], (node) => {
    urls.push(node.url);
  });
  return urls;
}
const sameSet = (where, actual, expected) => {
  const missing = [...expected].filter((url) => !actual.has(url));
  const extra = [...actual].filter((url) => !expected.has(url));
  if (missing.length > 0) fail(`${where}: missing ${missing.join(', ')}`);
  if (extra.length > 0) fail(`${where}: unexpected ${extra.join(', ')}`);
};

// The export file a site path is served from, exactly as GitHub Pages
// serves it: a directory only with its trailing slash (without it, the
// URL is a 301 to the slash). undefined when nothing is served there.
function served(sitePath) {
  if (sitePath !== basePath && !sitePath.startsWith(`${basePath}/`)) return undefined;
  const route = decodeURIComponent(sitePath.slice(basePath.length));
  const file = path.join(out, route.endsWith('/') || route === '' ? `${route}/index.html` : route);
  return fs.existsSync(file) && fs.statSync(file).isFile() ? file : undefined;
}

const idCache = new Map();
// Checks that a URL on this site leads to an exported file and, with a
// fragment, to an element with that id. `where` names the referrer.
function checkSiteUrl(url, where, ownIds = new Set()) {
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
  const where = rel(out, file);
  const own = ids(html);
  for (const [, raw] of html.matchAll(/\s(?:href|src)="([^"]*)"/g)) {
    const url = decode(raw);
    if (url.startsWith('//')) continue;
    if (/^[a-z][a-z0-9+.-]*:/i.test(url) && !url.startsWith(`${siteOrigin}/`)) continue;
    checkSiteUrl(url, where, own);
  }
}

// The docs pages: every Markdown file under docs/ is one, at the route
// its path gives (docs/guides/tools.md is /docs/guides/tools/).
const pages = walk(docsSource)
  .filter((file) => file.endsWith('.md'))
  .map((source) => {
    const slug = rel(docsSource, source)
      .replace(/\.md$/, '')
      .replace(/(^|\/)index$/, '');
    return {
      source,
      slug,
      html: path.join(out, 'docs', slug, 'index.html'),
      url: `${siteUrl}/docs/${slug ? `${slug}/` : ''}`,
      copy: path.join(out, docsContentRoute, slug, 'content.md'),
      copyPath: `${basePath}${docsContentRoute}/${slug ? `${slug}/` : ''}content.md`,
    };
  });
if (pages.length === 0) fail(`no Markdown files under ${docsSource}`);

for (const page of pages) {
  const where = rel(out, page.html);
  if (!fs.existsSync(page.html)) {
    fail(`${where}: missing from the export for ${rel(docsSource, page.source)}`);
    continue;
  }
  const html = read(page.html);
  const tocStart = html.indexOf('id="nd-toc"');
  const article = tocStart < 0 ? html : html.slice(0, tocStart);
  const toc = tocStart < 0 ? '' : html.slice(tocStart);

  // 2. The tables of the page's source render as tables.
  let tables = 0;
  visit(parse(read(page.source)), 'table', () => {
    tables += 1;
  });
  const rendered = (article.match(/<table[\s>]/g) ?? []).length;
  if (rendered !== tables) fail(`${where}: ${tables} table(s) in its source, ${rendered} rendered`);

  // 3. Every heading has an id, and every h2 and h3 is in the table of
  // contents, which links to nothing else.
  const headings = [...article.matchAll(/<h([1-6])(\s[^>]*)?>/g)];
  const withoutId = headings.filter((m) => m[1] !== '1' && !/\sid="/.test(m[2] ?? '')).length;
  if (withoutId > 0) fail(`${where}: ${withoutId} heading(s) without an id`);
  const tocIds = new Set([...article.matchAll(/<h[23]\s[^>]*id="([^"]+)"/g)].map((m) => decode(m[1])));
  if (tocIds.size > 0 && tocStart < 0) fail(`${where}: ${tocIds.size} h2/h3 heading(s) but no table of contents`);
  if (tocStart >= 0) {
    const linked = new Set([...toc.matchAll(/href="#([^"]+)"/g)].map((m) => decode(m[1])));
    const articleIds = ids(article);
    const missing = [...tocIds].filter((id) => !linked.has(id));
    const stray = [...linked].filter((id) => !articleIds.has(id));
    if (missing.length > 0) fail(`${where}: table of contents lacks ${missing.join(', ')}`);
    if (stray.length > 0) fail(`${where}: table of contents links to missing ${stray.join(', ')}`);
  }

  // 4. The page actions name this page's own Markdown copy, under the
  // basePath: fumadocs-ui adds it only under Vite.
  const actionUrls = new Set(
    [...html.matchAll(/\\?"markdownUrl\\?":\\?"([^"\\]+)\\?"/g)].map((m) => m[1]),
  );
  sameSet(`${where} markdownUrl`, actionUrls, new Set([page.copyPath]));

  // 5. The JSON-LD names the page by the URL it is served at.
  const script = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
  if (!script) fail(`${where}: no JSON-LD`);
  else {
    const data = JSON.parse(script[1]);
    if (data.url !== page.url) fail(`${where} JSON-LD: url ${data.url}, expected ${page.url}`);
    if (data.isPartOf?.url !== `${siteUrl}/docs/`) fail(`${where} JSON-LD: isPartOf.url ${data.isPartOf?.url}`);
  }

  // 6. The page's Markdown copy starts with its URL, and every link in
  // it is absolute.
  if (!fs.existsSync(page.copy)) fail(`${rel(out, page.copy)}: missing from the export`);
  else if (!read(page.copy).startsWith(`URL: ${page.url}\n`)) {
    fail(`${rel(out, page.copy)}: does not start with "URL: ${page.url}"`);
  }
}

// 7. llms.txt, llms-full.txt and the Markdown copies are read outside
// the site: every link in them is absolute, and the ones to this site
// are served.
const markdownFiles = [
  path.join(out, 'llms.txt'),
  path.join(out, 'llms-full.txt'),
  ...walk(path.join(out, docsContentRoute)).filter((file) => file.endsWith('.md')),
];
for (const file of markdownFiles) {
  const where = rel(out, file);
  if (!fs.existsSync(file)) {
    fail(`${where}: missing from the export`);
    continue;
  }
  const text = read(file);
  const urls = [...markdownUrls(text), ...[...text.matchAll(/^URL: (\S+)$/gm)].map((m) => m[1])];
  for (const url of urls) {
    if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) fail(`${where}: ${url} is not an absolute URL`);
    else if (url.startsWith(`${siteOrigin}/`)) checkSiteUrl(url, where);
  }
}

// 8. llms.txt links every page's copy and llms-full.txt, each under an
// H2 (the format's file lists), and llms-full.txt holds every page.
const llms = path.join(out, 'llms.txt');
if (fs.existsSync(llms)) {
  const text = read(llms);
  const firstH2 = text.search(/^## /m);
  const beforeH2 = firstH2 < 0 ? text : text.slice(0, firstH2);
  const loose = markdownUrls(beforeH2);
  if (loose.length > 0) fail(`llms.txt: links before the first H2: ${loose.join(', ')}`);
  sameSet(
    'llms.txt',
    new Set(markdownUrls(text)),
    new Set([...pages.map((page) => `${siteOrigin}${page.copyPath}`), `${siteUrl}/llms-full.txt`]),
  );
}
const full = path.join(out, 'llms-full.txt');
if (fs.existsSync(full)) {
  const urls = [...read(full).matchAll(/^URL: (\S+)$/gm)].map((m) => m[1]);
  if (urls.length !== new Set(urls).size) fail('llms-full.txt: a page appears more than once');
  sameSet('llms-full.txt', new Set(urls), new Set(pages.map((page) => page.url)));
}

// 9. The sitemap lists the home page and every docs page by the URL it
// is served at.
const sitemap = path.join(out, 'sitemap.xml');
if (!fs.existsSync(sitemap)) fail('sitemap.xml: missing from the export');
else {
  const locs = [...read(sitemap).matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => decode(m[1]));
  sameSet('sitemap.xml', new Set(locs), new Set([`${siteUrl}/`, ...pages.map((page) => page.url)]));
  for (const loc of locs) checkSiteUrl(loc, 'sitemap.xml');
}

// 10. Every search result leads to a page and section of the export.
// The static index names pages by route; the search dialog navigates
// with Next's router, which adds the basePath and the trailing slash.
const search = path.join(out, 'api/search');
if (!fs.existsSync(search)) fail('api/search: missing from the export');
else {
  const entries = Object.values(JSON.parse(read(search)).docs.docs);
  if (entries.length === 0) fail('api/search: no entries');
  for (const entry of new Set(entries.map((doc) => doc.url))) {
    const [route, fragment] = entry.split('#');
    checkSiteUrl(`${basePath}${route.replace(/\/?$/, '/')}${fragment ? `#${fragment}` : ''}`, `api/search ${entry}`);
  }
}

if (failures.length > 0) {
  console.error(`check-export: ${failures.length} problem(s) in ${out}`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log(
  `check-export: ${htmlFiles.length} pages, ${pages.length} of them docs pages, and ` +
    `${markdownFiles.length} Markdown files OK (links, anchors, tables, heading ids, ` +
    'tables of contents, page actions, JSON-LD, llms files, sitemap, search)',
);
