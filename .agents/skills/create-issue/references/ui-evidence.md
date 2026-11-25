# UI/UX and media evidence for issues

Use this reference when the issue concerns UI/UX work or its evidence includes
local screenshots or videos.

- For UI/UX work, add the affected states, current and expected visual
  evidence, accessibility expectations, responsive/theme scope, and applicable
  design system components or tokens.
- Put local screenshots and videos into the body in the command that writes
  it, so the issue never exists without them: reference each file as
  `![alt text](<path>)` and pass `--attach <path>` to
  `gh issue create --body-file FILE`, or to `gh issue edit N --body-file FILE`
  when rewriting an existing issue's body. Run it from the repository root
  with the same path in the reference and the flag, and read the body back,
  as
  [PR media](../../create-pr/references/walkthroughs.md#upload-media)
  describes. When an upload fails, gh can still create the issue with the
  files that uploaded and exit non-zero: search for the issue before
  retrying, and write its complete body again with `gh issue edit`. Media
  that belongs in a comment goes in with that comment's
  `gh issue comment N --body-file FILE --attach <path>`.
