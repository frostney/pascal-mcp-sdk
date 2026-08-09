// Local static preview for the exported site.
//
// `next build` (output: 'export') emits out/ with every asset and page
// URL prefixed by the basePath (/pascal-mcp-sdk). A plain `serve out`
// hands those files back at the root, so the pages request
// /pascal-mcp-sdk/_next/... and 404 locally. This tiny static server
// mounts out/ under the basePath instead, reproducing the deployed URL
// layout (https://frostney.github.io/pascal-mcp-sdk/) so links, assets,
// and docs routes resolve exactly as they will in production.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(here, '..', 'out');
const basePath = '/pascal-mcp-sdk';
const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? 'localhost';

const contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.map': 'application/json; charset=utf-8',
};

if (!fs.existsSync(outDir)) {
  console.error(`out/ not found at ${outDir} — run "npm run build" first.`);
  process.exit(1);
}

// Resolve a request path (already stripped of the base prefix) to a file
// inside out/, honouring the trailingSlash export layout where every
// route is a directory holding index.html.
function resolveFile(urlPath) {
  // A malformed percent sequence (e.g. "/%") throws URIError inside
  // the request handler; treat it as not-found instead of crashing
  // the preview process.
  let clean;
  try {
    clean = decodeURIComponent(urlPath.split('?')[0]);
  } catch {
    return null;
  }
  // Contain traversal to out/.
  const abs = path.normalize(path.join(outDir, clean));
  if (abs !== outDir && !abs.startsWith(outDir + path.sep)) return null;

  const candidates = [];
  if (path.extname(abs)) {
    candidates.push(abs);
  } else {
    candidates.push(path.join(abs, 'index.html'));
    candidates.push(abs + '.html');
  }
  for (const candidate of candidates) {
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
      return candidate;
    }
  }
  return null;
}

const server = http.createServer((req, res) => {
  const reqPath = (req.url ?? '/').split('?')[0];

  // Bare root redirects into the mounted base path.
  if (reqPath === '/' || reqPath === '') {
    res.writeHead(302, { Location: `${basePath}/` });
    res.end();
    return;
  }

  if (reqPath !== basePath && !reqPath.startsWith(basePath + '/')) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(`Not found. The site is mounted at ${basePath}/`);
    return;
  }

  const inner = reqPath.slice(basePath.length) || '/';
  const file = resolveFile(inner);
  if (!file) {
    // Fall back to the exported 404 page when present.
    const notFound = path.join(outDir, '404.html');
    if (fs.existsSync(notFound)) {
      res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
      fs.createReadStream(notFound).pipe(res);
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Not found');
    return;
  }

  res.writeHead(200, {
    'Content-Type': contentTypes[path.extname(file)] ?? 'application/octet-stream',
  });
  fs.createReadStream(file).pipe(res);
});

server.listen(port, host, () => {
  console.log(`Preview serving out/ at http://${host}:${port}${basePath}/`);
});
