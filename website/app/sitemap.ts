import type { MetadataRoute } from 'next';
import { source } from '@/lib/source';
import { pageUrl, resourceUrl } from '@/lib/shared';

// Static export: the sitemap is generated once at build time.
export const dynamic = 'force-static';

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    { url: pageUrl('/'), priority: 1 },
    { url: resourceUrl('/llms.txt'), priority: 0.3 },
    ...source.getPages().map((page) => ({
      url: pageUrl(page.url),
      priority: page.slugs.length === 0 ? 0.9 : 0.7,
    })),
  ];
}
