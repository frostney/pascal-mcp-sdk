// Streamable HTTP interop: the OFFICIAL stable MCP TypeScript client
// (@modelcontextprotocol/client 2.0.0) against pascal-mcp-sdk's
// mcpdemo serving `--http` on a localhost port — the shared modern
// battery (battery.mjs), byte-for-byte the same checks the stdio run
// makes, over real HTTP POSTs, plus a progress check that only passes
// when the server streams request-scoped notifications on the SSE
// response.
//
// Usage: node http-interop.mjs /abs/path/to/mcpdemo

import { StreamableHTTPClientTransport } from '@modelcontextprotocol/client';
import {
  check,
  fatal,
  newModernClient,
  printPackageVersions,
  report,
  runModernBattery,
} from './battery.mjs';
import { freePort, startDemo } from './demo-http.mjs';

printPackageVersions('@modelcontextprotocol/client');

const DEMO = process.argv[2];
if (!DEMO) {
  console.error('usage: node http-interop.mjs <path-to-mcpdemo>');
  process.exit(2);
}

const port = await freePort();
const demo = await startDemo(DEMO, port);

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
