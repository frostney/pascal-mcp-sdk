# Skills

## Executive Summary

Skills is the official extension for publishing
[Agent Skills](https://agentskills.io/specification) through MCP
(`io.modelcontextprotocol/skills`, at the Beta stage, defined by
[SEP-2640](https://github.com/modelcontextprotocol/ext-skills/blob/ba23984ab9859c88663d1ce1d93fa81942cae5a2/specification/beta/skills.mdx)).
A skill is a `SKILL.md` with YAML frontmatter, plus any supporting
files. The server serves each file as a `skill://` resource and lists
every skill with the SHA-256 digest and size of each file. A host
that supports the extension discovers the skills from the listing,
fetches a skill's `SKILL.md` when it loads the skill and each
supporting file when it is read, and checks every file it fetches
against the listed digest and size. `MCP.Skills` gives you
the server side for skills you define in code.

## Register a skill

```pascal
uses fpjson, MCP.Server, MCP.Skills;

RegisterSkill(Server, 'git-workflow',
  TJSONObject.Create(['name', 'git-workflow',
    'description', 'Follow this team''s Git conventions for branches ' +
    'and commits']),
  '# Git workflow' + LineEnding + LineEnding +
  'Branch from main. Commit messages follow ' +
  '[the conventions](references/commits.md).' + LineEnding,
  [MCPSkillFile('references/commits.md', CommitsText),
   MCPSkillFile('assets/flow.png', FlowPng)]);
```

- The skill path, here `git-workflow`, locates the skill. Its last
  segment must equal the frontmatter `name`. Earlier segments are your
  own prefix: `acme/billing/refunds` names the skill `refunds`.
- The frontmatter object is the skill's frontmatter. It needs `name`
  (1 to 64 of `a-z`, `0-9` and single inner hyphens) and `description`
  (1 to 1024 characters). The library checks `compatibility`,
  `license`, `allowed-tools` and `metadata` against the Agent Skills
  specification, and passes every other field through.
- The body follows the frontmatter. The library writes `SKILL.md`
  itself, so the frontmatter a host reads in the file is the one in
  the listing. Strings are written double-quoted, which every YAML
  parser reads back the same. A fractional number is refused: write
  it as a string.
- Each supporting file gives a path relative to the skill root and the
  file's raw bytes, and optionally a media type. Without one, the
  library picks the type from the extension, or `text/plain` for
  other UTF-8 text and `application/octet-stream` otherwise. A file
  that is valid UTF-8 is served as text, anything else as a base64
  blob, and the digest always covers the raw bytes.

Paths use letters, digits, `-`, `.`, `_` and `~` in `/`-separated
segments. These raise `EMCPServer` at registration and leave the
server as it was:

- a path or field the specifications refuse;
- files that clash: the same URI twice, or one file under another;
- a URI that is already served;
- a skill over the limits hosts accept: 512 files or 16 MiB, counting
  its `SKILL.md` and the files of skills nested in it.

A resource you register yourself under `skill://` fails startup, since
it would hide a skill file.

## What the server serves

The first `RegisterSkill` call declares the extension with
`directoryRead`, unless you declared it first (see
[Settings](#settings)), and the `resources` capability. It then serves:

- `skills/list`: every skill's entry, its frontmatter and the
  `uri`, `digest` and `size` of each of its files, paged with
  `PageSize` and never splitting an entry.
- `skills/get`: one entry by the URI of its `SKILL.md`. Any other URI
  answers `-32602`.
- `resources/read` for every `skill://` file. The files are not in
  `resources/list`.
- `resources/directory/read`: the direct children of a directory, with
  subdirectories as `inode/directory`. A URI that is no directory
  answers `-32602`.

A skill can sit inside another, as `git-workflow/rebase` does inside
`git-workflow`. It is listed as a skill of its own, and the enclosing
skill's entry lists its files too, as the specification requires.
Classic-handshake clients get the same answers without the 2026-07-28
result fields.

To point the model at a skill, name its URI in the server's
instructions, for example `skill://git-workflow/SKILL.md`.

## Load a skills directory

Skills usually live on disk, one directory per skill.
`RegisterSkillDirectory` serves a whole tree of them:

```pascal
RegisterSkillDirectory(Server, 'skills', 'acme');
```

Each directory below `skills` that holds a `SKILL.md` is a skill, at
`skill://acme/<its path below skills>/SKILL.md`; without a prefix the
path below the root is the whole skill path. Folders without a
`SKILL.md`, such as `billing` in `skills/billing/refunds`, become part
of the path. Every file in a skill's directory is served as its exact
bytes on disk, except those of a skill nested in it, which is
registered on its own, as above. Directories are listed by directory
reads even when empty. Names starting with `.` are left out, as are
files outside any skill. A symbolic link, the root included, is
refused, since it could lead outside the tree, and so is anything but a
directory or a regular file, or a directory that cannot be read. A
skill over the limits, its nested skills' files counted, is refused
from the sizes listed, before its files are read. The tree is trusted
and must not change while it is read: each entry is checked, then
opened again by its name.

The frontmatter is read with a YAML subset on which YAML 1.1 and 1.2
parsers agree, since a host compares what it parses with the listing:

- mappings and lists in block style;
- quoted strings on one line;
- `|` and `>` block scalars, with `-` or `+`;
- plain strings, also over several lines;
- `true`, `false`, `null` and whole numbers.

A plain value the two YAML versions read differently, such as `yes`,
`on`, `1.0`, `012` or a date, must be quoted: `version: "1.0"`. So
must any plain value starting with a digit, a sign or a dot, even one
both read as text, such as `3d-printing`: telling numbers, dates and
times apart is not worth the risk. So must
a value with a colon followed by a space, or a space followed by `#`, in it. Flow collections like `[a, b]`,
anchors and tags are not read, and neither are raw tabs, control
characters, U+2028 or U+2029: write those as escapes (`\t`, `\u2028`)
in a double-quoted string. Each of these raises `EMCPServer` naming the file
and line; the checks `RegisterSkill` makes name the skill instead.
Either way no skill of the tree is registered.

## Settings

`RegisterSkill` keeps extension settings you declared first with
`DeclareExtension(MCP_SKILLS_EXTENSION, Settings)`. The Skills
extension has one setting, `directoryRead`, and the library serves
directory reads either way.

## Related pages

- [Server API reference](../reference/server.md#extensions), for
  `RegisterSkill`, `MCPSkillFile` and the extension hooks it builds on.
- [Resources](resources.md), for the resources a skill's files sit
  beside.
- [Interactive UIs (MCP Apps)](mcp-apps.md), the other extension the
  library serves.
