import type { Node, Root } from 'fumadocs-core/page-tree';
import { absoluteUrl, getPageMarkdownUrl, pageDescription, source } from '@/lib/source';
import { appName, description } from '@/lib/shared';

export const revalidate = false;

// llms.txt (https://llmstxt.org): the project, its summary, and the
// pages by section, each with the absolute URL of its Markdown copy
// and its first sentences. fumadocs' own llms() index writes site
// paths without the basePath, which lead nowhere on a GitHub Pages
// project site (issue #75). Every link sits under an H2, where the
// format's file lists are; the prose before the first H2 says what the
// library is and which similarly named projects it is not.

// A Markdown link, its label's brackets and its URL's parentheses
// escaped, as fumadocs' own index writes it.
function link(label: string, url: string): string {
  return `[${label.replace(/([[\]\\])/g, '\\$1')}](${url.replace(/([()])/g, '\\$1')})`;
}

async function entries(node: Node): Promise<string[]> {
  if (node.type === 'folder') {
    const pages = node.index ? [node.index, ...node.children] : node.children;
    return (await Promise.all(pages.map(entries))).flat();
  }
  if (node.type !== 'page') return [];
  const page = source.getNodePage(node);
  if (!page) return [];
  const summary = await pageDescription(page);
  const line = `- ${link(String(node.name), absoluteUrl(getPageMarkdownUrl(page).url))}`;
  return [summary ? `${line}: ${summary}` : line];
}

export async function GET() {
  const tree: Root = source.getPageTree();
  const top: string[] = [];
  const sections: string[] = [];
  for (const node of tree.children) {
    if (node.type === 'folder') {
      sections.push(`## ${String(node.name)}`, '', ...(await entries(node)), '');
    } else {
      top.push(...(await entries(node)));
    }
  }
  const text = [
    `# ${appName}`,
    '',
    `> ${description}`,
    '',
    `${appName} lets a FreePascal program expose tools, resources and prompts to AI agents. It uses only packages that ship with FPC (the RTL, fpjson and fcl-base, plus fcl-web for HTTP). Over stdio it serves both protocol eras, so Claude Code, Claude Desktop and Codex connect to it as they are; its Streamable HTTP binding speaks only the stateless 2026-07-28 protocol, for clients that send per-request _meta instead of opening with initialize.`,
    '',
    'It is not tina4stack/pascal-mcp (formerly claude-pascal-mcp, a Python MCP server that compiles and runs Pascal programs) and not @pascal-app/mcp (the MCP server of the Pascal 3D editor).',
    '',
    `## ${String(tree.name)}`,
    '',
    ...top,
    `- ${link('All of the documentation in one file', absoluteUrl('/llms-full.txt'))}`,
    '',
    ...sections,
  ].join('\n');
  return new Response(text, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
}
