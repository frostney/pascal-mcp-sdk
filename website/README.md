This is a Next.js application generated with
[Create Fumadocs](https://github.com/fuma-nama/fumadocs).

It is a Next.js app with [Static Export](https://nextjs.org/docs/app/guides/static-exports) configured.

Run development server:

```bash
npm run dev
# or
pnpm dev
# or
yarn dev
```

Open http://localhost:3000 with your browser to see the result.

## Preview the static export

The site is exported with `basePath: /pascal-mcp-sdk`, so its pages
request assets under `/pascal-mcp-sdk/...`. To preview the exported
`out/` with that prefix in place (matching the deployed layout):

```bash
npm run build
npm run start
# Preview serving out/ at http://localhost:3000/pascal-mcp-sdk/
```

`npm run start` runs `scripts/preview.mjs`, a tiny dependency-free static
server that mounts `out/` under `/pascal-mcp-sdk/` (set `PORT`/`HOST` to
override). A plain root-mounted server would 404 because the pages expect
the base path. Open http://localhost:3000/pascal-mcp-sdk/.

## Explore

In the project, you can see:

- `lib/source.ts`: Code for content source adapter, [`loader()`](https://fumadocs.dev/docs/headless/source-api) provides the interface to access your content.
- `lib/layout.shared.tsx`: Shared options for layouts, optional but preferred to keep.

| Route                     | Description                                            |
| ------------------------- | ------------------------------------------------------ |
| `app/(home)`              | The route group for your landing page and other pages. |
| `app/docs`                | The documentation layout and pages.                    |
| `app/api/search/route.ts` | The Route Handler for search.                          |

### Fumadocs MDX

Collections are defined with the [Macro API](https://fumadocs.dev/docs/mdx/macro) in `lib/source.ts`.

Read the [Introduction](https://fumadocs.dev/docs/mdx) for further details.

## Learn More

To learn more about Next.js and Fumadocs, take a look at the following
resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js
  features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.
- [Fumadocs](https://fumadocs.dev) - learn about Fumadocs
