// Cross-implementation interop: the OFFICIAL stable MCP TypeScript
// client (@modelcontextprotocol/client 2.0.0, the 2026-07-28 client)
// against pascal-mcp-sdk's mcpdemo over real stdio.
//
// Runs the shared modern battery (battery.mjs) twice:
//   1. pinned to 2026-07-28  (modern era, no probe-and-fallback)
//   2. mode 'auto'           (the server/discover probe path a dual-era
//                             client uses in the wild)
//
// Usage: node interop.mjs /abs/path/to/mcpdemo

import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import {
  fatal,
  newModernClient,
  printPackageVersions,
  report,
  runModernBattery,
} from './battery.mjs';

printPackageVersions('@modelcontextprotocol/client');

const DEMO = process.argv[2];
if (!DEMO) {
  console.error('usage: node interop.mjs <path-to-mcpdemo>');
  process.exit(2);
}

async function battery(label, versionNegotiation) {
  console.log(`\n=== ${label} ===`);
  const client = newModernClient('ts-interop', versionNegotiation);
  await client.connect(new StdioClientTransport({ command: DEMO }));
  try {
    await runModernBattery(client);
  } finally {
    await client.close();
  }
}

try {
  await battery('pinned 2026-07-28', { mode: { pin: '2026-07-28' } });
  await battery("mode 'auto' (server/discover probe)", { mode: 'auto' });
} catch (error) {
  fatal(error);
}

process.exit(
  report('interop', 'ALL CHECKS PASSED against the official TS client'),
);
