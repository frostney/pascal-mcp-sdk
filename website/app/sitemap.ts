import type { MetadataRoute } from 'next';
import { source } from '@/lib/source';
import { siteUrl } from '@/lib/shared';

// Static export: the sitemap is generated once at build time.
export const dynamic = 'force-static';

function slashed(path: string): string {
  return path.endsWith('/') ? path : `${path}/`;
}

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    { url: `${siteUrl}/`, priority: 1 },
    { url: `${siteUrl}/llms.txt`, priority: 0.3 },
    ...source.getPages().map((page) => ({
      url: `${siteUrl}${slashed(page.url)}`,
      priority: page.slugs.length === 0 ? 0.9 : 0.7,
    })),
  ];
}
