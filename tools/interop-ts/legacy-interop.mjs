// Legacy-era interop: the OFFICIAL v1 MCP TypeScript SDK client
// (@modelcontextprotocol/sdk — the client library today's clients such
// as Claude Code and Claude Desktop are built on) against pascal-mcp-sdk's
// mcpdemo over stdio. connect() performs the classic initialize
// handshake; this proves the dual-era server serves the legacy era a
// real 2025 client speaks.
//
// Usage: node legacy-interop.mjs /abs/path/to/mcpdemo

import { readFileSync } from 'node:fs';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

function installedVersion(packageName) {
  const packageUrl = new URL(
    `./node_modules/${packageName}/package.json`,
    import.meta.url,
  );
  return JSON.parse(readFileSync(packageUrl, 'utf8')).version;
}

console.log(
  'interop packages: ' +
    `@modelcontextprotocol/client ${installedVersion('@modelcontextprotocol/client')}, ` +
    `@modelcontextprotocol/sdk ${installedVersion('@modelcontextprotocol/sdk')}`,
);

const DEMO = process.argv[2];
if (!DEMO) {
  console.error('usage: node legacy-interop.mjs <path-to-mcpdemo>');
  process.exit(2);
}

let failures = 0;
function check(cond, what) {
  console.log((cond ? 'ok    ' : 'FAIL  ') + what);
  if (!cond) failures++;
}

const client = new Client(
  { name: 'legacy-interop', version: '0.1.0' },
  { capabilities: {} },
);

try {
  // connect() = the legacy initialize/initialized handshake.
  await client.connect(new StdioClientTransport({ command: DEMO }));
  check(true, 'initialize handshake completed (v1 SDK connect)');

  const server = client.getServerVersion();
  check(server?.name === 'pascal-mcp-sdk-demo', 'serverInfo from initialize');
  check(
    typeof client.getInstructions() === 'string' &&
      client.getInstructions().length > 0,
    'instructions from initialize',
  );
  check(!!client.getServerCapabilities()?.tools, 'tools capability declared');

  const tools = await client.listTools();
  check(
    tools.tools.map((t) => t.name).join(',') === 'echo,add',
    'tools/list: echo,add',
  );

  const echo = await client.callTool({
    name: 'echo',
    arguments: { message: 'legacy interop' },
  });
  check(
    echo.content?.[0]?.text === 'legacy interop',
    'tools/call echo: text mirrored',
  );

  const utf8Payload = 'h\u00e9llo \u4e16\u754c';
  const utf8Echo = await client.callTool({
    name: 'echo',
    arguments: { message: utf8Payload },
  });
  check(
    utf8Echo.content?.[0]?.text === utf8Payload,
    'tools/call echo: non-ASCII text mirrored as UTF-8',
  );

  const add = await client.callTool({
    name: 'add',
    arguments: { a: 19, b: 23 },
  });
  check(
    add.structuredContent?.sum === 42,
    'tools/call add: structuredContent.sum === 42',
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

  const templates = await client.listResourceTemplates();
  check(
    templates.resourceTemplates?.[0]?.uriTemplate ===
      'mcp://pascal-mcp-sdk/shout/{text}',
    'resources/templates/list: shout template present',
  );
  const shouted = await client.readResource({
    uri: 'mcp://pascal-mcp-sdk/shout/hey',
  });
  check(
    shouted.contents?.[0]?.text === 'HEY',
    'resources/read: template match (shout/hey → HEY)',
  );

  const prompts = await client.listPrompts();
  check(
    prompts.prompts?.[0]?.name === 'greet',
    'prompts/list: greet present',
  );
  const prompt = await client.getPrompt({
    name: 'greet',
    arguments: { name: 'Ada' },
  });
  check(
    prompt.messages?.[0]?.content?.text?.includes('Ada'),
    'prompts/get: argument woven into message',
  );

  // v1 SDKs map the legacy -32002 resource-not-found to an error.
  let notFound = false;
  try {
    await client.readResource({ uri: 'mcp://nope' });
  } catch (e) {
    notFound = /-?32002|not found/i.test(String(e?.code ?? e));
  }
  check(notFound, 'resources/read unknown: legacy -32002 surfaced');

  await client.close();
} catch (e) {
  console.error('\nFATAL', e);
  failures++;
}

console.log(
  failures === 0
    ? '\nlegacy-interop: ALL CHECKS PASSED against the v1 SDK client'
    : `\nlegacy-interop: ${failures} check(s) FAILED`,
);
process.exit(failures === 0 ? 0 : 1);
