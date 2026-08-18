import Link from 'next/link';
import type { Metadata } from 'next';
import { codeToHtml } from 'shiki';
import { LogoMark } from '@/components/logo';
import { gitConfig, pageUrl, repoUrl } from '@/lib/shared';

export const metadata: Metadata = {
  title: { absolute: 'pascal-mcp-sdk — a FreePascal-native MCP server library' },
  description:
    'Give AI agents tools written in Pascal: a FreePascal-native MCP (Model Context Protocol) server library with zero third-party dependencies, stdio and Streamable HTTP transports, and out-of-the-box Claude Code support.',
  alternates: { canonical: pageUrl('/') },
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

// One source for the visible FAQ section and the FAQPage JSON-LD —
// keep answers plain text (links live in the rendered extras below).
const FAQ: { q: string; a: string; extra?: React.ReactNode }[] = [
  {
    q: 'What is pascal-mcp-sdk?',
    a: 'A FreePascal-native library for building MCP (Model Context Protocol) servers: expose tools, resources, and prompts from any Pascal program to AI agents. It has zero third-party runtime dependencies — just FPC’s RTL and fpjson — and runs on Linux, macOS, and Windows.',
  },
  {
    q: 'Does Claude Code work with a Pascal MCP server?',
    a: 'Yes — and so does Codex. Servers are dual-era by default: they answer the classic initialize handshake current clients still speak alongside the newest stateless protocol revision, and pick per connection. No configuration needed on either side.',
  },
  {
    q: 'How do I build an MCP server in Pascal?',
    a: 'Install FPC 3.2.2, add the library (lwpt add frostney/pascal-mcp-sdk@^2.0, or vendor its seven source files), register your tools with a name, description, and JSON Schema, and call RunMCPStdioServer. The quick start walks through a complete server in a few minutes.',
  },
  {
    q: 'Which parts of the MCP specification are implemented?',
    a: 'Tools, resources with RFC 6570 templates, prompts, multi-round-trip input requests (elicitation, sampling, roots), progress and log notifications, caching hints, stdio and Streamable HTTP transports, plus the classic initialize handshake era that current clients speak. Deliberately out: subscriptions/listen and list-changed notifications, since registries are static after startup.',
  },
  {
    q: 'Is this the same as claude-pascal-mcp or @pascal-app/mcp?',
    a: 'No. pascal-mcp-sdk is a FreePascal library for writing MCP servers in Pascal. tina4stack/claude-pascal-mcp is a Python MCP server that compiles Pascal. @pascal-app/mcp is the MCP for a 3D editor. Same word, different products.',
  },
];

function jsonLd() {
  return {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'SoftwareApplication',
        name: 'pascal-mcp-sdk',
        alternateName: 'FreePascal MCP server library',
        description:
          'A FreePascal-native MCP (Model Context Protocol) server library with zero third-party dependencies.',
        url: pageUrl('/'),
        applicationCategory: 'DeveloperApplication',
        operatingSystem: 'Linux, macOS, Windows',
        license: 'https://opensource.org/license/mit',
        codeRepository: repoUrl,
        sameAs: [repoUrl],
        programmingLanguage: 'Pascal',
        offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
      },
      {
        '@type': 'FAQPage',
        mainEntity: FAQ.map(({ q, a }) => ({
          '@type': 'Question',
          name: q,
          acceptedAnswer: { '@type': 'Answer', text: a },
        })),
      },
    ],
  };
}

export default async function HomePage() {
  const quickStartHtml = await codeToHtml(QUICK_START, {
    lang: 'pascal',
    themes: { light: 'github-light', dark: 'github-dark' },
    defaultColor: false,
  });
  return (
    <main className="flex flex-col items-center px-4 py-16 gap-14">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd()) }}
      />
      <section className="flex flex-col items-center text-center gap-5 max-w-2xl">
        <div className="text-fd-primary">
          <LogoMark size={72} />
        </div>
        <h1 className="text-4xl font-bold">
          FreePascal-native MCP server library
        </h1>
        <p className="text-sm text-fd-muted-foreground">pascal-mcp-sdk</p>
        <p className="text-lg text-fd-muted-foreground">
          Give AI agents tools written in Pascal. pascal-mcp-sdk turns any{' '}
          <a href="https://www.freepascal.org" className="underline">
            FreePascal
          </a>{' '}
          program into an{' '}
          <a href="https://modelcontextprotocol.io" className="underline">
            MCP (Model Context Protocol)
          </a>{' '}
          server: register tools, resources, and prompts as ordinary
          Pascal functions, and clients like{' '}
          <a href="https://claude.com/product/claude-code" className="underline">
            Claude Code
          </a>{' '}
          and{' '}
          <a href="https://claude.com/download" className="underline">
            Claude Desktop
          </a>{' '}
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
            href={repoUrl}
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
        <div
          className="landing-code rounded-lg border text-left text-sm overflow-x-auto [&>pre]:p-4 [&>pre]:m-0 [&>pre]:bg-transparent"
          dangerouslySetInnerHTML={{ __html: quickStartHtml }}
        />
        <p className="mt-3 text-sm text-fd-muted-foreground text-center">
          The library validates arguments against your{' '}
          <a href="https://json-schema.org" className="underline">
            JSON Schema
          </a>{' '}
          before the handler runs, turns exceptions into errors the model
          can correct against, and speaks both the newest stateless
          protocol revision and the classic handshake today&apos;s clients
          use.{' '}
          <Link href="/docs/guides/tools" className="underline">
            How tools work →
          </Link>
        </p>
      </section>

      <section className="w-full max-w-2xl">
        <h2 className="text-xl font-semibold mb-3 text-center">Install</h2>
        <div className="rounded-lg border bg-fd-card p-4 text-sm flex flex-col gap-3">
          <p>
            <strong>
              As an{' '}
              <a href="https://github.com/frostney/lwpt" className="underline">
                lwpt
              </a>{' '}
              dependency:
            </strong>{' '}
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
        <p className="mt-3 text-sm text-fd-muted-foreground text-center">
          The 2026-07-28 protocol surface — everything except
          subscriptions — is implemented and interop-tested against both
          official MCP TypeScript clients; see{' '}
          <Link href="/docs/reference/protocol-coverage" className="underline">
            protocol coverage
          </Link>
          .
        </p>
      </section>

      <section className="w-full max-w-2xl">
        <h2 className="text-xl font-semibold mb-3 text-center">
          Frequently asked questions
        </h2>
        <div className="flex flex-col gap-4">
          {FAQ.map(({ q, a }) => (
            <details key={q} className="rounded-lg border bg-fd-card p-4 text-sm">
              <summary className="font-medium cursor-pointer">{q}</summary>
              <p className="mt-2 text-fd-muted-foreground">{a}</p>
            </details>
          ))}
        </div>
      </section>
    </main>
  );
}
