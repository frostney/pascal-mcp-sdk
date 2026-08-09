// Streamable HTTP interop: the OFFICIAL stable MCP TypeScript client
// (@modelcontextprotocol/client 2.0.0) against pascal-mcp-sdk's
// mcpdemo serving `--http` on a localhost port — the shared modern
// battery (battery.mjs), byte-for-byte the same checks the stdio run
// makes, over real HTTP POSTs, plus a progress check that only passes
// when the server streams request-scoped notifications on the SSE
// response.
//
// Usage: node http-interop.mjs /abs/path/to/mcpdemo

import { spawn } from 'node:child_process';
import { createServer, connect } from 'node:net';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/client';
import {
  check,
  fatal,
  newModernClient,
  printPackageVersions,
  report,
  runModernBattery,
} from './battery.mjs';

printPackageVersions('@modelcontextprotocol/client');

const DEMO = process.argv[2];
if (!DEMO) {
  console.error('usage: node http-interop.mjs <path-to-mcpdemo>');
  process.exit(2);
}

// Ask the kernel for a free port, release it, hand it to mcpdemo.
function freePort() {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.listen(0, '127.0.0.1', () => {
      const port = probe.address().port;
      probe.close(() => resolve(port));
    });
    probe.on('error', reject);
  });
}

// One connect attempt; resolves to whether the port accepted it.
function canConnect(port) {
  return new Promise((resolve) => {
    const socket = connect({ host: '127.0.0.1', port });
    const settle = (ok) => {
      socket.destroy();
      resolve(ok);
    };
    socket.once('connect', () => settle(true));
    socket.once('error', () => settle(false));
    socket.setTimeout(250, () => settle(false));
  });
}

// mcpdemo prints its banner BEFORE the listener binds, so the banner
// alone is not readiness: poll the port until a connection is accepted.
async function waitUntilListening(port, timeoutMs = 5000, intervalMs = 50) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (await canConnect(port)) return;
    if (Date.now() >= deadline)
      throw new Error(`mcpdemo never listened on 127.0.0.1:${port}`);
    await new Promise((resume) => setTimeout(resume, intervalMs));
  }
}

function startDemo(port) {
  return new Promise((resolve, reject) => {
    const child = spawn(DEMO, ['--http', String(port)], {
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    const timer = setTimeout(
      () => reject(new Error('mcpdemo startup timed out')),
      10000,
    );
    let banner = '';
    const onData = (chunk) => {
      banner += chunk.toString();
      if (!banner.includes('http://127.0.0.1:')) return;
      child.stderr.off('data', onData);
      waitUntilListening(port).then(
        () => {
          clearTimeout(timer);
          resolve(child);
        },
        (error) => {
          clearTimeout(timer);
          reject(error);
        },
      );
    };
    child.stderr.on('data', onData);
    child.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`mcpdemo exited early (code ${code})`));
    });
  });
}

const port = await freePort();
const demo = await startDemo(port);

try {
  const client = newModernClient('ts-http-interop', {
    mode: { pin: '2026-07-28' },
  });
  await client.connect(
    new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`)),
  );

  await runModernBattery(client);

  // HTTP-only extra: opting into progress forces the SSE response mode
  // server-side, so the notification only reaches us if real events
  // precede the final response on the stream.
  const progressUpdates = [];
  const streamed = await client.callTool(
    { name: 'echo', arguments: { message: 'stream me' } },
    { onprogress: (p) => progressUpdates.push(p) },
  );
  check(
    streamed.content?.[0]?.text === 'stream me',
    'tools/call echo: result delivered on the SSE stream',
  );
  check(
    progressUpdates.length > 0,
    'tools/call echo: progress notifications streamed before the response',
  );

  await client.close();
} catch (error) {
  fatal(error);
} finally {
  demo.kill();
}

process.exit(
  report(
    'http-interop',
    'ALL CHECKS PASSED against the official TS client over Streamable HTTP',
  ),
);
