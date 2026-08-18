import { appName, docsRoute, pageUrl, repoUrl, siteUrl } from '@/lib/shared';
import { libraryVersion } from '@/lib/library-version';

export const revalidate = false;

// Authored citation card in the llmstxt.org shape: H1, blockquote
// summary, prose, then H2 sections of `- [name](url): note` links.
// llms-full.txt stays the generated full-text dump. Identity, URLs,
// and the version come from their single sources so a release or
// repository move can't leave this surface stale.
function card(): string {
  return `# ${appName}

> A FreePascal-native MCP (Model Context Protocol) server library. Version ${libraryVersion()}.

${appName} lets you expose tools, resources, and prompts from any FreePascal program to AI agents. Zero third-party runtime dependencies — everything it uses ships with FPC (RTL, fpjson, fcl-base; fcl-web only for the HTTP transport). stdio and Streamable HTTP transports. Claude Code, Claude Desktop, and Codex connect out of the box.

This is not tina4stack/claude-pascal-mcp (a Python MCP that compiles Pascal) and not @pascal-app/mcp (the 3D editor MCP). Same word, different products.

## Docs

- [Documentation](${pageUrl(docsRoute)}): guides and public API reference
- [Introduction](${pageUrl('/docs/guides/introduction')}): what the library is and is not
- [Quick start](${pageUrl('/docs/guides/quick-start')}): a complete server in a few minutes
- [Full text](${siteUrl}/llms-full.txt): every documentation page as one markdown file

## Source

- [GitHub](${repoUrl}): source, issues, and releases
`;
}

export function GET() {
  return new Response(card(), {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
