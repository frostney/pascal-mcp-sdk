import { appName, repoUrl, siteUrl } from '@/lib/shared';
import { libraryVersion } from '@/lib/library-version.mjs';
import { getPageMarkdownUrl, source } from '@/lib/source';

export const revalidate = false;

// Absolute URL of a curated page's existing Markdown export
// (`/llms.mdx/docs/.../content.md`); throws at build time if the page
// disappears from docs/.
function markdownUrl(slugs: string[]): string {
  const page = source.getPage(slugs);
  if (!page) throw new Error(`llms.txt docs page missing: ${slugs.join('/')}`);
  return `${siteUrl}${getPageMarkdownUrl(page).url}`;
}

// Identity, the repository URL, and the version come from their
// single sources (gitConfig, lwpt.toml) at build time so a release or
// repository move cannot leave this surface stale. Curated docs
// entries point at the existing per-page Markdown exports.
const CARD = `# ${appName}

> A FreePascal-native MCP (Model Context Protocol) server library. Version ${libraryVersion()}.

${appName} lets you expose tools, resources, and prompts from any FreePascal program to AI agents. Zero third-party runtime dependencies (FPC RTL + fpjson). stdio and Streamable HTTP transports. Claude Code, Claude Desktop, and Codex connect out of the box.

This is not tina4stack/claude-pascal-mcp (a Python MCP that compiles Pascal) and not @pascal-app/mcp (the 3D editor MCP). Same word, different products.

- Docs: ${siteUrl}/
- Introduction: ${markdownUrl(['guides', 'introduction'])}
- Quick start: ${markdownUrl(['guides', 'quick-start'])}
- GitHub: ${repoUrl}
`;

export function GET() {
  return new Response(CARD, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
