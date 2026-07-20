// Cross-implementation interop: the OFFICIAL MCP TypeScript client beta
// (@modelcontextprotocol/client 2.0.0-beta.4, the 2026-07-28 RC client)
// against pascal-mcp-sdk's mcpdemo over real stdio.
//
// Runs the battery twice:
//   1. pinned to 2026-07-28  (modern era, no probe-and-fallback)
//   2. mode 'auto'           (the server/discover probe path a dual-era
//                             client uses in the wild)
//
// Usage: node interop.mjs /abs/path/to/mcpdemo

import { readFileSync } from 'node:fs';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

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
  console.error('usage: node interop.mjs <path-to-mcpdemo>');
  process.exit(2);
}

let failures = 0;
function check(cond, what) {
  console.log((cond ? 'ok    ' : 'FAIL  ') + what);
  if (!cond) failures++;
}

async function battery(label, versionNegotiation) {
  console.log(`\n=== ${label} ===`);
  const client = new Client(
    { name: 'ts-interop', version: '0.1.0' },
    { versionNegotiation },
  );
  const transport = new StdioClientTransport({ command: DEMO });
  await client.connect(transport);

  const discover = client.getDiscoverResult() ?? (await client.discover());
  check(
    discover.supportedVersions?.includes('2026-07-28'),
    'discover: supportedVersions lists 2026-07-28',
  );
  check(!!discover.capabilities?.tools, 'discover: tools capability');
  check(
    typeof discover.instructions === 'string' &&
      discover.instructions.length > 0,
    'discover: instructions present',
  );

  const tools = await client.listTools();
  check(
    tools.tools.map((t) => t.name).join(',') === 'echo,add',
    'tools/list: echo,add in registration order',
  );

  const echo = await client.callTool({
    name: 'echo',
    arguments: { message: 'interop round trip' },
  });
  check(
    echo.content?.[0]?.type === 'text' &&
      echo.content[0].text === 'interop round trip',
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
    'prompts/get: argument woven into message (validated shape)',
  );

  // Unknown tool must surface as a protocol error (-32602), not a result.
  let unknownRejected = false;
  try {
    await client.callTool({ name: 'nope', arguments: {} });
  } catch (e) {
    unknownRejected = /-?32602|Unknown tool/i.test(String(e?.code ?? e));
  }
  check(unknownRejected, 'tools/call unknown: rejected with -32602');

  await client.close();
}

try {
  await battery('pinned 2026-07-28', { mode: { pin: '2026-07-28' } });
  await battery("mode 'auto' (server/discover probe)", { mode: 'auto' });
} catch (e) {
  console.error('\nFATAL', e);
  failures++;
}

console.log(
  failures === 0
    ? '\ninterop: ALL CHECKS PASSED against the official TS client beta'
    : `\ninterop: ${failures} check(s) FAILED`,
);
process.exit(failures === 0 ? 0 : 1);
