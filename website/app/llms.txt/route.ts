import { appName, docsMarkdownUrl, repoUrl, siteUrl } from "@/lib/shared";
import { libraryVersion } from "@/lib/library-version";
import { getPageMarkdownUrl, source } from "@/lib/source";

export const revalidate = false;

function curatedMarkdownUrl(slugs: string[]): string {
  const page = source.getPage(slugs);
  if (!page) {
    throw new Error(`llms.txt docs page missing: ${slugs.join("/") || "(docs root)"}`);
  }
  const { url } = getPageMarkdownUrl(page);
  const expected = docsMarkdownUrl(slugs.join("/"));
  const actual = `${siteUrl}${url}`;
  if (actual !== expected) {
    throw new Error(`llms.txt markdown URL drift: ${actual} !== ${expected}`);
  }
  return actual;
}

// Authored citation card in the llmstxt.org shape: H1, blockquote
// summary, prose, then H2 sections of `- [name](url): note` links.
// llms-full.txt stays the generated full-text dump. Identity, URLs,
// and the version come from their single sources so a release or
// repository move can not leave this surface stale. Curated Docs
// entries point at the existing per-page Markdown exports.
function card(): string {
  return `# ${appName}

> A FreePascal-native MCP (Model Context Protocol) server library. Version ${libraryVersion()}.

${appName} lets you expose tools, resources, and prompts from any FreePascal program to AI agents. Zero third-party runtime dependencies — everything it uses ships with FPC (RTL, fpjson, fcl-base; fcl-web only for the HTTP transport). stdio and Streamable HTTP transports. Claude Code, Claude Desktop, and Codex connect out of the box.

This is not tina4stack/claude-pascal-mcp (a Python MCP that compiles Pascal) and not @pascal-app/mcp (the 3D editor MCP). Same word, different products.

## Docs

- [Documentation](${curatedMarkdownUrl([])}): guides and public API reference
- [Introduction](${curatedMarkdownUrl(["guides", "introduction"])}): what the library is and is not
- [Quick start](${curatedMarkdownUrl(["guides", "quick-start"])}): a complete server in a few minutes
- [Full text](${siteUrl}/llms-full.txt): every documentation page as one markdown file

## Source

- [GitHub](${repoUrl}): source, issues, and releases
`;
}

export function GET() {
  return new Response(card(), {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
