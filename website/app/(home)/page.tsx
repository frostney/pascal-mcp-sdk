import Link from 'next/link';
import type { Metadata } from 'next';
import { LogoMark } from '@/components/logo';
import { gitConfig } from '@/lib/shared';
import { readmeCoverage } from '@/lib/readme-coverage';

export const metadata: Metadata = {
  title: 'pascal-mcp-sdk — a FreePascal-native MCP server library',
  description:
    'Give AI agents tools written in Pascal: a FreePascal-native MCP server library with zero third-party dependencies.',
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

export default function HomePage() {
  const github = `https://github.com/${gitConfig.user}/${gitConfig.repo}`;
  // Parsed at build time from the repository README's "Protocol
  // coverage" table — edit the README, not this page.
  const coverage = readmeCoverage();
  return (
    <main className="flex flex-col items-center px-4 py-16 gap-14">
      <section className="flex flex-col items-center text-center gap-5 max-w-2xl">
        <div className="text-fd-primary">
          <LogoMark size={72} />
        </div>
        <h1 className="text-4xl font-bold">pascal-mcp-sdk</h1>
        <p className="text-lg text-fd-muted-foreground">
          Give AI agents tools written in Pascal. pascal-mcp-sdk turns any
          FreePascal program into an MCP (Model Context Protocol) server:
          register tools, resources, and prompts as ordinary Pascal
          functions, and clients like Claude Code and Claude Desktop
          connect out of the box. No second language runtime, no
          framework, zero third-party dependencies — FPC&apos;s RTL and
          fpjson, cross-platform on Linux, macOS, and Windows.
        </p>
        <div className="flex gap-3">
          <Link
            href="/docs/guides/quick-start"
            className="rounded-full bg-fd-primary px-5 py-2.5 font-medium text-fd-primary-foreground"
          >
            Get started
          </Link>
          <Link href="/docs" className="rounded-full border px-5 py-2.5 font-medium">
            Documentation
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
        <p className="mt-3 text-sm text-fd-muted-foreground text-center">
          The library validates arguments against your schema before the
          handler runs, turns exceptions into errors the model can
          correct against, and speaks both the current stateless protocol
          revision and the legacy handshake today&apos;s clients use.{' '}
          <Link href="/docs/guides/tools" className="underline">
            How tools work →
          </Link>
        </p>
      </section>

      <section className="w-full max-w-2xl">
        <h2 className="text-xl font-semibold mb-3 text-center">Install</h2>
        <div className="rounded-lg border bg-fd-card p-4 text-sm flex flex-col gap-3">
          <p>
            <strong>As an lwpt dependency:</strong>{' '}
            <code className="rounded bg-fd-muted px-1.5 py-0.5">
              lwpt add {gitConfig.user}/{gitConfig.repo}@^2.0
            </code>{' '}
            — then <code className="rounded bg-fd-muted px-1.5 py-0.5">uses MCP.Server</code>{' '}
            in your program.
          </p>
          <p>
            <strong>By vendoring:</strong> the library is seven files.
            Copy them from{' '}
            <code className="rounded bg-fd-muted px-1.5 py-0.5">
              source/units/
            </code>{' '}
            into your unit path — RTL + fpjson only, nothing to fetch.
          </p>
          <p>
            <strong>Just trying it out?</strong> Clone the repo and build
            the demo server with plain FPC —{' '}
            <code className="rounded bg-fd-muted px-1.5 py-0.5">
              fpc @lwpt.cfg -FEbuild source/apps/mcpdemo.pas
            </code>{' '}
            — then wire{' '}
            <code className="rounded bg-fd-muted px-1.5 py-0.5">
              build/mcpdemo
            </code>{' '}
            into your MCP client.
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
              {coverage.map(({ surface, marker, status }) => (
                <tr key={surface} className="border-b last:border-b-0">
                  <td className="px-4 py-2 font-mono text-xs">{surface}</td>
                  <td className="px-4 py-2 text-fd-muted-foreground">
                    {marker} {status}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="mt-3 text-sm text-fd-muted-foreground text-center">
          Interop-tested against both official MCP TypeScript clients on
          every pull request.
        </p>
      </section>
    </main>
  );
}
