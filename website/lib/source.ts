import { loader } from 'fumadocs-core/source';
import { docsContentRoute, docsImageRoute, docsRoute } from './shared';
import { defineDocs } from 'fumadocs-mdx/macro';
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';
import { z } from 'zod';
import { remarkRepoLinks } from './remark-repo-links.mjs';

const docs = defineDocs({
  // The site renders the repository's docs/ tree directly — no second
  // copy (issue #6). Only landing-page content and glue live under
  // website/.
  dir: '../docs',
  docs: {
    // The rendered docs are plain GitHub markdown without frontmatter
    // (the site adapts to docs/, not the other way around): titles are
    // optional here and derived from the page path when absent — the
    // page body keeps its own H1.
    schema: pageSchema.extend({ title: z.string().optional() }),
    postprocess: {
      includeProcessedMarkdown: true,
      // Export the search-index structure remarkStructure produces so
      // the static Orama index can be built.
      valueToExport: ['structuredData'],
    },
    mdxOptions: {
      remarkPlugins: [remarkRepoLinks],
    },
  },
  meta: {
    schema: metaSchema,
  },
});

// See https://fumadocs.dev/docs/headless/source-api for more info
export const source = loader({
  baseUrl: docsRoute,
  source: docs.toFumadocsSource(),
  plugins: [],
});

// Display title for pages without frontmatter: 'quick-start' →
// 'Quick Start'; the docs root is 'Documentation'.
export function pageTitle(page: (typeof source)['$inferPage']): string {
  if (page.data.title) return page.data.title;
  const slug = page.slugs.at(-1);
  if (!slug) return 'Documentation';
  return slug
    .split('-')
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');
}

export function getPageImageUrl(page: (typeof source)['$inferPage']) {
  const segments = [...page.slugs, 'image.png'];

  return {
    segments,
    url: '/' + [page.locale, ...docsImageRoute.split('/'), ...segments].filter(Boolean).join('/'),
  };
}

export function getPageMarkdownUrl(page: (typeof source)['$inferPage']) {
  const segments = [...page.slugs, 'content.md'];

  return {
    segments,
    url: '/' + [page.locale, ...docsContentRoute.split('/'), ...segments].filter(Boolean).join('/'),
  };
}

export async function getLLMText(page: (typeof source)['$inferPage']) {
  const processed = await page.data.getText('processed');

  return `# ${pageTitle(page)} (${page.url})

${processed}`;
}
