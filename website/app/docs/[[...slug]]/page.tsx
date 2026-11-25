import {
  absoluteUrl,
  canonicalUrl,
  getPageImageUrl,
  getPageMarkdownUrl,
  pageDescription,
  pageTitle,
  source,
} from '@/lib/source';
import {
  DocsBody,
  DocsPage,
  MarkdownCopyButton,
  ViewOptionsPopover,
} from 'fumadocs-ui/layouts/docs/page';
import { notFound } from 'next/navigation';
import { getMDXComponents } from '@/components/mdx';
import type { Metadata } from 'next';
import { createRelativeLink } from 'fumadocs-ui/mdx';
import { basePath, gitConfig, siteUrl } from '@/lib/shared';

export default async function Page(props: PageProps<'/docs/[[...slug]]'>) {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  const MDX = page.data.body;
  // fumadocs-ui adds the basePath to this URL only under Vite, so it
  // carries the basePath itself (issue #76).
  const markdownUrl = `${basePath}${getPageMarkdownUrl(page).url}`;
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'TechArticle',
    headline: pageTitle(page),
    description: await pageDescription(page),
    url: canonicalUrl(page),
    isPartOf: {
      '@type': 'WebSite',
      name: 'pascal-mcp-sdk documentation',
      url: `${siteUrl}/docs/`,
    },
  };

  return (
    <DocsPage toc={page.data.toc} full={page.data.full}>
      {/* The markdown body carries its own H1 (the docs stay valid
          GitHub markdown), so no separate DocsTitle is rendered. */}
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      {/* llmstxt.org's link relations: describedby names the llms.txt
          that covers this page (the text/markdown alternate is in
          generateMetadata). The Metadata API has no slot for it; React
          places the <link> in <head>. */}
      <link rel="describedby" type="text/plain" href={absoluteUrl('/llms.txt')} />
      <div className="flex flex-row gap-2 items-center border-b pb-6">
        <MarkdownCopyButton markdownUrl={markdownUrl} />
        <ViewOptionsPopover
          markdownUrl={markdownUrl}
          githubUrl={`https://github.com/${gitConfig.user}/${gitConfig.repo}/blob/${gitConfig.branch}/docs/${page.path}`}
        />
      </div>
      <DocsBody>
        <MDX
          components={getMDXComponents({
            // this allows you to link to other pages with relative file paths
            a: createRelativeLink(source, page),
          })}
        />
      </DocsBody>
    </DocsPage>
  );
}

export async function generateStaticParams() {
  return source.generateParams();
}

export async function generateMetadata(props: PageProps<'/docs/[[...slug]]'>): Promise<Metadata> {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  return {
    title: pageTitle(page),
    description: await pageDescription(page),
    alternates: {
      canonical: canonicalUrl(page),
      // The page's Markdown copy, for machine readers (llmstxt.org).
      types: { 'text/markdown': absoluteUrl(getPageMarkdownUrl(page).url) },
    },
    openGraph: {
      images: `${basePath}${getPageImageUrl(page).url}`,
    },
  };
}
