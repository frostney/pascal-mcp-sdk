// Terminal recordings in the docs: a paragraph consisting of a single
// link to a `.cast` file under docs/casts/ becomes the self-hosted
// asciinema player on the site, while GitHub renders the same
// markdown as an ordinary link to the recording file.
//
//   [Watch: the quick start in a terminal](../casts/quick-start.cast)
//
// Runs BEFORE remark-repo-links, which would otherwise try to route
// the .cast path as a docs page. The cast files themselves are synced
// into public/docs-casts/ by scripts/sync-docs-assets.mjs, mirroring
// the docs-images flow (and like there, the served URL carries the
// Next basePath explicitly).
import fs from 'node:fs';
import path from 'node:path';
import { visit } from 'unist-util-visit';

const basePath = '/pascal-mcp-sdk';

function findRepoRoot(dir) {
  let current = dir;
  while (!fs.existsSync(path.join(current, 'lwpt.toml'))) {
    const parent = path.dirname(current);
    if (parent === current) throw new Error('repo root not found');
    current = parent;
  }
  return current;
}

export function remarkCasts() {
  return (tree, file) => {
    visit(tree, 'paragraph', (node, index, parent) => {
      if (!parent || index === undefined) return;
      if (node.children.length !== 1) return;
      const [link] = node.children;
      if (link.type !== 'link' || !link.url.endsWith('.cast')) return;

      const filePath = file.path ?? file.history[0];
      const repoRoot = findRepoRoot(path.dirname(filePath));
      const resolved = path.resolve(path.dirname(filePath), link.url);
      if (!fs.existsSync(resolved)) {
        throw new Error(
          `broken cast "${link.url}" in ${path.relative(repoRoot, filePath)}: ` +
            `${path.relative(repoRoot, resolved)} does not exist`,
        );
      }
      const fromCasts = path.relative(path.join(repoRoot, 'docs', 'casts'), resolved);
      if (fromCasts.startsWith('..')) {
        throw new Error(
          `cast "${link.url}" in ${path.relative(repoRoot, filePath)} ` +
            'must live under docs/casts/ to be served by the site',
        );
      }

      const label = node.children[0].children?.[0]?.value ?? 'Terminal session';
      parent.children[index] = {
        type: 'mdxJsxFlowElement',
        name: 'TerminalCast',
        attributes: [
          {
            type: 'mdxJsxAttribute',
            name: 'src',
            value: `${basePath}/docs-casts/${fromCasts}`,
          },
          { type: 'mdxJsxAttribute', name: 'label', value: label },
        ],
        children: [],
      };
    });
  };
}
