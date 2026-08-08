// Link mapping for rendering the repository's docs/ tree directly
// (issue #6): links that stay inside docs/ become site routes; links
// that leave the rendered set (README.md, CONTRIBUTING.md, source
// paths, ...) resolve to their GitHub URLs. Every mapped target is
// checked against the working tree — a broken mapping fails the build.
import path from 'node:path';
import fs from 'node:fs';
import { visit } from 'unist-util-visit';

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
  return `${githubBase}/${kind}/main/${repoRelative}${suffix}`;
}

export function remarkRepoLinks() {
  return (tree, file) => {
    visit(tree, ['link', 'definition'], (node) => {
      node.url = mapHref(node.url, file.path);
    });
  };
}
