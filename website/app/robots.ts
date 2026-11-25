import type { MetadataRoute } from 'next';
import { siteUrl } from '@/lib/shared';

// Static export: generated once at build time. Note: on the
// github.io project site this lands under the basePath, where
// crawlers ignore it — it becomes effective the day the site moves
// to a domain root, and is harmless until then.
export const dynamic = 'force-static';

export default function robots(): MetadataRoute.Robots {
  return {
    rules: { userAgent: '*', allow: '/' },
    sitemap: `${siteUrl}/sitemap.xml`,
  };
}
