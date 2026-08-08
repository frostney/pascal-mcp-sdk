// Streamable HTTP interop: the OFFICIAL stable MCP TypeScript client
// (@modelcontextprotocol/client 2.0.0) against pascal-mcp-sdk's
// mcpdemo serving `--http` on a localhost port — the same battery the
// stdio interop runs, over real HTTP POSTs, plus a progress check
// that only passes when the server streams request-scoped
// notifications on the SSE response.
//
// Usage: node http-interop.mjs /abs/path/to/mcpdemo

import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { readFileSync } from 'node:fs';
import {
  Client,
  StreamableHTTPClientTransport,
} from '@modelcontextprotocol/client';

function installedVersion(packageName) {
  const packageUrl = new URL(
    `./node_modules/${packageName}/package.json`,
    import.meta.url,
  );
  return JSON.parse(readFileSync(packageUrl, 'utf8')).version;
}

console.log(
  'interop packages: ' +
    `@modelcontextprotocol/client ${installedVersion('@modelcontextprotocol/client')}`,
);

const DEMO = process.argv[2];
if (!DEMO) {
  console.error('usage: node http-interop.mjs <path-to-mcpdemo>');
  process.exit(2);
}

let failures = 0;
function check(cond, what) {
  console.log((cond ? 'ok    ' : 'FAIL  ') + what);
  if (!cond) failures++;
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

function startDemo(port) {
  return new Promise((resolve, reject) => {
    const child = spawn(DEMO, ['--http', String(port)], {
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    let banner = '';
    const onData = (chunk) => {
      banner += chunk.toString();
      if (banner.includes('http://127.0.0.1:')) {
        child.stderr.off('data', onData);
        resolve(child);
      }
    };
    child.stderr.on('data', onData);
    child.on('exit', (code) =>
      reject(new Error(`mcpdemo exited early (code ${code})`)),
    );
    setTimeout(() => reject(new Error('mcpdemo startup timed out')), 10000);
  });
}

const port = await freePort();
const demo = await startDemo(port);

try {
  const client = new Client(
    { name: 'ts-http-interop', version: '0.1.0' },
    {
      versionNegotiation: { mode: { pin: '2026-07-28' } },
      capabilities: { elicitation: {} },
    },
  );
  client.setRequestHandler('elicitation/create', async () => ({
    action: 'accept',
    content: { name: 'Ada' },
  }));
  const transport = new StreamableHTTPClientTransport(
    new URL(`http://127.0.0.1:${port}/mcp`),
  );
  await client.connect(transport);

  const discover = client.getDiscoverResult() ?? (await client.discover());
  check(
    discover.supportedVersions?.includes('2026-07-28'),
    'discover: supportedVersions lists 2026-07-28',
  );
  check(!!discover.capabilities?.tools, 'discover: tools capability');

  const tools = await client.listTools();
  check(
    tools.tools.map((t) => t.name).join(',') === 'echo,add,greet_user',
    'tools/list: echo,add,greet_user in registration order',
  );

  const echo = await client.callTool({
    name: 'echo',
    arguments: { message: 'http round trip' },
  });
  check(
    echo.content?.[0]?.type === 'text' &&
      echo.content[0].text === 'http round trip',
    'tools/call echo: text mirrored over HTTP',
  );

  const utf8Payload = 'héllo 世界';
  const utf8Echo = await client.callTool({
    name: 'echo',
    arguments: { message: utf8Payload },
  });
  check(
    utf8Echo.content?.[0]?.text === utf8Payload,
    'tools/call echo: non-ASCII text mirrored as UTF-8',
  );

  // Opting into progress forces the SSE response mode server-side:
  // the notification only reaches us if real events precede the
  // final response on the stream.
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

  const add = await client.callTool({
    name: 'add',
    arguments: { a: 19, b: 23 },
  });
  check(
    add.structuredContent?.sum === 42,
    'tools/call add: structuredContent.sum === 42 (validated against outputSchema)',
  );

  const resources = await client.listResources();
  check(
    resources.resources?.[0]?.uri === 'mcp://pascal-mcp-sdk/greeting',
    'resources/list: greeting present',
  );
  const contents = await client.readResource({
    uri: 'mcp://pascal-mcp-sdk/greeting',
  });
  check(
    contents.contents?.[0]?.text?.includes('Hello from pascal-mcp-sdk'),
    'resources/read: greeting text',
  );

  const prompts = await client.listPrompts();
  check(prompts.prompts?.[0]?.name === 'greet', 'prompts/list: greet present');
  const prompt = await client.getPrompt({
    name: 'greet',
    arguments: { name: 'Ada' },
  });
  check(
    prompt.messages?.[0]?.content?.text?.includes('Ada'),
    'prompts/get: argument woven into message (validated shape)',
  );

  const greeted = await client.callTool({ name: 'greet_user', arguments: {} });
  check(
    greeted.content?.[0]?.text === 'Hello, Ada!',
    'tools/call greet_user: MRTR elicitation round trip over HTTP',
  );

  let unknownRejected = false;
  try {
    await client.callTool({ name: 'nope', arguments: {} });
  } catch (error) {
    unknownRejected = error?.code === -32602;
  }
  check(unknownRejected, 'tools/call unknown: rejected with -32602');

  await client.close();
} finally {
  demo.kill();
}

if (failures > 0) {
  console.error(`\nhttp-interop: ${failures} check(s) FAILED`);
  process.exit(1);
}
console.log(
  '\nhttp-interop: ALL CHECKS PASSED against the official TS client over Streamable HTTP',
);
process.exit(0);
