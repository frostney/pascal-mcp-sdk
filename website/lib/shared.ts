export const appName = 'pascal-mcp-sdk';
// Mirrors next.config.mjs basePath (GitHub Pages project site).
export const basePath = '/pascal-mcp-sdk';
// Canonical deployed origin + basePath — used for metadataBase,
// sitemap, robots, and JSON-LD.
export const siteUrl = 'https://frostney.github.io/pascal-mcp-sdk';
export const docsRoute = '/docs';
export const docsImageRoute = '/og/docs';
export const docsContentRoute = '/llms.mdx/docs';

export const gitConfig = {
  user: 'frostney',
  repo: 'pascal-mcp-sdk',
  branch: 'main',
};
export const repoUrl = `https://github.com/${gitConfig.user}/${gitConfig.repo}`;

// Canonical absolute URL of a rendered page. next.config.mjs sets
// trailingSlash, so every page is served at its slash-suffixed path;
// the sitemap, canonicals, and JSON-LD all go through here so the
// discovery surfaces publish one URL form. Not for files (llms.txt,
// content.md, sitemap.xml) — those keep their bare path.
export function pageUrl(path: string): string {
  return `${siteUrl}${path.endsWith('/') ? path : `${path}/`}`;
}

// Absolute URL of an exported file or route whose name must remain
// bare. Keep resource construction separate from pageUrl so metadata
// never adds a trailing slash to llms.txt, content.md, or images.
export function resourceUrl(path: string): string {
  return `${siteUrl}${path.startsWith('/') ? path : `/${path}`}`;
}
