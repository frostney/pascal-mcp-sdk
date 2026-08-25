import { siteUrl } from './site-identity.mjs';

export {
  appName,
  basePath,
  gitConfig,
  repoUrl,
  siteUrl,
} from './site-identity.mjs';
export const docsRoute = '/docs';
export const docsImageRoute = '/og/docs';
export const docsContentRoute = '/llms.mdx/docs';

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

// Absolute URL for an existing per-page Markdown export
// (`/llms.mdx/docs/.../content.md`). File-like, so no trailing slash.
export function docsMarkdownUrl(relativePath: string): string {
  const trimmed = relativePath.replace(/^\/+|\/+$/g, '');
  const suffix = trimmed ? `/${trimmed}` : '';
  return `${siteUrl}${docsContentRoute}${suffix}/content.md`;
}
