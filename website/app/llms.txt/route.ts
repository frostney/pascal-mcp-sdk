import { appName, pageUrl, repoUrl } from '@/lib/shared';
import { libraryVersion } from '@/lib/library-version';

export const revalidate = false;

// Authored citation card (llms-full.txt stays the generated dump).
// Identity, URLs, and the version come from their single sources so a
// release or repository move can't leave this surface stale.
function card(): string {
  return `# ${appName}

> A FreePascal-native MCP (Model Context Protocol) server library. Version ${libraryVersion()}.

${appName} lets you expose tools, resources, and prompts from any FreePascal program to AI agents. Zero third-party runtime dependencies (FPC RTL + fpjson). stdio and Streamable HTTP transports. Claude Code, Claude Desktop, and Codex connect out of the box.

This is not tina4stack/claude-pascal-mcp (a Python MCP that compiles Pascal) and not @pascal-app/mcp (the 3D editor MCP). Same word, different products.

- Docs: ${pageUrl('/')}
- Introduction: ${pageUrl('/docs/guides/introduction')}
- Quick start: ${pageUrl('/docs/guides/quick-start')}
- GitHub: ${repoUrl}
`;
}

export function GET() {
  return new Response(card(), {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
