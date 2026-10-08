import { pageTitle, source } from '@/lib/source';
import { createFromSource } from 'fumadocs-core/search/server';
import type { StructuredData } from 'fumadocs-core/mdx-plugins';

export const revalidate = false;

// A page without structuredData means remarkStructure (or its export)
// fell out of the pipeline: fail the build instead of silently
// indexing the page as empty.
function requireStructuredData(page: (typeof source)['$inferPage']): StructuredData {
  const data = (page.data as { structuredData?: StructuredData }).structuredData;
  if (!data) {
    throw new Error(`search index: ${page.url} has no structuredData — remarkStructure missing?`);
  }
  return data;
}

// The index consumes the compile-time structuredData export produced
// by remarkStructure (postprocess.valueToExport in lib/source.ts);
// only the title needs deriving here because the docs are
// frontmatter-free.
export const { staticGET: GET } = createFromSource(source, {
  // https://docs.orama.com/docs/orama-js/supported-languages
  language: 'english',
  buildIndex: (page) => ({
    title: pageTitle(page),
    description: page.data.description,
    url: page.url,
    id: page.url,
    structuredData: requireStructuredData(page),
  }),
});
