// Auto-link well-known tooling terms: the first plain-text occurrence
// of each term on a page becomes a link to that tool's site (one link
// per target URL per page — a page that already links a target, by
// hand or via an earlier term, gets no second link). Matches are
// case-sensitive, respect word boundaries (so `MCP.Server`,
// `lwpt.toml`, `pascal-mcp-sdk` stay plain), and never fire inside
// code, existing links, or headings.

// Longest-first so 'Model Context Protocol' wins over 'MCP'.
const TERMS = [
  ['Model Context Protocol', 'https://modelcontextprotocol.io'],
  ['Claude Desktop', 'https://claude.com/download'],
  ['Claude Code', 'https://claude.com/product/claude-code'],
  ['JSON Schema', 'https://json-schema.org'],
  ['FreePascal', 'https://www.freepascal.org'],
  ['git-cliff', 'https://git-cliff.org'],
  ['Fumadocs', 'https://fumadocs.dev'],
  ['fpjson', 'https://wiki.freepascal.org/fcl-json'],
  ['Shiki', 'https://shiki.style'],
  ['lwpt', 'https://github.com/frostney/lwpt'],
  ['MCP', 'https://modelcontextprotocol.io'],
  ['FPC', 'https://www.freepascal.org'],
];

const SKIP_TYPES = new Set(['link', 'linkReference', 'heading', 'code', 'inlineCode']);

// A term match must not touch identifier-ish neighbours: letters,
// digits, and the joiners that appear in unit/file names.
const BOUNDARY = /[A-Za-z0-9_.\-/]/;

function normalize(url) {
  return url.replace(/\/+$/, '');
}

function collectExistingLinks(node, seen) {
  // Inline links and reference-style link definitions both count as
  // "this page already links that target".
  if ((node.type === 'link' || node.type === 'definition') && typeof node.url === 'string') {
    seen.add(normalize(node.url));
  }
  for (const child of node.children ?? []) collectExistingLinks(child, seen);
}

function earliestMatch(text, seen) {
  let best = null;
  for (const [term, url] of TERMS) {
    if (seen.has(normalize(url))) continue;
    let from = 0;
    for (;;) {
      const at = text.indexOf(term, from);
      if (at === -1) break;
      const before = at === 0 ? '' : text[at - 1];
      const after = text[at + term.length] ?? '';
      if ((before === '' || !BOUNDARY.test(before)) && (after === '' || !BOUNDARY.test(after))) {
        if (!best || at < best.at || (at === best.at && term.length > best.term.length)) {
          best = { at, term, url };
        }
        break;
      }
      from = at + 1;
    }
  }
  return best;
}

function linkTerms(node, seen) {
  if (SKIP_TYPES.has(node.type) || !node.children) return;
  for (let i = 0; i < node.children.length; i++) {
    const child = node.children[i];
    if (child.type !== 'text') {
      linkTerms(child, seen);
      continue;
    }
    const match = earliestMatch(child.value, seen);
    if (!match) continue;
    seen.add(normalize(match.url));
    const before = child.value.slice(0, match.at);
    const after = child.value.slice(match.at + match.term.length);
    const replacement = [];
    if (before) replacement.push({ type: 'text', value: before });
    replacement.push({
      type: 'link',
      url: match.url,
      children: [{ type: 'text', value: match.term }],
    });
    if (after) replacement.push({ type: 'text', value: after });
    node.children.splice(i, 1, ...replacement);
    // Re-examine the trailing text node for further (other-term) matches.
    i = node.children.indexOf(replacement[replacement.length - 1]) - 1;
  }
}

export function remarkTermLinks() {
  return (tree) => {
    const seen = new Set();
    collectExistingLinks(tree, seen);
    linkTerms(tree, seen);
  };
}
