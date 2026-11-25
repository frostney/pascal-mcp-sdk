---
name: template-check
description: >-
  Compares an issue or pull request body's headings with the repository's
  template, used internally by issue and PR workflows. Use when another
  workflow must check a draft or posted body against its template.
license: Unlicense OR MIT
compatibility: >-
  Requires Python 3.11 or newer, git and the cmarkgfm package, GitHub's
  cmark-gfm renderer, and PyYAML, which the script runs through uv when they
  are not installed. Reading a live body or a remote repository's templates also
  requires the GitHub CLI (gh) authenticated to that repository, and network
  access.
---

# Template check

Run `scripts/check_template.py` to compare a body's headings with the template
it should follow. It reports each template heading that is missing, renamed,
out of order or left empty. The caller owns the rule the body must meet and
fixes the body; this skill only reports.

## Running a check

Run it as `python3 "$SKILL_DIR/scripts/check_template.py"`, where `SKILL_DIR`
is this skill's directory, from the checkout of the repository the body
belongs to.

- Check a draft with `--body FILE`, or `--body -` for standard input, plus
  `--kind issue` or `--kind pr`. Check a posted body with `--pr N` or
  `--issue N`.
- The template is discovered where GitHub looks for it, in the root, `docs/`
  and `.github/`: `pull_request_template.md` or a `PULL_REQUEST_TEMPLATE/`
  folder for PRs, and `issue_template.md` or an `ISSUE_TEMPLATE/` folder of
  templates and issue forms for issues. `--root` names another checkout.
  `--repo OWNER/REPO`, `HOST/OWNER/REPO` or the repository's URL names the
  repository for `--pr` and `--issue` and, without `--root`, reads the
  templates from its default branch.
- With several templates, pass the one the body follows with
  `--template-name`, matching its front matter `name` or its file name.
  Without it the closest fit is used, and a tie is an error. Choose it from
  what the body is for, such as the issue's or PR's labels or title, and ask
  only when nothing settles it. `--template PATH` skips discovery; an issue
  form passed that way checks an issue body without `--kind`.
- `--json` prints one JSON object with the same result.

## Reading the result

- Exit 0 with `match`: every template heading is present, verbatim, in order
  and has content.
- Exit 0 with `no-template`: the repository has no template with headings, or
  the template `--template-name` names has none, so there is nothing to
  compare.
- Exit 1 with `mismatch`: fix each reported heading in the body and run the
  check again. A Markdown template's heading is reported as the template
  writes it, so it can be pasted into the body.
- Exit 2 with `operational-error`: the check could not compare, for example
  outside a git checkout, without the Markdown renderer, for an
  unreachable repository, for an issue form it cannot read, or for a body that
  fits several templates equally. Fix the
  cause it names, pass `--repo`, `--template-name` or `--template PATH` as it
  says, and never treat it as a pass.

It reads a Markdown body or template as GitHub renders it: with cmark-gfm,
the engine behind GitHub's Markdown, run locally, so a heading counts exactly
where GitHub shows one and nothing is sent anywhere to be rendered. Without
the `cmarkgfm` package, or PyYAML for issue forms and front matter, it runs
that package through uv with a pinned version from PyPI alone, outside the
checkout and ignoring uv configuration and index settings; without uv, it is
an operational error that names the install command. A check with no template
needs no renderer. With `--template-name`, only the templates that can be the one named
are read.

Text in code, comments and other HTML GitHub does not show is no heading. A
heading inside a list item, quote, table or alert is its section's content,
not a section of its own. A heading compares with its inline code, emphasis,
strikethrough, link destinations, images by their source, line breaks and inline HTML such as subscript, as GitHub
shows them, and a footnote reference by its label, not the number GitHub
shows. Emoji
shortcodes such as `:bug:` compare as written, not as the emoji GitHub shows,
and so does math in dollar signs, which cmark-gfm does not render, so write
them as the template does. A template heading pairs with a body
heading at the same level before one at another level, so a subsection that shares a
section's name does not stand in for it. A list item that shows nothing, or only `[ ]`, such as a
template's `-` placeholder, is not content. Reading stops at a pull request's
review note, the last `---` rule with a blank line before and after it,
followed by a plain line that opens with `Edit:` and names the head it covers in
code, such as ``Edit: `1a2b3c4` reviewed``, so the note is not content of the
last template section. For an issue, the
attribution note `create-issue` closes it with is not content either.

Issue forms and front matter are YAML, read with PyYAML's safe loader as
GitHub reads them, in any YAML style. A form that does not load, a `body`
that is not a list, or a field whose label is not text, is an operational
error, never a partial check, as is front matter that does not load once the
parser has read its root as a mapping. When the YAML parser reads a broken template's own `name`
before the error, that name keeps it from blocking a check that names another
template; a name it cannot read, or one a `<<` merge may supply, blocks every
named check.
