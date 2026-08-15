// Build-time Mermaid rendering with class-based dark mode.
//
// rehype-mermaid renders every `language-mermaid` code fence to an
// inline SVG with ONE mermaid config, and its own dark-mode support
// (`dark` option) keys off prefers-color-scheme — but this site's
// theme is a `.dark` class toggle (next-themes via fumadocs-ui), so a
// media query would contradict an explicit toggle. Instead each
// diagram is rendered twice: the fence is duplicated up front, the
// light pass renders the originals, a rename pass re-arms the dark
// copies, and the dark pass renders those with the dark palette.
// `.mermaid-light` / `.mermaid-dark` wrappers let global.css show the
// one that matches the active theme. Everything happens at build time
// in headless Chromium — no mermaid JS ships to the client.
import rehypeMermaid from 'rehype-mermaid';
import { visit } from 'unist-util-visit';

// One hue family, site-aligned: the indigo accent from the logo
// favicon (#6366f1) on neutral surfaces. Mermaid needs literal
// colors at render time, so the fd-* CSS variables can't be used
// directly; these values mirror the neutral preset's grays.
const FONT = "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif";

const lightTheme = {
  theme: 'base',
  themeVariables: {
    fontFamily: FONT,
    fontSize: '14px',
    background: 'transparent',
    primaryColor: '#eef2ff', // indigo-50 node fill
    primaryTextColor: '#171717',
    primaryBorderColor: '#6366f1',
    secondaryColor: '#fafafa',
    tertiaryColor: '#f5f5f5',
    lineColor: '#737373',
    textColor: '#171717',
    mainBkg: '#eef2ff',
    nodeBorder: '#6366f1',
    clusterBkg: '#fafafa',
    clusterBorder: '#d4d4d4',
    titleColor: '#171717',
    edgeLabelBackground: '#ffffff',
    // sequence diagrams
    actorBkg: '#eef2ff',
    actorBorder: '#6366f1',
    actorTextColor: '#171717',
    signalColor: '#404040',
    signalTextColor: '#404040',
    labelBoxBkgColor: '#fafafa',
    labelBoxBorderColor: '#d4d4d4',
    labelTextColor: '#171717',
    loopTextColor: '#171717',
    noteBkgColor: '#fef9c3',
    noteBorderColor: '#ca8a04',
    noteTextColor: '#171717',
    activationBkgColor: '#e0e7ff',
    activationBorderColor: '#6366f1',
    // state diagrams
    specialStateColor: '#404040',
  },
};

const darkTheme = {
  theme: 'base',
  themeVariables: {
    fontFamily: FONT,
    fontSize: '14px',
    darkMode: true,
    background: 'transparent',
    primaryColor: '#1e1b4b', // indigo-950 node fill
    primaryTextColor: '#e5e5e5',
    primaryBorderColor: '#818cf8',
    secondaryColor: '#171717',
    tertiaryColor: '#262626',
    lineColor: '#a3a3a3',
    textColor: '#e5e5e5',
    mainBkg: '#1e1b4b',
    nodeBorder: '#818cf8',
    clusterBkg: '#171717',
    clusterBorder: '#404040',
    titleColor: '#e5e5e5',
    edgeLabelBackground: '#0a0a0a',
    // sequence diagrams
    actorBkg: '#1e1b4b',
    actorBorder: '#818cf8',
    actorTextColor: '#e5e5e5',
    signalColor: '#d4d4d4',
    signalTextColor: '#d4d4d4',
    labelBoxBkgColor: '#171717',
    labelBoxBorderColor: '#404040',
    labelTextColor: '#e5e5e5',
    loopTextColor: '#e5e5e5',
    noteBkgColor: '#422006',
    noteBorderColor: '#ca8a04',
    noteTextColor: '#e5e5e5',
    activationBkgColor: '#312e81',
    activationBorderColor: '#818cf8',
    // state diagrams
    specialStateColor: '#d4d4d4',
  },
};

function isMermaidPre(node) {
  if (node.type !== 'element' || node.tagName !== 'pre') return false;
  const code = node.children?.find(
    (child) => child.type === 'element' && child.tagName === 'code',
  );
  const classes = code?.properties?.className;
  return Array.isArray(classes) && classes.includes('language-mermaid');
}

// Pass 1: duplicate every mermaid fence into a light and a dark copy.
// The dark copy's language class is parked as `language-mermaid-dark`
// so the light rehype-mermaid pass leaves it alone.
function duplicateMermaidFences() {
  return (tree) => {
    visit(tree, 'element', (node, index, parent) => {
      if (!parent || index === undefined || !isMermaidPre(node)) return;
      const darkPre = structuredClone(node);
      const darkCode = darkPre.children.find(
        (child) => child.type === 'element' && child.tagName === 'code',
      );
      darkCode.properties.className = ['language-mermaid-dark'];
      parent.children.splice(
        index,
        1,
        {
          type: 'element',
          tagName: 'div',
          properties: { className: ['mermaid-diagram', 'mermaid-light'] },
          children: [node],
        },
        {
          type: 'element',
          tagName: 'div',
          properties: { className: ['mermaid-diagram', 'mermaid-dark'] },
          children: [darkPre],
        },
      );
      return 'skip';
    });
  };
}

// Pass 3: re-arm the parked dark copies for the dark render pass.
function armDarkMermaidFences() {
  return (tree) => {
    visit(tree, 'element', (node) => {
      const classes = node.properties?.className;
      if (Array.isArray(classes) && classes.includes('language-mermaid-dark')) {
        node.properties.className = ['language-mermaid'];
      }
    });
  };
}

// unified deduplicates plugins by function identity — registering
// rehypeMermaid twice would only reconfigure the first registration,
// collapsing the two passes into one. Distinct wrapper attachers keep
// both passes alive.
function rehypeMermaidLightPass() {
  return rehypeMermaid.call(this, {
    strategy: 'inline-svg',
    prefix: 'mermaid-light',
    mermaidConfig: lightTheme,
  });
}

function rehypeMermaidDarkPass() {
  return rehypeMermaid.call(this, {
    strategy: 'inline-svg',
    prefix: 'mermaid-dark',
    mermaidConfig: darkTheme,
  });
}

// The full plugin chain, ready to spread into rehypePlugins.
export const rehypeMermaidDual = [
  duplicateMermaidFences,
  rehypeMermaidLightPass,
  armDarkMermaidFences,
  rehypeMermaidDarkPass,
];
