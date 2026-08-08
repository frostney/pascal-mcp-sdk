import { createMDX } from 'fumadocs-mdx/next';

const withMDX = createMDX();

/** @type {import('next').NextConfig} */
const config = {
  output: 'export',
  // Served at https://frostney.github.io/pascal-mcp-sdk/
  basePath: '/pascal-mcp-sdk',
  trailingSlash: true,
  reactStrictMode: true,
  // The docs content lives outside website/ (the site renders the
  // repository's docs/ tree directly), so Turbopack's filesystem root
  // must be the repository root.
  turbopack: {
    root: '..',
  },
};

export default withMDX(config);
