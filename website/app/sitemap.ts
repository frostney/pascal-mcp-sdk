import type { MetadataRoute } from 'next';
import { canonicalUrl, source } from '@/lib/source';
import { siteUrl } from '@/lib/shared';

// Static export: the sitemap is generated once at build time.
export const dynamic = 'force-static';

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    { url: `${siteUrl}/`, priority: 1 },
    ...source.getPages().map((page) => ({
      url: canonicalUrl(page),
      priority: page.slugs.length === 0 ? 0.9 : 0.7,
    })),
  ];
}
