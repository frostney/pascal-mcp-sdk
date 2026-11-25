// Link mapping for rendering the repository's docs/ tree directly
// (issue #6): links that stay inside docs/ become site routes; links
// that leave the rendered set (README.md, CONTRIBUTING.md, source
// paths, ...) resolve to their GitHub URLs. Every mapped target is
// checked against the working tree — a broken mapping fails the build.
// Each mapped node also records its absolute URL for the page's
// Markdown copy (see stringifyAbsoluteLinks below).
import path from 'node:path';
import fs from 'node:fs';
import { visit } from 'unist-util-visit';
import { defaultHandlers } from 'mdast-util-to-markdown';

const githubBase = 'https://github.com/frostney/pascal-mcp-sdk';

// Walk up from the processed file to the repository root (the
// directory holding lwpt.toml) — bundlers rewrite import.meta paths,
// so the anchor must come from the file being processed.
function findRepoRoot(from) {
  let dir = from;
  for (;;) {
    if (fs.existsSync(path.join(dir, 'lwpt.toml'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir)
      throw new Error(`repository root not found above ${from}`);
    dir = parent;
  }
}

// The site route of a docs/ Markdown file: docs/guides/tools.md is
// /docs/guides/tools/, docs/index.md is /docs/.
function pageRoute(file, docsRoot) {
  const slug = path
    .relative(docsRoot, file)
    .split(path.sep)
    .join('/')
    .replace(/\.md$/, '')
    .replace(/(^|\/)index$/, '');
  return `/docs/${slug}${slug ? '/' : ''}`;
}

function mapHref(href, filePath) {
  const repoRoot = findRepoRoot(path.dirname(filePath));
  const docsRoot = path.join(repoRoot, 'docs');
  if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('#')) {
    return href; // absolute URL or in-page anchor
  }
  const [target, hash] = href.split('#');
  const suffix = hash ? '#' + hash : '';
  const resolved = path.resolve(path.dirname(filePath), target);
  if (!fs.existsSync(resolved)) {
    throw new Error(
      `broken link "${href}" in ${path.relative(repoRoot, filePath)}: ` +
        `${path.relative(repoRoot, resolved)} does not exist`,
    );
  }
  if (path.relative(repoRoot, resolved).startsWith('..')) {
    throw new Error(
      `link "${href}" in ${path.relative(repoRoot, filePath)} ` +
        'leaves the repository',
    );
  }
  const fromDocs = path.relative(docsRoot, resolved);
  if (!fromDocs.startsWith('..') && resolved.endsWith('.md')) {
    // Stays inside the rendered set: site route.
    return `${pageRoute(resolved, docsRoot)}${suffix}`;
  }
  // Leaves the rendered set: GitHub URL.
  const repoRelative = path.relative(repoRoot, resolved);
  const kind = fs.statSync(resolved).isDirectory() ? 'tree' : 'blob';
  return `${githubBase}/${kind}/main/${repoRelative}${suffix}`;
}

// Images under docs/images/ are copied into the site's public/ tree
// by scripts/sync-docs-assets.mjs (prebuild); the markdown's relative
// path is rewritten to that served location, basePath included (plain
// <img> src attributes don't get the Next basePath automatically).
// Mirrors basePath in lib/shared.ts / next.config.mjs.
const basePath = '/pascal-mcp-sdk';
// Mirrors the origin of siteUrl in lib/shared.ts.
const siteOrigin = 'https://frostney.github.io';

// The absolute URL of a mapped link or image, for the page's Markdown
// copy, which is read outside the site: a site route (/docs/...) gains
// the origin and the basePath, a served file (/pascal-mcp-sdk/...) the
// origin, and a section of the same page (#section) the page's own
// URL. Anything else is already absolute.
function absoluteUrl(url, filePath) {
  if (url.startsWith('#')) {
    const docsRoot = path.join(findRepoRoot(path.dirname(filePath)), 'docs');
    return `${siteOrigin}${basePath}${pageRoute(filePath, docsRoot)}${url}`;
  }
  if (url.startsWith(`${basePath}/`)) return `${siteOrigin}${url}`;
  if (url.startsWith('/')) return `${siteOrigin}${basePath}${url}`;
  return undefined;
}

function recordAbsoluteUrl(node, filePath) {
  const url = absoluteUrl(node.url, filePath);
  if (url) (node.data ??= {}).absoluteUrl = url;
}

function mapImage(src, filePath) {
  if (/^[a-z][a-z0-9+.-]*:/i.test(src) || src.startsWith('#')) return src;
  const repoRoot = findRepoRoot(path.dirname(filePath));
  const resolved = path.resolve(path.dirname(filePath), src);
  if (!fs.existsSync(resolved)) {
    throw new Error(
      `broken image "${src}" in ${path.relative(repoRoot, filePath)}: ` +
        `${path.relative(repoRoot, resolved)} does not exist`,
    );
  }
  const fromImages = path.relative(path.join(repoRoot, 'docs', 'images'), resolved);
  if (fromImages.startsWith('..')) {
    throw new Error(
      `image "${src}" in ${path.relative(repoRoot, filePath)} ` +
        'must live under docs/images/ to be served by the site',
    );
  }
  return `${basePath}/docs-images/${fromImages}`;
}

export function remarkRepoLinks() {
  return (tree, file) => {
    // Definitions referenced by reference-style images (`![alt][id]`)
    // must map as images, not links — their URL becomes the rendered
    // <img> src.
    const imageDefinitions = new Set();
    visit(tree, 'imageReference', (node) => {
      imageDefinitions.add(node.identifier);
    });
    visit(tree, ['link', 'definition'], (node) => {
      if (node.type === 'definition' && imageDefinitions.has(node.identifier)) {
        node.url = mapImage(node.url, file.path);
      } else {
        node.url = mapHref(node.url, file.path);
      }
      recordAbsoluteUrl(node, file.path);
    });
    visit(tree, 'image', (node) => {
      node.url = mapImage(node.url, file.path);
      recordAbsoluteUrl(node, file.path);
    });
  };
}

// The `stringify` hook for fumadocs' processed Markdown (the Markdown
// copies and llms-full.txt): writes each link, image and definition
// with the absolute URL remarkRepoLinks recorded, so the copies work
// outside the site while the HTML keeps its site routes (issue #75).
export function stringifyAbsoluteLinks(node, parent, state, info) {
  const url = node.data?.absoluteUrl;
  if (!url) return undefined;
  switch (node.type) {
    case 'link':
    case 'image':
    case 'definition':
      return defaultHandlers[node.type]({ ...node, url }, parent, state, info);
  }
  return undefined;
}
