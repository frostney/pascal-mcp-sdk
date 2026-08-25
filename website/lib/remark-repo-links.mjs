// Link mapping for rendering the repository's docs/ tree directly
// (issue #6): links that stay inside docs/ become site routes; links
// that leave the rendered set (README.md, CONTRIBUTING.md, source
// paths, ...) resolve to their GitHub URLs. Every mapped target is
// checked against the working tree — a broken mapping fails the build.
import path from 'node:path';
import fs from 'node:fs';
import { visit } from 'unist-util-visit';
import { findRepoRoot } from './repo-root.mjs';
import { basePath, gitConfig, repoUrl } from './site-identity.mjs';

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
    const slug = fromDocs.replace(/\.md$/, '').replace(/(^|\/)index$/, '');
    return `/docs/${slug}${slug ? '/' : ''}${suffix}`;
  }
  // Leaves the rendered set: GitHub URL.
  const repoRelative = path.relative(repoRoot, resolved);
  const kind = fs.statSync(resolved).isDirectory() ? 'tree' : 'blob';
  return `${repoUrl}/${kind}/${gitConfig.branch}/${repoRelative}${suffix}`;
}

// Images under docs/images/ are copied into the site's public/ tree
// by scripts/sync-docs-assets.mjs (prebuild); the markdown's relative
// path is rewritten to that served location, basePath included (plain
// <img> src attributes don't get the Next basePath automatically).
// basePath comes from site-identity.mjs (same module as shared.ts
// and next.config.mjs).

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
        return;
      }
      node.url = mapHref(node.url, file.path);
    });
    visit(tree, 'image', (node) => {
      node.url = mapImage(node.url, file.path);
    });
  };
}
