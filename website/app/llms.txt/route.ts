import type { Node, Root } from 'fumadocs-core/page-tree';
import { absoluteUrl, getPageMarkdownUrl, pageDescription, source } from '@/lib/source';
import { appName, description } from '@/lib/shared';

export const revalidate = false;

// llms.txt (https://llmstxt.org): the project, its summary, and the
// pages by section, each with the absolute URL of its Markdown copy
// and its first sentences. fumadocs' own llms() index writes site
// paths without the basePath, which lead nowhere on a GitHub Pages
// project site (issue #75).
async function entry(node: Node): Promise<string[]> {
  if (node.type === 'folder') {
    const pages = node.index ? [node.index, ...node.children] : node.children;
    return (await Promise.all(pages.map(entry))).flat();
  }
  if (node.type !== 'page') return [];
  const page = source.getNodePage(node);
  if (!page) return [];
  const summary = await pageDescription(page);
  const link = `- [${String(node.name)}](${absoluteUrl(getPageMarkdownUrl(page).url)})`;
  return [summary ? `${link}: ${summary}` : link];
}

export async function GET() {
  const tree: Root = source.getPageTree();
  const top: string[] = [];
  const sections: string[] = [];
  for (const node of tree.children) {
    if (node.type === 'folder') {
      sections.push(`## ${String(node.name)}`, '', ...(await entry(node)), '');
    } else {
      top.push(...(await entry(node)));
    }
  }
  const text = [
    `# ${appName}`,
    '',
    `> ${description}`,
    '',
    ...top,
    `- [All of the documentation in one file](${absoluteUrl('/llms-full.txt')})`,
    '',
    ...sections,
  ].join('\n');
  return new Response(text, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
}
