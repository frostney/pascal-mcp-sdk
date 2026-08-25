import { loader } from 'fumadocs-core/source';
import fs from 'node:fs';
import path from 'node:path';
import { docsContentRoute, docsImageRoute, docsRoute } from './shared';
import { findRepoRoot } from './repo-root.mjs';
import { defineDocs } from 'fumadocs-mdx/macro';
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';
import { z } from 'zod';
import { rehypeCode } from 'fumadocs-core/mdx-plugins';
import { remarkRepoLinks } from './remark-repo-links.mjs';
import { remarkTermLinks } from './remark-term-links.mjs';

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
      remarkPlugins: [remarkRepoLinks, remarkTermLinks],
      // Syntax highlighting: this macro-mode mdxOptions is plain
      // ProcessorOptions, so rehypeCode is applied explicitly. The
      // docs' Pascal fences need the grammar named; themes follow the
      // site's light/dark toggle.
      rehypePlugins: [
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

// Display title for pages without frontmatter: prefer the document
// H1 (the visible article title) so metadata, JSON-LD, search, and
// generated LLM text stay aligned with the page. Slug title-case is
// the fallback when a page has no H1.
export function pageTitle(page: (typeof source)['$inferPage']): string {
  if (page.data.title) return page.data.title;
  const fromHeading = headingFromPage(page);
  if (fromHeading) return fromHeading;
  const slug = page.slugs.at(-1);
  if (!slug) return 'Documentation';
  return slug
    .split('-')
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');
}

function headingFromPage(page: (typeof source)['$inferPage']): string | undefined {
  const toc = page.data.toc;
  if (Array.isArray(toc)) {
    const h1 = toc.find((item) => item.depth === 1 && typeof item.title === 'string');
    if (h1 && typeof h1.title === 'string' && h1.title.trim()) return h1.title.trim();
  }
  try {
    const file = path.join(findRepoRoot(process.cwd()), 'docs', page.path);
    const match = /^#\s+(.+?)\s*$/m.exec(fs.readFileSync(file, 'utf8'));
    if (match) return match[1].trim();
  } catch {
    // slug fallback
  }
  return undefined;
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
