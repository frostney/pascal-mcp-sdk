# Introduction

**MCP for Pascal developers.** You know Pascal; you keep hearing
about AI agents; this page connects the two. No AI background
assumed.

## What an AI agent actually is

A large language model (LLM) on its own can only produce text. What
turns it into an *agent* is a loop: the model runs inside a host
application — Claude Code in a terminal, Claude Desktop on a desktop,
Codex, an IDE assistant — that offers it **functions it may call**.
The model reads a user request, decides a function would help,
"calls" it by emitting the function's name and arguments as
structured output, the host executes the real function, and the
result is fed back into the model's context so it can continue — call
again, or answer the user.

That's the whole trick. The model never executes anything itself; it
asks, and the host runs real code. The quality of an agent therefore
depends a lot on *which functions it is given* — and that is exactly
the part you can supply.

## What MCP standardizes

Without a standard, every AI application would need bespoke plumbing
for every data source or capability. The
[Model Context Protocol](https://modelcontextprotocol.io) (MCP) is an
open, vendor-neutral protocol that standardizes that plumbing — think
"USB for AI capabilities". Three roles:

- **Server** — a program that *offers* capabilities. This is what you
  build with pascal-mcp-sdk.
- **Client** — the protocol side of an AI application that connects
  to servers, discovers what they offer, and calls it.
- **Host** — the application the user actually uses (Claude Code,
  Claude Desktop, Codex, …), which embeds a client and decides,
  through its model, when to call your server.

A server offers three kinds of things, each meaning something
different to the model:

- **Tools** — functions the *model* decides to call: "add these
  numbers", "query this database", "run this calculation". The bread
  and butter.
- **Resources** — data the client can *read* and place into the
  model's context: files, configs, reports, addressed by URI.
- **Prompts** — message templates the *user* invokes explicitly (a
  slash command, a menu entry), with declared arguments.

The wire format underneath is JSON-RPC 2.0 — newline-delimited JSON
over stdin/stdout in the common case ("stdio transport"), or HTTP
POSTs for long-running services. You will rarely look at it, but when
you want to, [Your first conversation](first-conversation.md) shows a
complete real exchange line by line.

## Where your Pascal code fits

A pascal-mcp-sdk server is an ordinary FreePascal program. You
register each capability with a name, a description **written for the
model to read**, and a handler — a plain Pascal function:

```pascal
Server.RegisterTool('add', 'Add two numbers and return the sum',
  TAddArgs, AddHandler);
RunMCPStdioServer(Server);
```

The host launches your binary as a subprocess, speaks the protocol
over its stdin/stdout, and your handler runs when the model decides
your tool is the right one for the job. The library handles
everything protocol-shaped: discovery, argument validation against
your schema, error mapping, version negotiation across protocol
revisions.

Why Pascal is a genuinely good fit here: an MCP stdio server is a
small native binary the host starts and stops on demand — no
interpreter to ship, no virtual environment to activate, instant
startup, single-file deployment. The things FPC has always been good
at.

## What happens end to end

1. You register your server's binary with a host once
   (`claude mcp add my-server /path/to/binary`).
2. When a session starts, the host launches the binary and the client
   introduces itself; server and client agree on a protocol revision
   (the library supports the current revisions on both sides of the
   spec's big 2026 transition — you don't have to care).
3. The client asks what you offer (`tools/list`, …) and hands the
   catalog — names, descriptions, schemas — to the model.
4. The user asks something. If the model decides your tool helps, the
   client sends `tools/call`, your handler runs, and the result goes
   back into the model's context.
5. The model answers the user, quoting your result. When the session
   ends, the host closes your process's stdin and it exits.

Steps 2, 3, and 5 are entirely the library's job; step 4 is your
handler. You write domain logic; the protocol is somebody else's
problem — specifically, this library's.

## Where to go next

- [Quick start](quick-start.md) — build and register a working server
  in a few minutes.
- [Your first conversation](first-conversation.md) — watch a real
  agent call a real Pascal tool, on the wire and on screen.
- [Tools](tools.md), [Resources](resources.md),
  [Prompts](prompts.md) — each capability in depth.
