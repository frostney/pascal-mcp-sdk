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

function exactlyOne(links, predicate, description, page) {
  const matches = links.filter(predicate);
  if (matches.length !== 1) {
    throw new Error(`${page}: expected exactly one ${description}, found ${matches.length}`);
  }
  return matches[0];
}

for (const page of await exportedDocsPages(docsRoot)) {
  const html = await readFile(page, 'utf8');
  const links = linkAttributes(html);
  const canonical = exactlyOne(
    links,
    (link) => link.rel === 'canonical',
    'canonical link',
    page,
  );
  const alternate = exactlyOne(
    links,
    (link) => link.rel === 'alternate' && link.type === 'text/markdown',
    'text/markdown alternate link',
    page,
  );
  const describedBy = exactlyOne(
    links,
    (link) => link.rel === 'describedby' && link.type === 'text/plain',
    'text/plain describedby link',
    page,
  );
  const canonicalUrl = new URL(canonical.href);
  const docsMarker = canonicalUrl.pathname.indexOf('/docs/');
  if (docsMarker < 0) throw new Error(`${page}: canonical URL is outside /docs/`);
  const sitePath = canonicalUrl.pathname.slice(0, docsMarker);
  const docsPath = canonicalUrl.pathname.slice(docsMarker).replace(/\/$/, '');
  const expectedAlternate = new URL(
    `${sitePath}/llms.mdx${docsPath}/content.md`,
    canonicalUrl.origin,
  ).href;
  const expectedDescribedBy = new URL(`${sitePath}/llms.txt`, canonicalUrl.origin).href;
  if (alternate.href !== expectedAlternate) {
    throw new Error(`${page}: Markdown alternate is ${alternate.href}, expected ${expectedAlternate}`);
  }
  if (describedBy.href !== expectedDescribedBy) {
    throw new Error(`${page}: describedby is ${describedBy.href}, expected ${expectedDescribedBy}`);
  }
  await access(path.join(outputRoot, `llms.mdx${docsPath}`, 'content.md'));
}

await access(path.join(outputRoot, 'llms.txt'));
console.log('Exported docs advertise valid Markdown alternates and llms.txt coverage.');
