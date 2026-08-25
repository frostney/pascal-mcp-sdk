// One JavaScript-compatible source for repository and deployment
// identity. Consumed by shared.ts, next.config.mjs, and the remark
// transformer so a rename, default-branch change, or Pages base-path
// move cannot leave citation surfaces and rendered links disagreeing.
export const gitConfig = {
  user: 'frostney',
  repo: 'pascal-mcp-sdk',
  branch: 'main',
};

export const appName = gitConfig.repo;
export const basePath = `/${gitConfig.repo}`;
export const repoUrl = `https://github.com/${gitConfig.user}/${gitConfig.repo}`;
export const siteUrl = `https://${gitConfig.user}.github.io${basePath}`;
