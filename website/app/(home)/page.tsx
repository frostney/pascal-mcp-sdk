import Link from 'next/link';
import type { Metadata } from 'next';
import { LogoMark } from '@/components/logo';
import { gitConfig } from '@/lib/shared';

export const metadata: Metadata = {
  title: 'pascal-mcp-sdk — a FreePascal-native MCP server library',
  description:
    'Expose tools, resources, and prompts from any Pascal program to AI agents — no second language runtime, no framework.',
};

const QUICK_START = `Server := TMCPServer.Create('my-server', '1.0.0');
try
  Server.RegisterTool('greet', 'Greet someone by name',
    ObjectSchema.AddString('name', 'Who to greet'),
    Greet);
  RunMCPStdioServer(Server);  // serves until the client closes stdin
finally
  Server.Free;
end;`;

// Source of truth: the "Protocol coverage" table in the repository
// README.md. This array mirrors it row for row — when that table
// changes, mirror the change here (and keep each row's own status
// marker, so a not-implemented row renders as ⏳ rather than ✅).
const COVERAGE: [surface: string, marker: string, status: string][] = [
  ['server/discover', '✅', 'mandatory entry point, capabilities + instructions'],
  ['tools/list, tools/call', '✅', 'text / structured content, in-band errors, server-side argument validation'],
  ['resources/list, resources/read', '✅', 'static + dynamic, text + blob builders'],
  ['resources/templates/list', '✅', 'RFC 6570 level-1 templates, vars passed to readers'],
  ['prompts/list, prompts/get', '✅', 'fluent argument declaration, message builders'],
  ['MRTR input_required (SEP-2322)', '✅', 'elicitation / sampling / roots, capability-gated, stateless re-entry'],
  ['notifications/progress, notifications/message', '✅', 'opt-in per request, severity-filtered'],
  ['_meta validation, version negotiation', '✅', '-32602 / -32021 / -32022 per spec'],
  ['ttlMs / cacheScope caching hints (SEP-2549)', '✅', 'on discover/list/read, tunable via CacheTtlMs / CacheScope'],
  ['stdio transport', '✅', 'newline-delimited, EOF shutdown contract'],
  ['Streamable HTTP transport', '✅', 'single POST endpoint, SSE streams, header mirroring, Origin allowlist'],
  ['Legacy era (initialize)', '✅', '2024-11-05 / 2025-06-18 / 2025-11-25 — Claude Code and Claude Desktop connect out of the box'],
  ['subscriptions/listen, list-changed', '⏳', 'not implemented (registries are static after startup)'],
];

export default function HomePage() {
  const github = `https://github.com/${gitConfig.user}/${gitConfig.repo}`;
  return (
    <main className="flex flex-col items-center px-4 py-16 gap-14">
      <section className="flex flex-col items-center text-center gap-5 max-w-2xl">
        <div className="text-fd-primary">
          <LogoMark size={72} />
        </div>
        <h1 className="text-4xl font-bold">pascal-mcp-sdk</h1>
        <p className="text-lg text-fd-muted-foreground">
          A FreePascal-native MCP (Model Context Protocol) server library.
          Dependency-light, cross-platform, targeting the current stateless
          protocol revision (2026-07-28). Expose tools, resources, and
          prompts from any Pascal program to AI agents — no second language
          runtime, no framework.
        </p>
        <div className="flex gap-3">
          <Link
            href="/docs/quick-start"
            className="rounded-full bg-fd-primary px-5 py-2.5 font-medium text-fd-primary-foreground"
          >
            Get started
          </Link>
          <a
            href={github}
            className="rounded-full border px-5 py-2.5 font-medium"
          >
            GitHub
          </a>
        </div>
      </section>

      <section className="w-full max-w-2xl">
        <h2 className="text-xl font-semibold mb-3 text-center">
          Register a tool, serve it
        </h2>
        <pre className="rounded-lg border bg-fd-card p-4 text-left text-sm overflow-x-auto">
          <code>{QUICK_START}</code>
        </pre>
      </section>

      <section className="w-full max-w-2xl">
        <h2 className="text-xl font-semibold mb-3 text-center">Install</h2>
        <div className="rounded-lg border bg-fd-card p-4 text-sm flex flex-col gap-3">
          <p>
            <strong>As an lwpt dependency:</strong>{' '}
            <code className="rounded bg-fd-muted px-1.5 py-0.5">
              lwpt add {gitConfig.user}/{gitConfig.repo}@^1.0
            </code>
          </p>
          <p>
            <strong>By vendoring:</strong> copy the seven files under{' '}
            <code className="rounded bg-fd-muted px-1.5 py-0.5">
              source/units/
            </code>{' '}
            into your unit path — RTL + fpjson only.
          </p>
          <p>
            <strong>Zero-install from a clone:</strong>{' '}
            <code className="rounded bg-fd-muted px-1.5 py-0.5">
              fpc @lwpt.cfg -FEbuild source/apps/mcpdemo.pas
            </code>{' '}
            — no lwpt binary required.
          </p>
        </div>
      </section>

      <section className="w-full max-w-3xl">
        <h2 className="text-xl font-semibold mb-3 text-center">
          Protocol coverage
        </h2>
        <div className="rounded-lg border overflow-x-auto">
          <table className="w-full text-sm text-left">
            <thead>
              <tr className="border-b bg-fd-muted/50">
                <th className="px-4 py-2 font-medium">Surface</th>
                <th className="px-4 py-2 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {COVERAGE.map(([surface, marker, status]) => (
                <tr key={surface} className="border-b last:border-b-0">
                  <td className="px-4 py-2 font-mono text-xs whitespace-nowrap">
                    {surface}
                  </td>
                  <td className="px-4 py-2 text-fd-muted-foreground">
                    {marker} {status}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}
