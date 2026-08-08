import { pageTitle, source } from '@/lib/source';
import { createFromSource } from 'fumadocs-core/search/server';
import { structure } from 'fumadocs-core/mdx-plugins';

export const revalidate = false;

// The docs are plain markdown rendered straight from the repository's
// docs/ tree, so the search structure is derived from the processed
// markdown here instead of a compile-time export.
export const { staticGET: GET } = createFromSource(source, {
  // https://docs.orama.com/docs/orama-js/supported-languages
  language: 'english',
  buildIndex: async (page) => ({
    title: pageTitle(page),
    description: page.data.description,
    url: page.url,
    id: page.url,
    structuredData: structure(await page.data.getText('processed')),
  }),
});
