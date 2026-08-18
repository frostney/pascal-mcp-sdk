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

// The one absolute-URL builder for page routes. next.config.mjs sets
// `trailingSlash: true`, so the served form of every page is the
// slashed one; canonical tags, JSON-LD `url`s, the sitemap, and the
// llms.txt card must all name that same form or crawlers see
// competing preferred URLs. File routes (`/llms.txt`, `/sitemap.xml`)
// are not pages — build those with `siteUrl` directly.
export function pageUrl(route: string): string {
  const slashed = route.endsWith('/') ? route : `${route}/`;
  return `${siteUrl}${slashed}`;
}
