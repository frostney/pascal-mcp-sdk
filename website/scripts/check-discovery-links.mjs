// Postbuild gate for the discovery surfaces in the static export:
// every rendered docs page advertises its own canonical URL, its
// Markdown alternate, and the covering llms.txt; every Markdown export
// carries exactly one H1; and llms.txt lists every exported page
// exactly once, in the right section, with local links that resolve
// under out/.
import { access, readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const websiteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputRoot = path.join(websiteRoot, 'out');
const docsRoot = path.join(outputRoot, 'docs');

async function exportedDocsPages(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const pages = [];
  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) pages.push(...(await exportedDocsPages(entryPath)));
    if (entry.isFile() && entry.name === 'index.html') pages.push(entryPath);
  }
  return pages;
}

function linkAttributes(html) {
  return [...html.matchAll(/<link\b[^>]*>/g)].map(([tag]) =>
    Object.fromEntries(
      [...tag.matchAll(/([\w:-]+)="([^"]*)"/g)].map(([, name, value]) => [name, value]),
    ),
  );
}

// HTML rel is a case-insensitive, whitespace-separated token set.
function hasRel(link, token) {
  return (link.rel ?? '').toLowerCase().split(/\s+/).includes(token);
}

function exactlyOne(links, predicate, description, page) {
  const matches = links.filter(predicate);
  if (matches.length !== 1) {
    throw new Error(`${page}: expected exactly one ${description}, found ${matches.length}`);
  }
  return matches[0];
}

// Site-local URL → exported file, or null when the URL is not local.
// Resolves relative hrefs against `base`, lets URL normalize dot
// segments, and proves the filesystem target stays under out/.
function localTarget(href, base, site) {
  const url = new URL(href, base);
  if (url.origin !== site.origin || !url.pathname.startsWith(`${site.path}/`)) return null;
  const relative = decodeURIComponent(url.pathname.slice(site.path.length + 1));
  const file = relative === '' || relative.endsWith('/') ? `${relative}index.html` : relative;
  const target = path.resolve(outputRoot, file);
  if (target !== outputRoot && !target.startsWith(`${outputRoot}${path.sep}`)) {
    throw new Error(`${href} resolves outside the export root (${target})`);
  }
  return { href: url.href, target };
}

async function assertExported(resolved, context) {
  try {
    await access(resolved.target);
  } catch {
    throw new Error(`${context}: ${resolved.href} does not resolve to an exported file (${resolved.target})`);
  }
}

const pages = await exportedDocsPages(docsRoot);
if (pages.length === 0) throw new Error(`${docsRoot}: no exported docs pages found`);

// Markdown alternate → llms.txt section it must appear in. Keyed per
// rendered page, and a page must advertise *its own* canonical (the
// route its index.html was exported at), so miswired or copied metadata
// cannot make two pages collapse onto one resource.
const expectedResources = new Map();
const seenCanonicals = new Set();
let site;
for (const page of pages) {
  // out/docs/guides/tools/index.html → /docs/guides/tools/ ; out/docs/index.html → /docs/
  const route = `/docs/${path.relative(docsRoot, path.dirname(page)).split(path.sep).filter(Boolean).join('/')}`;
  const expectedRoute = route.endsWith('/') ? route : `${route}/`;
  const html = await readFile(page, 'utf8');
  const links = linkAttributes(html);
  const canonical = exactlyOne(links, (link) => hasRel(link, 'canonical'), 'canonical link', page);
  const alternate = exactlyOne(
    links,
    (link) => hasRel(link, 'alternate') && link.type === 'text/markdown',
    'text/markdown alternate link',
    page,
  );
  const describedBy = exactlyOne(
    links,
    (link) => hasRel(link, 'describedby') && link.type === 'text/plain',
    'text/plain describedby link',
    page,
  );
  const canonicalUrl = new URL(canonical.href);
  const docsMarker = canonicalUrl.pathname.indexOf('/docs/');
  if (docsMarker < 0) throw new Error(`${page}: canonical URL is outside /docs/`);
  const sitePath = canonicalUrl.pathname.slice(0, docsMarker);
  if (canonicalUrl.pathname.slice(docsMarker) !== expectedRoute) {
    throw new Error(`${page}: canonical ${canonical.href} does not match its exported route ${expectedRoute}`);
  }
  if (seenCanonicals.has(canonical.href)) {
    throw new Error(`${page}: canonical ${canonical.href} is already claimed by another page`);
  }
  seenCanonicals.add(canonical.href);
  const prefix = `${canonicalUrl.origin}${sitePath}`;
  if (site && `${site.origin}${site.path}` !== prefix) {
    throw new Error(`${page}: canonical site prefix ${prefix} differs from ${site.origin}${site.path}`);
  }
  site = { origin: canonicalUrl.origin, path: sitePath };
  const docsPath = expectedRoute.replace(/\/$/, '');
  const expectedAlternate = `${prefix}/llms.mdx${docsPath}/content.md`;
  const expectedDescribedBy = `${prefix}/llms.txt`;
  if (alternate.href !== expectedAlternate) {
    throw new Error(`${page}: Markdown alternate is ${alternate.href}, expected ${expectedAlternate}`);
  }
  if (describedBy.href !== expectedDescribedBy) {
    throw new Error(`${page}: describedby is ${describedBy.href}, expected ${expectedDescribedBy}`);
  }
  const markdown = localTarget(alternate.href, canonical.href, site);
  await assertExported(markdown, page);
  const text = await readFile(markdown.target, 'utf8');
  const h1Count = text.split('\n').filter((line) => /^#\s/.test(line)).length;
  if (h1Count !== 1) throw new Error(`${markdown.target}: expected exactly one H1, found ${h1Count}`);
  if (expectedResources.has(alternate.href)) {
    throw new Error(`${page}: Markdown alternate ${alternate.href} is already claimed by another page`);
  }
  expectedResources.set(
    alternate.href,
    docsPath.startsWith('/docs/internals/') ? 'Optional' : 'Docs',
  );
}
if (expectedResources.size !== pages.length) {
  throw new Error(`expected one discovery resource per rendered page: ${expectedResources.size} resources for ${pages.length} pages`);
}

// llms.txt (https://llmstxt.org): H1, blockquote summary, then H2
// sections whose bullets are single Markdown links. Every bullet in the
// file is validated: bullets outside the recognized sections and extra
// links on a bullet are errors, and links are resolved against the
// deployed llms.txt URL so relative spellings and aliases are
// normalized before the exact-once and resolution checks.
const llmsTxtPath = path.join(outputRoot, 'llms.txt');
const llmsTxtUrl = `${site.origin}${site.path}/llms.txt`;
const llmsTxt = await readFile(llmsTxtPath, 'utf8');
const lines = llmsTxt.split('\n');
if (!/^#\s\S/.test(lines[0])) throw new Error(`${llmsTxtPath}: must open with an H1`);
if (!lines.some((line) => /^>\s\S/.test(line))) {
  throw new Error(`${llmsTxtPath}: missing the blockquote summary`);
}
const RECOGNIZED_SECTIONS = new Set(['Docs', 'Source', 'Optional']);
const sections = new Set();
// normalized href → sections it is linked from
const listed = new Map();
let current;
for (const line of lines) {
  const heading = /^##\s+(.+?)\s*$/.exec(line);
  if (heading) {
    current = heading[1];
    if (sections.has(current)) throw new Error(`${llmsTxtPath}: duplicate section "## ${current}"`);
    if (!RECOGNIZED_SECTIONS.has(current)) {
      throw new Error(`${llmsTxtPath}: unrecognized section "## ${current}"`);
    }
    sections.add(current);
    continue;
  }
  if (!line.startsWith('- ')) continue;
  if (current === undefined) {
    throw new Error(`${llmsTxtPath}: resource bullet before the first section: ${line}`);
  }
  const links = [...line.matchAll(/\[[^\]]*\]\(([^)\s]+)\)/g)].map((m) => m[1]);
  if (links.length !== 1 || !/^- \[[^\]]+\]\(/.test(line)) {
    throw new Error(`${llmsTxtPath}: "## ${current}" bullet must be exactly one Markdown link: ${line}`);
  }
  const href = new URL(links[0], llmsTxtUrl).href;
  listed.set(href, [...(listed.get(href) ?? []), current]);
}
for (const name of ['Docs', 'Optional']) {
  if (!sections.has(name)) throw new Error(`${llmsTxtPath}: missing "## ${name}" section`);
}
for (const [href, section] of expectedResources) {
  const where = listed.get(href) ?? [];
  if (where.length !== 1 || where[0] !== section) {
    throw new Error(
      `${llmsTxtPath}: ${href} expected exactly once under "## ${section}", found under [${where.join(', ')}]`,
    );
  }
}
for (const href of listed.keys()) {
  const resolved = localTarget(href, llmsTxtUrl, site);
  if (resolved) await assertExported(resolved, llmsTxtPath);
}

console.log(
  `Exported docs (${pages.length} pages) advertise valid Markdown alternates; llms.txt lists each once with resolving links.`,
);
