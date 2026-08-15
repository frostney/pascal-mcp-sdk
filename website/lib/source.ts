import { loader } from 'fumadocs-core/source';
import { docsContentRoute, docsImageRoute, docsRoute } from './shared';
import { defineDocs } from 'fumadocs-mdx/macro';
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';
import { z } from 'zod';
import {
  rehypeCode,
  rehypeToc,
  remarkGfm,
  remarkHeading,
  remarkStructure,
} from 'fumadocs-core/mdx-plugins';
import { remarkRepoLinks } from './remark-repo-links.mjs';
import { remarkTermLinks } from './remark-term-links.mjs';
import { rehypeMermaidDual } from './rehype-mermaid-dual.mjs';
import type { PluggableList } from 'unified';

const docs = defineDocs({
  // The site renders the repository's docs/ tree directly — no second
  // copy (issue #6). Only landing-page content and glue live under
  // website/.
  dir: '../docs',
  docs: {
    // ADRs and other repo-only records under docs/ stay off the
    // website: the docs tree is the site's content source, but not
    // everything in it is site content.
    files: ['**/*.md', '!adr/**'],
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
      // Macro-mode mdxOptions is plain ProcessorOptions: it REPLACES
      // fumadocs' bundler preset instead of extending it, so every
      // preset plugin the site relies on is re-applied explicitly,
      // in the preset's own order (see fumadocs-core's
      // content/mdx/preset-bundler.ts): remarkGfm parses GFM tables,
      // remarkHeading assigns heading ids (anchors), rehypeToc builds
      // the per-page TOC, and remarkStructure emits the search-index
      // structure exported via valueToExport above.
      remarkPlugins: [
        remarkGfm,
        [remarkHeading, { generateToc: false }],
        remarkRepoLinks,
        remarkTermLinks,
        remarkStructure,
      ],
      // Syntax highlighting: the docs' Pascal fences need the grammar
      // named; themes follow the site's light/dark toggle.
      rehypePlugins: [
        // Mermaid fences become themed inline SVGs (light + dark) at
        // build time — before rehypeCode, so Shiki never sees them.
        ...(rehypeMermaidDual as PluggableList),
        [
          rehypeCode,
          {
            themes: {
              light: 'github-light',
              dark: 'github-dark',
            },
            langs: ['pascal', 'sh', 'bash', 'json', 'text', 'toml'],
          },
        ],
        rehypeToc,
      ],
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

// Meta description for pages without frontmatter (the docs stay
// frontmatter-free by design): the page's first prose paragraph from
// the processed markdown (same source the search index uses), with
// inline markdown stripped, clipped to meta-description length at a
// word boundary.
export async function pageDescription(
  page: (typeof source)['$inferPage'],
): Promise<string | undefined> {
  if (page.data.description) return page.data.description;
  const processed = await page.data.getText('processed');
  const firstParagraph = processed
    .split(/\n\s*\n/)
    .map((block) => block.trim())
    .find((block) => block.length > 0 && !/^[#>|`\-*\d]/.test(block));
  if (!firstParagraph) return undefined;
  const text = firstParagraph
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1') // links → text
    .replace(/[`*_]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (text.length <= 160) return text;
  return text.slice(0, 157).replace(/\s+\S*$/, '') + '…';
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
