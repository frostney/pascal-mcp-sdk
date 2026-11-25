import { loader } from 'fumadocs-core/source';
import { docsContentRoute, docsImageRoute, docsRoute, siteUrl } from './shared';
import { defineDocs } from 'fumadocs-mdx/macro';
import { applyMdxPreset } from 'fumadocs-mdx/config';
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';
import { z } from 'zod';
import { remarkRepoLinks, stringifyAbsoluteLinks } from './remark-repo-links.mjs';
import { remarkTermLinks } from './remark-term-links.mjs';
import { remarkCasts } from './remark-casts.mjs';
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
    // everything in it is site content. The macro takes literal
    // strings only, so this list mirrors repoOnlyDocDirs in
    // remark-repo-links.mjs, which sends links to those files to
    // GitHub; scripts/check-export.mjs fails the build when the two
    // disagree (a repo-only page in the export, or a link to a page
    // the export lacks).
    files: ['**/*.md', '!adr/**'],
    // The rendered docs are plain GitHub markdown without frontmatter
    // (the site adapts to docs/, not the other way around): titles are
    // optional here and derived from the page path when absent — the
    // page body keeps its own H1.
    schema: pageSchema.extend({ title: z.string().optional() }),
    postprocess: {
      // The Markdown of each page, for llms-full.txt, the Markdown
      // copies, page descriptions and the search index: plain GitHub
      // Markdown, so without fumadocs' `[#id]` after each heading, and
      // with absolute URLs, as it is read outside the site.
      includeProcessedMarkdown: { headingIds: false, stringify: stringifyAbsoluteLinks },
    },
    // fumadocs-mdx's own preset: GitHub Markdown (tables), heading ids
    // and the per-page table of contents, and syntax highlighting. The
    // macro takes plain processor options otherwise, which leaves all
    // of that out (issue #74).
    mdxOptions: applyMdxPreset({
      // The preset runs these after its GFM and heading-id plugins.
      // Cast links become the terminal player before remarkRepoLinks,
      // which would route .cast paths as pages.
      remarkPlugins: [remarkCasts, remarkRepoLinks, remarkTermLinks],
      // Mermaid fences become themed inline SVGs (light + dark) at
      // build time, ahead of the preset's rehypeCode so Shiki never
      // sees them; the preset's rehypeToc still runs last.
      rehypePlugins: (preset) => [...(rehypeMermaidDual as PluggableList), ...preset],
      // remarkRepoLinks maps images to the site's copy of docs/images/.
      remarkImageOptions: false,
      // app/api/search/route.ts builds the search structure from the
      // processed Markdown, so no page exports one of its own.
      remarkStructureOptions: false,
      rehypeCodeOptions: {
        // Themes follow the site's light/dark toggle; the docs' Pascal
        // fences need the grammar named.
        themes: {
          light: 'github-light',
          dark: 'github-dark',
        },
        langs: ['pascal', 'sh', 'bash', 'json', 'toml'],
      },
    }),
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

// Absolute URLs: llms.txt and the Markdown copies are read outside the
// site, where a path without the origin and the basePath leads nowhere
// (issue #75).
export function absoluteUrl(path: string): string {
  return `${siteUrl}${path}`;
}

// The URL a page is served at: the export has trailingSlash, so the
// path without the slash is a redirect (issue #77).
export function canonicalUrl(page: (typeof source)['$inferPage']): string {
  return `${absoluteUrl(page.url)}/`;
}

// A page's Markdown copy, for llms-full.txt and /llms.mdx/: its URL,
// then its own Markdown, which carries the page's H1 and whose links
// stringifyAbsoluteLinks made absolute.
export async function getLLMText(page: (typeof source)['$inferPage']) {
  const processed = await page.data.getText('processed');
  const url = canonicalUrl(page);

  return `URL: ${url}

${processed.trimStart()}`;
}
