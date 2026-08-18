import {
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
import { basePath, docsRoute, gitConfig, pageUrl } from '@/lib/shared';

export default async function Page(props: PageProps<'/docs/[[...slug]]'>) {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  const MDX = page.data.body;
  const markdownUrl = getPageMarkdownUrl(page).url;
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'TechArticle',
    headline: pageTitle(page),
    description: await pageDescription(page),
    url: pageUrl(page.url),
    isPartOf: {
      '@type': 'WebSite',
      name: 'pascal-mcp-sdk documentation',
      url: pageUrl(docsRoute),
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
    alternates: { canonical: pageUrl(page.url) },
    openGraph: {
      images: `${basePath}${getPageImageUrl(page).url}`,
    },
  };
}
