import { getPageMarkdownUrl, pageDescription, pageTitle, source } from '@/lib/source';
import { appName, pageUrl, repoUrl, siteUrl } from '@/lib/shared';

export const revalidate = false;

// llms.txt (https://llmstxt.org): an H1, a one-line blockquote summary,
// prose, then H2-delimited resource sections of Markdown links. The
// resources point at the per-page Markdown exports (the same content
// the copy-as-markdown button serves) rather than rendered HTML;
// contributor pages go under the spec's `## Optional` section.
// The card carries no exact version on purpose — the release manifest
// (lwpt.toml) is not a Pages trigger, so an embedded number would go
// stale.
async function resourceLine(page: (typeof source)['$inferPage']): Promise<string> {
  const description = await pageDescription(page);
  const link = `[${pageTitle(page)}](${siteUrl}${getPageMarkdownUrl(page).url})`;
  return description ? `- ${link}: ${description}` : `- ${link}`;
}

export async function GET() {
  const pages = source.getPages();
  const docs = await Promise.all(
    pages.filter((page) => page.slugs[0] !== 'internals').map(resourceLine),
  );
  const optional = await Promise.all(
    pages.filter((page) => page.slugs[0] === 'internals').map(resourceLine),
  );

  const card = `# ${appName}

> A FreePascal-native MCP (Model Context Protocol) server library.

${appName} lets you expose tools, resources, and prompts from any FreePascal program to AI agents. Zero third-party runtime dependencies: FPC RTL + fpjson (the HTTP transport uses fcl-web, which ships inside FPC). stdio and Streamable HTTP transports. Claude Code, Claude Desktop, and Codex connect out of the box.

This is not tina4stack/claude-pascal-mcp (a Python MCP that compiles Pascal) and not @pascal-app/mcp (the 3D editor MCP). Same word, different products.

## Docs

- [Documentation home](${pageUrl('/docs')}): rendered HTML; the entries below are the same pages as Markdown.
${docs.join('\n')}

## Source

- [GitHub repository](${repoUrl}): source, issues, releases.

## Optional

${optional.join('\n')}
`;

  return new Response(card, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
