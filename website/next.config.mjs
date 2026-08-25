import { createMDX } from 'fumadocs-mdx/next';
import { basePath } from './lib/site-identity.mjs';

const withMDX = createMDX();

/** @type {import('next').NextConfig} */
const config = {
  output: 'export',
  // Served at https://frostney.github.io/pascal-mcp-sdk/
  basePath,
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
