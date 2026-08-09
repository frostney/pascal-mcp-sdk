// Shared interop machinery for the batteries in this directory.
//
// The modern (2026-07-28) battery lives here exactly once so the stdio
// and Streamable HTTP runs assert the identical surface — a check added
// for one transport is automatically made for the other, and the two
// can no longer drift apart. Transport construction, the extras only
// one transport can prove (SSE streaming), and the legacy-era battery
// stay in the individual scripts.

import { readFileSync } from 'node:fs';
import { Client } from '@modelcontextprotocol/client';

export function installedVersion(packageName) {
  const packageUrl = new URL(
    `./node_modules/${packageName}/package.json`,
    import.meta.url,
  );
  return JSON.parse(readFileSync(packageUrl, 'utf8')).version;
}

// Each battery records the implementation versions it ran against.
export function printPackageVersions(...packageNames) {
  console.log(
    'interop packages: ' +
      packageNames
        .map((name) => `${name} ${installedVersion(name)}`)
        .join(', '),
  );
}

let failures = 0;

export function check(cond, what) {
  console.log((cond ? 'ok    ' : 'FAIL  ') + what);
  if (!cond) failures++;
}

export function fatal(error) {
  console.error('\nFATAL', error);
  failures++;
}

// Prints the closing line and returns the process exit code.
export function report(name, successLine) {
  if (failures > 0) {
    console.error(`\n${name}: ${failures} check(s) FAILED`);
    return 1;
  }
  console.log(`\n${name}: ${successLine}`);
  return 0;
}

// A v2 client that auto-fulfils MRTR elicitations: input_required is
// answered through this handler and the original call retried by the
// client's driver.
export function newModernClient(name, versionNegotiation) {
  const client = new Client(
    { name, version: '0.1.0' },
    { versionNegotiation, capabilities: { elicitation: {} } },
  );
  client.setRequestHandler('elicitation/create', async () => ({
    action: 'accept',
    content: { name: 'Ada' },
  }));
  return client;
}

// The modern-era surface, driven over whichever transport the caller
// already connected. Every check here runs on every modern transport.
export async function runModernBattery(client) {
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
    tools.tools.map((t) => t.name).join(',') === 'echo,add,greet_user,pixel',
    'tools/list: echo,add,greet_user,pixel in registration order',
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

  const utf8Payload = 'héllo 世界';
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
  check(prompts.prompts?.[0]?.name === 'greet', 'prompts/list: greet present');
  const prompt = await client.getPrompt({
    name: 'greet',
    arguments: { name: 'Ada' },
  });
  check(
    prompt.messages?.[0]?.content?.text?.includes('Ada'),
    'prompts/get: argument woven into message (validated shape)',
  );

  // MRTR (SEP-2322): greet_user answers input_required with an
  // elicitation form; the client's driver fulfils it via the handler
  // on the client and retries with inputResponses + the echoed
  // requestState.
  const greeted = await client.callTool({ name: 'greet_user', arguments: {} });
  check(
    greeted.content?.[0]?.text === 'Hello, Ada!',
    'tools/call greet_user: MRTR elicitation round trip (auto-fulfilled)',
  );

  // Unknown tool must surface as a protocol error, not a result — and
  // as exactly -32602, asserted strictly on every transport.
  let unknownCode;
  try {
    await client.callTool({ name: 'nope', arguments: {} });
  } catch (error) {
    unknownCode = error?.code;
  }
  check(unknownCode === -32602, 'tools/call unknown: rejected with -32602');
}
