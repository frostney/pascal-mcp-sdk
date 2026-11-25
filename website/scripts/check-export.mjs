// Post-build check of the static export (npm's postbuild hook, so it
// runs on every `npm run build`, locally and in pages.yml). The
// Markdown pipeline and the site's URLs can break without failing the
// build: tables, heading ids and every anchor were once lost because
// the fumadocs preset was not applied (issue #74), and llms.txt, the
// Markdown copies and the sitemap named URLs that 404 or redirect on
// GitHub Pages (issues #75, #76, #77). This fails the build unless
// each page's output is what its docs/ source says it should be,
// diagrams and terminal recordings included.
//
// Usage: node scripts/check-export.mjs [export dir, default out/]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fromMarkdown } from 'mdast-util-from-markdown';
import { gfmFromMarkdown } from 'mdast-util-gfm';
import { gfm } from 'micromark-extension-gfm';
import { visit } from 'unist-util-visit';
import { isLocalCast } from '../lib/remark-casts.mjs';
import { isRepoOnlyDoc, repoOnlyDocDirs } from '../lib/remark-repo-links.mjs';

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
// The text of an mdast node, as a heading or a link label reads.
const flatten = (node) =>
  'value' in node ? node.value : (node.children ?? []).map(flatten).join('');
// The text of a Markdown document's first H1.
function title(markdown) {
  const h1 = parse(markdown).children.find((node) => node.type === 'heading' && node.depth === 1);
  return h1 ? flatten(h1) : undefined;
}
// The recordings the terminal players in some HTML play, in order, as
// absolute URLs: each player's caption links the file it plays
// (components/terminal-cast.tsx).
// A player that does not link the player's licence reads as
// '(no licence link)'.
function recordings(html) {
  return [...html.matchAll(/<figure class="terminal-cast"[\s\S]*?<\/figure>/g)].map((m) => {
    const hrefs = [...m[0].matchAll(/<a\s[^>]*href="([^"]+)"/g)].map((a) => decode(a[1]));
    if (!hrefs.includes(`${basePath}/licenses/asciinema-player.txt`)) return '(no licence link)';
    return hrefs[0] ? new URL(hrefs[0], `${siteOrigin}/`).href : '(no link)';
  });
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
// its path gives (docs/guides/tools.md is /docs/guides/tools/), except
// the repo-only records (docs/adr/), which lib/source.ts leaves off
// the site.
const pages = walk(docsSource)
  .filter((file) => file.endsWith('.md') && !isRepoOnlyDoc(rel(docsSource, file)))
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

// The repo-only records reach no page, Markdown copy or other file.
const leaked = walk(out).filter((file) =>
  rel(out, path.dirname(file))
    .split('/')
    .some((part) => repoOnlyDocDirs.includes(part)),
);
if (leaked.length > 0) fail(`repo-only docs reached the export: ${leaked.map((file) => rel(out, file)).join(', ')}`);

// asciinema-player ships in the site's JavaScript under Apache-2.0,
// so the export carries its licence, and each player links it (the
// link itself is checked with every other href in step 1).
const playerLicense = path.join(out, 'licenses', 'asciinema-player.txt');
if (!fs.existsSync(playerLicense) || !read(playerLicense).includes('Apache License')) {
  fail('licenses/asciinema-player.txt: the player licence is missing from the export');
}

// The home page plays the hero recording.
const home = path.join(out, 'index.html');
const heroUrl = `${siteUrl}/docs-casts/hero.cast`;
const homePlayers = fs.existsSync(home) ? recordings(read(home)) : [];
if (homePlayers.join(' ') !== heroUrl) {
  fail(`index.html: plays ${homePlayers.join(', ') || 'no recording'}, expected ${heroUrl}`);
}

// The llms.txt section a page is listed under: the title in the
// meta.json of its top-level docs/ folder, or of docs/ itself.
function sectionTitle(slug) {
  const folder = slug.includes('/') ? slug.split('/')[0] : '';
  const meta = path.join(docsSource, folder, 'meta.json');
  return fs.existsSync(meta) ? JSON.parse(read(meta)).title : undefined;
}

for (const page of pages) {
  const where = rel(out, page.html);
  if (!fs.existsSync(page.html)) {
    fail(`${where}: missing from the export for ${rel(docsSource, page.source)}`);
    continue;
  }
  const html = read(page.html);
  // The page's article and its table of contents, as fumadocs-ui's
  // docs layout renders them.
  const articleStart = html.indexOf('<article id="nd-page"');
  const article = articleStart < 0 ? '' : html.slice(articleStart, html.indexOf('</article>', articleStart));
  if (articleStart < 0) fail(`${where}: no <article id="nd-page">`);
  const tocStart = html.indexOf('<div id="nd-toc"');
  const toc = tocStart < 0 ? '' : html.slice(tocStart);

  // 2. The tables of the page's source render as tables.
  let tables = 0;
  visit(parse(read(page.source)), 'table', () => {
    tables += 1;
  });
  const rendered = (article.match(/<table[\s>]/g) ?? []).length;
  if (rendered !== tables) fail(`${where}: ${tables} table(s) in its source, ${rendered} rendered`);

  // Each Mermaid fence of the source renders as one light and one dark
  // SVG (lib/rehype-mermaid-dual.mjs), and no fence is left as code.
  // Each paragraph that is a lone link to a .cast file renders as the
  // terminal player (lib/remark-casts.mjs); the player's link to the
  // recording is checked with every other href in step 1.
  let fences = 0;
  page.castUrls = [];
  visit(parse(read(page.source)), ['code', 'paragraph'], (node) => {
    if (node.type === 'code' && node.lang === 'mermaid') fences += 1;
    const [only] = node.type === 'paragraph' && node.children.length === 1 ? node.children : [];
    if (only?.type === 'link' && isLocalCast(only.url)) {
      const recording = rel(path.join(docsSource, 'casts'), path.resolve(path.dirname(page.source), only.url));
      page.castUrls.push(`${siteUrl}/docs-casts/${recording}`);
    }
  });
  const light = (article.match(/\sid="mermaid-light-\d+"/g) ?? []).length;
  const dark = (article.match(/\sid="mermaid-dark-\d+"/g) ?? []).length;
  if (light !== fences || dark !== fences) {
    fail(`${where}: ${fences} Mermaid fence(s) in its source, ${light} light and ${dark} dark SVG(s) rendered`);
  }
  if (article.includes('language-mermaid')) fail(`${where}: a Mermaid fence rendered as code`);
  const sized = (article.match(/<svg\s[^>]*id="mermaid-(?:light|dark)-\d+"[^>]*--mermaid-width:[0-9.]+px/g) ?? []).length;
  if (sized !== 2 * fences) fail(`${where}: ${2 * fences - sized} diagram(s) without --mermaid-width (lib/rehype-mermaid-dual.mjs)`);
  const players = recordings(article);
  if (players.join(' ') !== page.castUrls.join(' ')) {
    fail(`${where}: its source plays ${page.castUrls.join(', ') || 'no recording'}, its players ${players.join(', ') || 'none'}`);
  }

  // 3. Every heading has an id, and the table of contents lists every
  // h2 and h3 and links only to the article's headings.
  const headings = [...article.matchAll(/<h([1-6])(\s[^>]*)?>/g)];
  const withoutId = headings.filter((m) => m[1] !== '1' && !/\sid="/.test(m[2] ?? '')).length;
  if (withoutId > 0) fail(`${where}: ${withoutId} heading(s) without an id`);
  const headingIds = (depths) =>
    new Set([...article.matchAll(new RegExp(`<h[${depths}]\\s[^>]*id="([^"]+)"`, 'g'))].map((m) => decode(m[1])));
  const tocIds = headingIds('23');
  if (tocIds.size > 0 && tocStart < 0) fail(`${where}: ${tocIds.size} h2/h3 heading(s) but no table of contents`);
  if (tocStart >= 0) {
    const linked = new Set([...toc.matchAll(/<a(?:\s[^>]*?)?\shref="#([^"]+)"/g)].map((m) => decode(m[1])));
    const articleHeadings = headingIds('1-6');
    const missing = [...tocIds].filter((id) => !linked.has(id));
    const stray = [...linked].filter((id) => !articleHeadings.has(id));
    if (missing.length > 0) fail(`${where}: table of contents lacks ${missing.join(', ')}`);
    if (stray.length > 0) fail(`${where}: table of contents links to non-headings ${stray.join(', ')}`);
  }

  // The canonical link names the page by the URL it is served at.
  const attribute = (tag, name) => tag.match(new RegExp(`\\s${name}="([^"]*)"`))?.[1];
  const canonicals = [...html.matchAll(/<link\s[^>]*>/g)]
    .map((m) => m[0])
    .filter((tag) => attribute(tag, 'rel') === 'canonical')
    .map((tag) => decode(attribute(tag, 'href') ?? ''));
  if (canonicals.length !== 1 || canonicals[0] !== page.url) {
    fail(`${where}: canonical ${canonicals.join(', ') || '(none)'}, expected ${page.url}`);
  }

  // 4. Both page actions, Copy Markdown and View Options, name this
  // page's own Markdown copy, under the basePath: fumadocs-ui adds it
  // only under Vite.
  const actionUrls = [...html.matchAll(/\\?"markdownUrl\\?":\\?"([^"\\]+)\\?"/g)].map((m) => m[1]);
  if (actionUrls.length !== 2 || actionUrls.some((url) => url !== page.copyPath)) {
    fail(`${where}: page actions name ${actionUrls.join(', ') || 'no Markdown copy'}, expected ${page.copyPath} on both`);
  }

  // 5. The JSON-LD names the page by the URL it is served at.
  const script = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
  if (!script) fail(`${where}: no JSON-LD`);
  else {
    const data = JSON.parse(script[1]);
    if (data.url !== page.url) fail(`${where} JSON-LD: url ${data.url}, expected ${page.url}`);
    if (data.isPartOf?.url !== `${siteUrl}/docs/`) fail(`${where} JSON-LD: isPartOf.url ${data.isPartOf?.url}`);
  }

  // 6. The page's Markdown copy starts with its URL, then its source's
  // H1.
  page.title = title(read(page.source));
  if (!fs.existsSync(page.copy)) fail(`${rel(out, page.copy)}: missing from the export`);
  else {
    page.copyText = read(page.copy);
    if (!page.copyText.startsWith(`URL: ${page.url}\n`)) {
      fail(`${rel(out, page.copy)}: does not start with "URL: ${page.url}"`);
    }
    const copyTitle = title(page.copyText.slice(page.copyText.indexOf('\n') + 1));
    if (copyTitle !== page.title) fail(`${rel(out, page.copy)}: H1 "${copyTitle}", its source's is "${page.title}"`);
    // Each recording the source plays is a link in the copy.
    const copyUrls = new Set(markdownUrls(page.copyText));
    const lost = page.castUrls.filter((url) => !copyUrls.has(url));
    if (lost.length > 0) fail(`${rel(out, page.copy)}: lacks the recording link ${lost.join(', ')}`);
  }
}

// 7. llms.txt, llms-full.txt and the Markdown copies are read outside
// the site: every link in them is absolute, and the ones to this site
// are served. (Each copy's URL line is checked against its page above.)
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
  for (const url of markdownUrls(text)) {
    if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) fail(`${where}: ${url} is not an absolute URL`);
    else if (url.startsWith(`${siteOrigin}/`)) checkSiteUrl(url, where);
  }
  // The site's own components, such as the terminal player, stay on
  // the site: a copy carries the Markdown its docs/ source has.
  visit(parse(text), 'html', (node) => {
    if (/^<[A-Z]/.test(node.value)) fail(`${where}: site component in the Markdown: ${node.value.slice(0, 60)}`);
  });
}

// 8. llms.txt has a list item per page, under an H2 (the format's file
// lists), that starts with a link to that page's copy labelled with its
// title, and one for llms-full.txt; nothing is linked before the first
// H2.
const llms = path.join(out, 'llms.txt');
if (fs.existsSync(llms)) {
  const tree = parse(read(llms));
  const firstH2 = tree.children.findIndex((node) => node.type === 'heading' && node.depth === 2);
  const loose = [];
  for (const node of firstH2 < 0 ? tree.children : tree.children.slice(0, firstH2)) {
    visit(node, ['link', 'definition'], (link) => {
      loose.push(link.url);
    });
  }
  if (loose.length > 0) fail(`llms.txt: links before the first H2: ${loose.join(', ')}`);
  // Each entry is listed under the H2 that owns it: the nearest heading
  // above its list, which must be an H2.
  const listed = new Set();
  let heading;
  for (const node of tree.children.slice(firstH2)) {
    if (node.type === 'heading') heading = node;
    if (node.type !== 'list') continue;
    const section = heading?.depth === 2 ? flatten(heading) : `(under an H${heading?.depth})`;
    for (const item of node.children) {
      const lead = item.children[0]?.type === 'paragraph' ? item.children[0].children[0] : undefined;
      if (lead?.type === 'link') listed.add(`${section}: ${flatten(lead)} -> ${lead.url}`);
      else fail(`llms.txt: a list item that does not start with a link: "${flatten(item).slice(0, 60)}"`);
    }
  }
  const rootSection = sectionTitle('');
  sameSet(
    'llms.txt',
    listed,
    new Set([
      ...pages.map(
        (page) => `${sectionTitle(page.slug)}: ${page.title} -> ${siteOrigin}${page.copyPath}`,
      ),
      `${rootSection}: All of the documentation in one file -> ${siteUrl}/llms-full.txt`,
    ]),
  );
}

// llms-full.txt is every page's Markdown copy, each once, joined by a
// blank line, and nothing else.
const full = path.join(out, 'llms-full.txt');
if (fs.existsSync(full) && pages.every((page) => page.copyText !== undefined)) {
  const text = read(full);
  const absent = pages.filter((page) => !text.includes(page.copyText)).map((page) => page.url);
  if (absent.length > 0) fail(`llms-full.txt: lacks the Markdown copy of ${absent.join(', ')}`);
  else {
    const joined = [...pages]
      .sort((a, b) => text.indexOf(a.copyText) - text.indexOf(b.copyText))
      .map((page) => page.copyText)
      .join('\n\n');
    if (text !== joined) fail("llms-full.txt: is not exactly the pages' Markdown copies joined by blank lines");
  }
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
    'tables of contents, diagrams, recordings, page actions, JSON-LD, llms files, sitemap, search)',
);
