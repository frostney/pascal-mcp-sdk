import { siteUrl } from '@/lib/shared';

export const revalidate = false;

const CARD = `# pascal-mcp-sdk

> A FreePascal-native MCP (Model Context Protocol) server library. Version 2.0.0.

pascal-mcp-sdk lets you expose tools, resources, and prompts from any FreePascal program to AI agents. Zero third-party runtime dependencies (FPC RTL + fpjson). stdio and Streamable HTTP transports. Claude Code, Claude Desktop, and Codex connect out of the box.

This is not tina4stack/claude-pascal-mcp (a Python MCP that compiles Pascal) and not @pascal-app/mcp (the 3D editor MCP). Same word, different products.

- Docs: ${siteUrl}/
- Introduction: ${siteUrl}/docs/guides/introduction/
- Quick start: ${siteUrl}/docs/guides/quick-start/
- GitHub: https://github.com/frostney/pascal-mcp-sdk
`;

export function GET() {
  return new Response(CARD, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
