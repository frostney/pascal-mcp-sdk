import { pageTitle, source } from '@/lib/source';
import { createFromSource } from 'fumadocs-core/search/server';
import type { StructuredData } from 'fumadocs-core/mdx-plugins';

export const revalidate = false;

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
    structuredData: (page.data as { structuredData?: StructuredData }).structuredData ?? {
      headings: [],
      contents: [],
    },
  }),
});
