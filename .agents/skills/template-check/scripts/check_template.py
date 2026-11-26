#!/usr/bin/env python3
"""Compare an issue or pull request body's headings with the repository template.

Reports template headings that are missing, renamed, out of order or left
empty. Exits 0 when the headings match or no template exists, 1 on a
mismatch and 2 on an operational error.

Markdown bodies and templates are rendered locally with cmark-gfm, the engine
behind GitHub's Markdown, so a heading counts only where GitHub shows one. A heading
inside a list item, quote, table or alert is that section's content, not a
section of its own.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from html import escape
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote, unquote, urlparse

sys.dont_write_bytecode = True  # Keep installed skill trees free of __pycache__.

try:
    import cmarkgfm
    from cmarkgfm.cmark import Options
except ImportError:  # render() runs it through uv instead.
    cmarkgfm = None
try:
    import yaml
except ImportError:  # load_yaml() runs it through uv instead.
    yaml = None

# GitHub's cmark-gfm for Python, and PyYAML for issue forms and front matter,
# each pinned to a release over a year old.
CMARKGFM = "cmarkgfm==2025.10.22"
PYYAML = "pyyaml==6.0.3"
# uv settings that name a package source or a directory; the fallback clears them so
# PyPI is the only source and the temporary directory the only working directory.
UV_SOURCES = {
    "UV_INDEX", "UV_INDEX_URL", "UV_DEFAULT_INDEX", "UV_EXTRA_INDEX_URL", "UV_FIND_LINKS", "UV_NO_INDEX",
    "UV_INDEX_STRATEGY", "UV_CONFIG_FILE", "UV_KEYRING_PROVIDER", "UV_WORKING_DIR", "UV_PROJECT",
}
# Raw HTML is kept, as GitHub keeps it before filtering the tags it never shows.
RENDER = (
    "import sys, cmarkgfm\n"
    "from cmarkgfm.cmark import Options\n"
    "markdown = sys.stdin.buffer.read().decode('utf-8')\n"
    "html = cmarkgfm.github_flavored_markdown_to_html(markdown, "
    "options=Options.CMARK_OPT_UNSAFE | Options.CMARK_OPT_FOOTNOTES | Options.CMARK_OPT_SOURCEPOS | Options.CMARK_OPT_HARDBREAKS)\n"
    "sys.stdout.buffer.write(html.encode('utf-8'))"
)
# The YAML reader run through uv: this script's own read_yaml(), with PyYAML installed there.
LOAD = (
    "import importlib.util, json, sys\n"
    "spec = importlib.util.spec_from_file_location('check_template', sys.argv[1])\n"
    "module = importlib.util.module_from_spec(spec)\n"
    "sys.modules[spec.name] = module\n"
    "spec.loader.exec_module(module)\n"
    "result = module.read_yaml(sys.stdin.buffer.read().decode('utf-8'))\n"
    "sys.stdout.buffer.write(json.dumps(result).encode('utf-8'))"
)


HEADING_TAG = re.compile(r"h([1-6])")
# Whitespace HTML collapses in prose; a nonbreaking space shows as it is.
COLLAPSIBLE = re.compile(r"[ \t\n\r\f]+")
CODE_SPACE = "\x00"  # A space inside inline code, which no rendered text contains.
# An explicit <br>, which shows a new line where a newline in the text shows a space.
BREAK = "\u2028"
# Block elements that only group what they hold, so a review note may sit inside one.
WRAPPERS = {"div", "section", "article", "main", "header", "footer", "aside", "nav", "details"}
# Elements whose headings are their section's content rather than sections.
NESTING = {"li", "blockquote", "table", "pre", "code", "summary"}
# A <picture> shows only the image inside it, so it is no media of its own.
MEDIA = {"img", "video", "audio"}
# An embed GitHub removes; cmark-gfm's tag filter already escapes <script>,
# <iframe> and the like into text, as GitHub's does.
STRIPPED = {"embed"}
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
# Opening one of these closes an open paragraph, as HTML does.
CLOSES_PARAGRAPH = {
    "address", "article", "aside", "blockquote", "details", "div", "dl", "fieldset", "figure", "footer",
    "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre", "section",
    "table", "ul",
}
# The attribution note `create-issue` ends every issue with, as rendered text.
ATTRIBUTION = re.compile(r"Created on behalf of @[\w-]+ using (?:(?!\.\s).)+\.")
# A renamed heading still resembles the template's wording this closely.
RENAME_SIMILARITY = 0.6
# GitHub looks for pull request templates in these directories, and for
# several issue templates in `.github/ISSUE_TEMPLATE/`.
TEMPLATE_DIRS = ("", "docs", ".github")


class CheckError(Exception):
    """An input or GitHub problem that prevents the comparison."""

    path = ""  # The template file the problem is in, when there is one.
    name = ""  # That template's declared name, when it was read.


EMAIL_AT = re.compile(r"(`+).*?(?<!`)\1(?!`)|\]\(<(?:\\.|[^>\\])*>\)|(?<=[\w.+-])@(?=[\w-]+\.[\w-])")


@dataclass
class Heading:
    level: int
    text: str
    line: int | None = None  # A form field's line; rendered Markdown has none.
    has_content: bool = False
    # The heading as written in Markdown, so a reported heading can be pasted as it is.
    written: str = ""
    # Whether it shows a link or footnote whose definition is elsewhere in its document.
    defined_elsewhere: bool = False
    html: str = ""  # Its rendered content, which shows as it is wherever it is pasted.

    def __str__(self) -> str:
        if self.written:
            return self.written
        # Outside code and link destinations, an email address would become a link
        # where this is pasted; no escape stops that, but a tag around its `@` does.
        shown = EMAIL_AT.sub(lambda match: "<span>@</span>" if match.group(0) == "@" else match.group(0), self.text)
        return f"{'#' * self.level} {shown}"


@dataclass
class Template:
    path: str
    name: str
    headings: list[Heading] = field(default_factory=list)


@dataclass
class Node:
    tag: str
    attrs: dict[str, str]
    children: list[Node | str] = field(default_factory=list)


class TreeBuilder(HTMLParser):
    """A tree of GitHub's rendered HTML; comments, which it never renders, are dropped."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = Node("root", {})
        self.stack = [self.root]
        self.joins = False  # Whether text continues the text before it, as across a dropped comment.

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.joins = False
        if tag == "br":
            self.stack[-1].children.append(BREAK)  # A line break separates words and lines.
            return
        if tag in CLOSES_PARAGRAPH and self.stack[-1].tag == "p":
            self.stack.pop()
        if tag == "li":
            # A new item closes the open item of its own list, whose end tag HTML lets an author omit.
            lists = [index for index, node in enumerate(self.stack) if node.tag in ("li", "ul", "ol")]
            if lists and self.stack[lists[-1]].tag == "li":
                del self.stack[lists[-1] :]
        if tag in STRIPPED:
            return
        node = Node(tag, {key: value or "" for key, value in attrs})
        self.stack[-1].children.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        self.joins = False
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        children = self.stack[-1].children
        if self.joins and children and isinstance(children[-1], str):
            children[-1] += data
        else:
            children.append(data)
        self.joins = True


def inner_html(node: Node) -> str:
    """A node's content as HTML, without the renderer's source positions."""

    def write(child: Node | str) -> str:
        if isinstance(child, str):
            return escape(child, quote=False).replace(BREAK, "<br>")
        attrs = "".join(f' {key}="{escape(value)}"' for key, value in child.attrs.items() if key != "data-sourcepos")
        return f"<{child.tag}{attrs}>" if child.tag in VOID else f"<{child.tag}{attrs}>{inner_html(child)}</{child.tag}>"

    return "".join(write(child) for child in node.children)


def text_of(node: Node | str) -> str:
    if isinstance(node, str):
        return node
    if node.tag == "img":
        return node.attrs.get("alt", "")  # A badge or image reads as its label.
    return "".join(text_of(child) for child in node.children)


# Inline formatting a reader sees, written back as Markdown in heading text.
INLINE_MARKERS = {"em": "*", "i": "*", "strong": "**", "b": "**", "del": "~~", "s": "~~", "strike": "~~"}
# Inline HTML GitHub shows apart from plain text, written back as tags.
INLINE_TAGS = {"sub", "sup", "kbd", "mark", "ins", "u", "small", "abbr", "picture"}


def renderer_link(node: Node) -> bool:
    """A link GitHub adds, not the author: a heading anchor, or one to the image it wraps."""
    if "anchor" in node.attrs.get("class", "").split() and not text_of(node).strip():
        return True  # GitHub's anchor shows only an icon; an author's link shows text.
    children = elements(node.children)
    sources = {child.attrs.get(key) for child in children for key in ("src", "data-canonical-src")}
    own_text = "".join(child for child in node.children if isinstance(child, str)).strip()
    only_images = bool(children) and all(child.tag == "img" for child in children)
    # GitHub opens the image it wraps in a new tab; the local renderer adds no wrapper.
    generated = node.attrs.get("target") == "_blank"
    return generated and only_images and not own_text and node.attrs.get("href") in sources


def utf8(match: re.Match[str]) -> str:
    """Percent escapes decoded as UTF-8, or kept as written when they are not valid UTF-8."""
    try:
        return unquote(match.group(0), errors="strict")
    except UnicodeDecodeError:
        return match.group(0)


def footnote_label(href: str) -> str:
    """A footnote's own label from its reference's target: `#fn-ref` locally, `#user-content-fn-ref-<hash>` on GitHub."""
    label = re.sub(r"^#(?:user-content-)?fn-", "", href)
    if href.startswith("#user-content-"):
        label = re.sub(r"-[0-9a-f]{32}$", "", label)
    # The target carries the definition's spelling, percent-encoded; a reference matches it in any case.
    # Only escapes of UTF-8 bytes are decoded, so a label written with `%41` stays apart from `A`.
    return re.sub(r"(?:%[89A-Fa-f][0-9A-Fa-f])+", utf8, label).casefold()


def literal(text: str) -> str:
    """Text with each character Markdown could read as markup escaped, so it reads back as written."""
    # `!` too, so a literal one before a link never reads as an image.
    text = re.sub(r"([\\`*_~<\[\]&!])", r"\\\1", text).replace(BREAK, "<br>")
    # A plain-text URL would become a link where it is written back.
    return re.sub(r"(?i)\b(?:https?|ftp)(?=://)|\bwww(?=\.)", lambda match: match.group(0) + "\\", text)


def destination(url: str) -> str:
    """A link or image destination written so it reads back as the same URL.

    In angle brackets, so no text after it can read as part of it; an
    ampersand as an entity, since an entity-shaped destination would
    otherwise decode; whitespace encoded, since it is part of the URL and
    must survive the heading's whitespace folding.
    """
    written = re.sub(r"([\\<>])", r"\\\1", url).replace("&", "&amp;")
    return re.sub(r"\s", lambda match: quote(match.group(0)), written)


def flattened(children: list[Node | str]) -> list[Node | str]:
    """Children with plain wrappers such as <span> replaced by what they hold, as they show."""
    shown: list[Node | str] = []
    for child in children:
        for item in flattened(child.children) if isinstance(child, Node) and child.tag in ("span", "font") else [child]:
            if isinstance(item, str) and shown and isinstance(shown[-1], str):
                shown[-1] += item  # Text the wrapper split reads as one run, as it shows.
            else:
                shown.append(item)
    return shown


def heading_text(node: Node | str, github: bool = True) -> str:
    """A heading's words, with its inline code in backticks.

    GitHub turns `:warning:` into an emoji in text but not in code, so a
    heading with the shortcode in code differs from one without, and a
    struck-out or emphasized word differs from plain text. A literal marker
    character reads escaped, as it is written, so it never passes for one.
    Inline code is written between backticks longer than any run inside it,
    so a reported heading can be pasted back as it is.
    """
    if isinstance(node, str):
        return literal(node)
    if node.tag == "source":
        # A <picture> source shows its image where its media condition holds, as in dark mode.
        attrs = "".join(f' {key}="{escape(node.attrs[key])}"' for key in ("media", "srcset", "type") if key in node.attrs)
        return f"<source{attrs}>"
    if node.tag == "img":
        # An image shows its picture, so its source is part of the heading; GitHub
        # proxies the source and keeps the original as data-canonical-src.
        source = (github and node.attrs.get("data-canonical-src")) or node.attrs.get("src", "")
        return f"![{literal(node.attrs.get('alt', ''))}](<{destination(source)}>)"
    references = elements(node.children)
    if node.tag == "sup" and references and all("data-footnote-ref" in child.attrs for child in references):
        # A footnote reference shows a number that depends on the footnotes before it; compare its label.
        return "".join(f"[^{footnote_label(child.attrs.get('href', ''))}]" for child in references)
    if node.tag == "code":
        code = text_of(node)
        fence = "`" * (max((len(run) for run in re.findall(r"`+", code)), default=0) + 1)
        padded = code[:1] == "`" or code[-1:] == "`" or (code[:1] == code[-1:] == " " and code.strip())
        # Whitespace in code is literal; CODE_SPACE keeps each character through the heading's folding.
        code = re.sub(r"\s", lambda match: f"{CODE_SPACE}{ord(match.group(0)):x}{CODE_SPACE}", code)
        return f"{fence} {code} {fence}" if padded else f"{fence}{code}{fence}"
    children = flattened(node.children)
    parts = [heading_text(child, github=github) for child in children]
    for index in range(len(parts) - 1):
        if parts[index].endswith("*") and parts[index + 1].startswith("*"):
            # Two runs of `*` side by side would merge; write one with `_` instead.
            for side in (index, index + 1):
                child = children[side]
                width = len(INLINE_MARKERS.get(child.tag, "")) if isinstance(child, Node) else 0
                if width and parts[side].startswith("*" * width):
                    parts[side] = "_" * width + parts[side][width:-width] + "_" * width
                    break
    inner = "".join(parts)
    # An empty destination is still a link, to the page itself.
    # Only GitHub's HTML has links it added itself; the local renderer adds none.
    if node.tag == "a" and "href" in node.attrs and not (github and renderer_link(node)):
        return f"[{inner}](<{destination(node.attrs['href'])}>)"
    if node.tag in INLINE_TAGS:
        return f"<{node.tag}>{inner}</{node.tag}>"
    marker = INLINE_MARKERS.get(node.tag, "")
    if not marker:
        return inner
    # Spaces just inside emphasis show as plain spaces beside it, so they sit outside its markers.
    body = inner.strip(" \t\n\r\f")
    before = inner[: len(inner) - len(inner.lstrip(" \t\n\r\f"))]
    after = inner[len(inner.rstrip(" \t\n\r\f")) :]
    return before + wrap(marker, body) + after


def wrap(marker: str, inner: str) -> str:
    """Inline text inside an emphasis marker, switched to `_` beside a `*` it would merge with."""
    if marker.startswith("*") and (inner.startswith("*") or inner.endswith("*")):
        # Around emphasis written with `*`, so `*_x_*` and `**x**` stay apart and read back as written.
        marker = marker.replace("*", "_")
    return f"{marker}{inner}{marker}"


def words(node: Node | str) -> str:
    return " ".join(text_of(node).split())


def elements(nodes: list[Node | str]) -> list[Node]:
    return [node for node in nodes if isinstance(node, Node)]


def contains(node: Node, tag: str) -> bool:
    return any(child.tag == tag or contains(child, tag) for child in elements(node.children))


def has_media(node: Node) -> bool:
    return any(child.tag in MEDIA or has_media(child) for child in elements(node.children))


def plain(node: Node) -> bool:
    """Whether a node shows only text, in paragraphs at most, with no formatting such as code.

    An element that shows nothing, such as an empty code block, is ignored.
    """
    return all(
        (child.tag in WRAPPERS | {"p", "span"} and plain(child)) or (not text_of(child).strip() and not has_media(child) and child.tag not in MEDIA)
        for child in elements(node.children)
    )


def apart(item: Node) -> tuple[Node, list[Node]]:
    """A list item's own content, and the lists and quotes nested in it, also inside plain wrappers."""
    nested: list[Node] = []

    def own(node: Node) -> Node:
        kept: list[Node | str] = []
        for child in node.children:
            if isinstance(child, Node) and child.tag in ("ul", "ol", "blockquote"):
                nested.append(child)
            elif isinstance(child, Node) and child.tag in WRAPPERS | {"p", "span"}:
                kept.append(own(child))
            else:
                kept.append(child)
        return Node(node.tag, node.attrs, kept)

    return own(item), nested


def is_alert(node: Node, github: bool = True) -> bool:
    """A GitHub alert; cmark-gfm leaves alerts as quotes, so locally a div with the class is the author's."""
    return github and node.tag == "div" and "markdown-alert" in node.attrs.get("class", "").split()


def names_head(paragraph: Node) -> bool:
    """Whether a paragraph's first line opens with a plain `Edit:` and names a commit in code."""
    opening = paragraph.children[0] if paragraph.children else None
    if not isinstance(opening, str) or not opening.lstrip().startswith("Edit:"):
        return False

    def first_line(node: Node) -> bool | None:
        """True once a commit in code is found, False at the first line break."""
        for child in node.children:
            if isinstance(child, str):
                if "\n" in child or BREAK in child:
                    return False
            elif child.tag == "code":
                if re.fullmatch(r"[0-9a-fA-F]{4,40}", words(child)):
                    return True
            else:
                found = first_line(child)
                if found is not None:
                    return found
        return None

    return bool(first_line(paragraph))


def is_footnotes(node: Node) -> bool:
    """The footnotes section GitHub appends, with its generated heading."""
    return node.tag == "section" and "data-footnotes" in node.attrs


def is_checked(node: Node) -> bool:
    """A checked task-list box; a hidden or other input shows no answer."""
    return node.tag == "input" and node.attrs.get("type") == "checkbox" and "checked" in node.attrs


def has_checked(node: Node) -> bool:
    return any(is_checked(child) or has_checked(child) for child in elements(node.children))


# The review note's rule in the source: `---` with a blank line before and after.
NOTE_SOURCE = re.compile(r"(?:\A|\n)[ \t]*\n[ \t]{0,3}-{3,}[ \t]*\n[ \t]*\n[ \t]{0,3}Edit:")


def source_line(node: Node) -> int | None:
    """The source line the renderer marked a block with, if the mark is its own.

    Raw HTML keeps any `data-sourcepos` an author wrote, so only a well-formed
    mark is read; the caller checks the line it names.
    """
    position = re.fullmatch(r"([1-9][0-9]*):[0-9]+-[0-9]+:[0-9]+", node.attrs.get("data-sourcepos", ""))
    return int(position.group(1)) if position else None


def written_heading(lines: list[str], node: Node, level: int) -> str:
    """A rendered heading's own Markdown, as one ATX line, or "" when its source is not a Markdown heading."""
    span = re.fullmatch(r"([1-9][0-9]*):[0-9]+-([1-9][0-9]*):[0-9]+", node.attrs.get("data-sourcepos", ""))
    if not span or not int(span.group(1)) <= int(span.group(2)) <= len(lines):
        return ""
    block = lines[int(span.group(1)) - 1 : int(span.group(2))]
    atx = re.fullmatch(r" {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*", block[0])
    if len(block) == 1 and atx and len(atx.group(1)) == level:
        content = atx.group(2) or ""
        content = "" if re.fullmatch(r"#+", content) else content
    elif len(block) > 1 and re.fullmatch(r" {0,3}(=+|-+)[ \t]*", block[-1]) and block[-1].strip()[0] == "=-"[level - 1]:
        # A setext heading's text lines; GitHub shows each line break in an issue or pull request as one.
        content = "<br>".join(re.sub(r"(?<!\\)((?:\\\\)*)\\$", r"\1", line.strip()) for line in block[:-1])
        # As an ATX heading, a closing run of `#` would end it early; escape it.
        content = re.sub(r"(^|[ \t])(#+)$", r"\1\\\2", content)
    else:
        return ""
    return f"{'#' * level} {content}".rstrip()


def standalone(found: list[Heading], renderer: Callable[[str], str], source: str = "") -> list[Heading]:
    """Report each heading in a form that shows the same heading where it is pasted.

    Tried in turn: as written in the source, as compared, then as HTML, which
    shows as it is. A reference link or footnote resolves through a
    definition elsewhere in its document, so pasted alone it reads
    differently; such a heading is reported as written, with a note to copy
    that definition too.
    """

    def failing(candidates: list[tuple[Heading, str]]) -> list[Heading]:
        """The headings whose form shows a different heading on its own."""
        if not candidates:
            return []
        alone = headings(renderer("\n\n".join(form for _, form in candidates)), github=False)
        if len(alone) != len(candidates):  # A form that is not one heading: try each alone.
            alone = [(headings(renderer(form), github=False) or [Heading(0, "")])[0] for _, form in candidates]
        return [heading for (heading, _), shown in zip(candidates, alone) if (shown.level, shown.text) != (heading.level, heading.text)]

    broken = failing([(heading, heading.written) for heading in found if heading.written])
    if broken:
        # Followed by their own document, which holds every link and footnote definition.
        shown = headings(renderer("\n\n".join([*(heading.written for heading in broken), source])), github=False)
        for index, heading in enumerate(broken):
            if index < len(shown) and (shown[index].level, shown[index].text) == (heading.level, heading.text):
                heading.defined_elsewhere = True
            else:
                heading.written = ""
    for heading in failing([(heading, str(heading)) for heading in found if not heading.written]):
        heading.written = f"<h{heading.level}>{heading.html}</h{heading.level}>"
    return found


def spaced_rule(rule: Node, note: Node, source: str | None, positioned: bool = False) -> bool:
    """Whether a rendered rule is a `---` line with a blank line before and after it, then the note.

    The local renderer marks each block with its source line; HTML without
    those marks, such as GitHub's, is checked against the source as a whole.
    """
    if source is None:
        return True
    source = source.replace("\r\n", "\n")
    if not positioned:
        # HTML with no positions at all, such as GitHub's, is checked against the source.
        return bool(NOTE_SOURCE.search(source))
    lines = source.split("\n")
    line, note_line = source_line(rule), source_line(note)
    # A raw <hr>, or one whose mark names another line, is no separator.
    if line is None or note_line is None or not line < note_line <= len(lines):
        return False
    before = lines[line - 2] if line >= 2 else ""
    between = lines[line : note_line - 1]
    return (
        bool(re.fullmatch(r" {0,3}-{3,}[ \t]*", lines[line - 1]))
        and not before.strip()
        and bool(between)
        and not any(entry.strip() for entry in between)
        and lines[note_line - 1].lstrip().startswith("Edit:")
    )


class EndOfBody(Exception):
    """Reading reached the review note, where the body ends."""


def note_rule(children: list[Node | str], valid: Callable[[Node, Node], bool], github: bool = True) -> Node | None:
    """The rule that opens the last review note, also inside wrapper elements."""
    found = None
    blocks = elements(children)
    for index, block in enumerate(blocks):
        following = blocks[index + 1] if index + 1 < len(blocks) else None
        if block.tag == "hr" and following is not None and following.tag == "p" and names_head(following) and valid(block, following):
            found = block
        elif block.tag in WRAPPERS and not is_alert(block, github) and not is_footnotes(block):
            found = note_rule(block.children, valid, github) or found  # Later in the document than any before it.
    return found


def headings(html: str, kind: str | None = None, source: str | None = None, github: bool | None = None) -> list[Heading]:
    """Headings of rendered HTML, each with whether its section shows anything.

    A section runs to the next heading of the same or a higher level. A list
    item that shows nothing, or only `[ ]`, is a template placeholder, not
    content. For a pull request, reading stops at a review note: a rule
    followed by a paragraph that opens with `Edit:`. For an issue, the
    attribution note that closes it is not content.
    """
    builder = TreeBuilder()
    builder.feed(html)
    builder.close()
    # GitHub appends footnotes after the last section; they are no section's content.
    top = [node for node in builder.root.children if not (isinstance(node, Node) and is_footnotes(node))]
    blocks = elements(top)
    # The local renderer marks every block with its source position; GitHub's HTML has none.
    positioned = "data-sourcepos" in html
    # Whether GitHub rendered this HTML, which only then holds links GitHub added
    # itself; a caller that rendered it says so, since raw HTML carries no positions.
    github = not positioned if github is None else github
    end = None
    if kind == "pr":
        # The review note closes the body: a `---` rule with a blank line
        # before and after it, then a line that opens with `Edit:` and names
        # the head it covers in code, such as ``Edit: `1a2b3c4` reviewed``.
        end = note_rule(top, lambda rule, note: spaced_rule(rule, note, source, positioned), github)
    # A rule or an empty element after the attribution shows nothing, so it does not hide it.
    shown = [block for block in blocks if block.tag != "hr" and (words(block) or has_media(block) or has_checked(block))]
    if kind == "issue" and shown:
        last, holder = shown[-1], builder.root
        # Through plain wrappers to the last block that shows anything.
        while last.tag in WRAPPERS and not is_alert(last, github):
            inner = [block for block in elements(last.children) if block.tag != "hr" and (words(block) or has_media(block) or has_checked(block))]
            if not inner:
                break
            last, holder = inner[-1], last
        paragraphs = [node for node in elements(last.children) if "markdown-alert-title" not in node.attrs.get("class", "")]
        lines = [line.strip() for line in text_of(paragraphs[0]).splitlines() if line.strip()] if len(paragraphs) == 1 else []
        opening = paragraphs[0].children[0] if len(paragraphs) == 1 and paragraphs[0].children else None
        if last.tag == "blockquote" and isinstance(opening, str) and opening.strip().split("\n")[0] == "[!NOTE]":
            lines = lines[1:]  # cmark-gfm leaves the alert a quote that opens with its marker.
        elif not (github and "markdown-alert-note" in last.attrs.get("class", "").split()):
            lines = []
        loose_text = any(isinstance(child, str) and child.strip() for child in last.children)
        # The note is plain prose; one quoting the sentence in code is an example of it.
        loose_text = loose_text or any(contains(paragraph, "code") for paragraph in paragraphs)
        if len(lines) == 1 and ATTRIBUTION.fullmatch(" ".join(lines[0].split())) and not has_media(last) and not loose_text:
            holder.children = [node for node in holder.children if node is not last]
            top = [node for node in top if node is not last]

    found: list[Heading] = []
    open_sections: list[Heading] = []
    source_lines = source.replace("\r\n", "\n").split("\n") if source is not None else []

    def content() -> None:
        for section in open_sections:
            section.has_content = True

    def visit(children: list[Node | str], nested: bool) -> None:
        for child in children:
            if child is end:
                raise EndOfBody
            if isinstance(child, str):
                if child.strip():
                    content()
                continue
            level = HEADING_TAG.fullmatch(child.tag)
            if level and not nested:
                line = source_line(child)
                written = written_heading(source_lines, child, int(level.group(1))) if source is not None else ""
                # A newline beside an explicit break, as after a setext hard break, shows nothing more.
                # Text writes a break as `<br>`; a literal one is escaped, so this is only a break.
                text = re.sub(r"[ \t\n\r\f]*(?<!\\)<br>[ \t\n\r\f]*", "<br>", heading_text(child, github=github))
                text = COLLAPSIBLE.sub(" ", text).strip(" ")
                text = re.sub(f"{CODE_SPACE}([0-9a-f]+){CODE_SPACE}", lambda match: chr(int(match.group(1), 16)), text)
                # A closing run of `#` would end the heading where it is written back.
                text = re.sub(r"(^|\s)(#+)$", r"\1\\\2", text)
                heading = Heading(int(level.group(1)), text, line, written=written, html=inner_html(child))
                while open_sections and open_sections[-1].level >= heading.level:
                    open_sections.pop()
                content()  # A subsection is content of the sections around it.
                found.append(heading)
                open_sections.append(heading)
                continue
            if child.tag == "li":
                # Nested lists and quotes, also inside plain wrappers, are read on their own,
                # apart from the item's own text.
                own, lists = apart(child)
                placeholder = not words(own) or (words(own) == "[ ]" and plain(own))
                if placeholder and not has_media(own) and not has_checked(own):
                    visit(lists, True)
                    continue
            if child.tag in MEDIA or is_checked(child):
                content()
            visit(child.children, nested or child.tag in NESTING or is_alert(child, github))

    try:
        visit(top, False)
    except EndOfBody:
        pass
    return found


def lines_of(text: str) -> str:
    """Text with every line ending as `\\n`; cmark-gfm also ends a line at a bare `\\r`,
    so its source positions count lines as this does."""
    return text.replace("\r\n", "\n").replace("\r", "\n")


def render(markdown: str) -> str:
    """Markdown as GitHub renders it in an issue or pull request, rendered locally.

    As there, each line break in the text shows as one.

    cmark-gfm renders raw HTML here, as GitHub does before it filters the
    tags it never shows; alerts stay quotes that open with their marker.
    """
    if not markdown.strip():
        return ""
    if cmarkgfm is not None:
        return cmarkgfm.github_flavored_markdown_to_html(
            markdown,
            options=Options.CMARK_OPT_UNSAFE | Options.CMARK_OPT_FOOTNOTES | Options.CMARK_OPT_SOURCEPOS | Options.CMARK_OPT_HARDBREAKS,
        )
    return isolated(RENDER, markdown, CMARKGFM, "the Markdown renderer")


def isolated(program: str, text: str, package: str, what: str, *args: str) -> str:
    """A pinned package's program run through uv on text, for a package that is not installed."""
    uv = shutil.which("uv")
    if not uv:
        raise CheckError(f"{what} is not installed: pip install {package}")
    # Outside the checkout, with uv's configuration files ignored and PyPI named,
    # so no checkout can choose where the package comes from; Python runs
    # isolated (-I), so no file in that directory can stand in for it.
    command = [
        uv, "run", "--quiet", "--no-config", "--no-project", "--isolated",
        "--default-index", "https://pypi.org/simple", "--python", sys.executable,
        "--with", package, "python", "-I", "-c", program, *args,
    ]
    # Index settings inherited from the environment could still add or prefer another source.
    environment = {key: value for key, value in os.environ.items() if key not in UV_SOURCES}
    try:
        completed = subprocess.run(
            command, input=text, cwd=tempfile.gettempdir(), env=environment, text=True, encoding="utf-8",
            capture_output=True, timeout=300, check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise CheckError(f"{what} did not start through uv within 300s") from error
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()[-500:]
        raise CheckError(f"cannot run {what} through uv ({detail}); pip install {package}")
    return completed.stdout


# Values and characters a template's YAML may stand for; aliases and merges can repeat data exponentially.
YAML_SIZE = 1_000_000


def expanded(node: Any, sizes: dict[int, int], active: set[int]) -> int:
    """How many values and characters a composed YAML node stands for once its aliases are copied out.

    Counted on the node graph before anything is built or written out, so
    neither an alias that repeats nested aliases or long text nor a merge can
    use memory past YAML_SIZE; ValueError past it, or for an alias inside its
    own anchor.
    """
    key = id(node)
    if key in sizes:
        return sizes[key]
    if key in active:
        raise ValueError("a YAML alias refers to itself")
    active.add(key)
    parts = (
        [part for item in node.value for part in (item if isinstance(item, tuple) else (item,))]
        if isinstance(node.value, list)
        else []
    )
    own = 1 + (len(node.value) if isinstance(node.value, str) else 0)
    total = own + sum(expanded(part, sizes, active) for part in parts)
    active.discard(key)
    if total > YAML_SIZE:
        raise ValueError(f"the YAML expands to more than {YAML_SIZE} values and characters")
    sizes[key] = total
    return total


def jsonable(value: Any) -> Any:
    """A loaded YAML value as plain data: mappings with string keys, lists and scalars."""
    if isinstance(value, dict):
        return {str(key): jsonable(item) for key, item in value.items()}
    if isinstance(value, list):
        return [jsonable(item) for item in value]
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    return {"!": type(value).__name__}  # A date or another YAML type, which is no text where text belongs.


def read_yaml(text: str) -> dict[str, Any]:
    """PyYAML's safe reading of text: {"value": plain data}, or {"error": why, "mapping": ..., "name": ...}.

    The error's mapping and name are root_reading()'s. Plain JSON either way,
    so the uv fallback in load_yaml() returns the same.
    """
    try:
        loader = yaml.SafeLoader(text)  # A character YAML does not allow raises here.
    except yaml.YAMLError as error:
        return {"error": str(error), **root_reading(text)}
    try:
        node = loader.get_single_node()
        if node is not None:
            expanded(node, {}, set())
        return {"value": jsonable(None if node is None else loader.construct_document(node))}
    # An escape past the last code point raises ValueError or OverflowError; deep nesting, RecursionError.
    except (yaml.YAMLError, ValueError, OverflowError, RecursionError) as error:
        return {"error": str(error), **root_reading(text)}
    finally:
        loader.dispose()


STR = "tag:yaml.org,2002:str"


def root_reading(text: str) -> dict[str, Any]:
    """What PyYAML's parser reads of YAML that does not load, up to where it stops.

    "mapping": whether the root is a mapping. "name": its own `name` entry,
    with quotes, comments, flow style, explicit keys and aliases read as YAML
    reads them. A name counts once the parser reads on past it, since a value
    the error follows may be cut short, such as an unclosed quote that ran on.
    "" when the mapping ends without a name; None when the name is not text,
    is given twice, may come from a `<<` merge, or is not read before the error.
    """
    cut: int | None = None
    try:
        yaml.SafeLoader(text).dispose()
    except yaml.reader.ReaderError as error:
        cut = error.position  # The entries before a character YAML does not allow still read.
    resolver = yaml.resolver.Resolver()

    def tag(event: Any) -> str:
        if event.tag is None or event.tag == "!":
            return resolver.resolve(yaml.ScalarNode, event.value, event.implicit)
        return event.tag

    texts: dict[str, str] = {}  # Anchored text, which an alias repeats.
    names: list[str | None] = []
    mapping, depth, entries, naming, read, twice, merged = False, 0, 0, False, [], False, False
    try:
        for event in yaml.parse(text[:cut], Loader=yaml.SafeLoader):
            if cut is None or event.start_mark.index < cut:
                names += read  # The parser read on past the name, before any cut.
            read = []
            if isinstance(event, (yaml.StreamStartEvent, yaml.DocumentStartEvent)):
                continue
            if depth == 0 and not isinstance(event, yaml.MappingStartEvent):
                break  # No root mapping, so no name.
            value: str | None = None
            if isinstance(event, yaml.ScalarEvent) and tag(event) == STR:
                value = event.value
                if event.anchor:
                    texts[event.anchor] = value
            elif isinstance(event, yaml.AliasEvent):
                value = texts.get(event.anchor)
            if isinstance(event, (yaml.MappingStartEvent, yaml.SequenceStartEvent)):
                mapping = mapping or depth == 0
                if depth == 1 and entries % 2 == 0:
                    naming = False  # A key that is a collection is not `name`.
                elif depth == 1 and naming:
                    read = [None]  # A name that is a collection is not text.
                    naming = False
                depth += 1
                continue
            if isinstance(event, (yaml.MappingEndEvent, yaml.SequenceEndEvent)):
                depth -= 1
                if depth == 0 and cut is not None and event.start_mark.index >= cut:
                    break  # The cut, not the mapping, ends here.
                if depth == 0:
                    complete = not (twice or (merged and not names))
                    return {"mapping": mapping, "name": (names or [""])[0] if complete else None}
                entries += depth == 1
                continue
            if depth == 1:  # A scalar or alias entry of the root mapping.
                if entries % 2 == 0:
                    naming = value == "name"
                    twice = twice or (naming and bool(names))  # A second name, whatever its value, leaves it open.
                    merged = merged or (isinstance(event, yaml.ScalarEvent) and tag(event) == "tag:yaml.org,2002:merge")
                elif naming:
                    null = isinstance(event, yaml.ScalarEvent) and tag(event) == "tag:yaml.org,2002:null"
                    read = ["" if null else value]
                    naming = False
                entries += 1
    except (yaml.YAMLError, ValueError, OverflowError, RecursionError):
        pass
    if not mapping:
        return {"mapping": False, "name": ""}
    return {"mapping": True, "name": None if twice or not names else names[0]}  # An explicit name wins over a merge.


def load_yaml(text: str) -> Any:
    """YAML read with PyYAML's safe loader, locally or through uv; BrokenYaml for text that is not YAML."""
    if yaml is not None:
        result = read_yaml(text)
    else:
        result = json.loads(isolated(LOAD, text, PYYAML, "the YAML reader", str(Path(__file__).resolve())))
    if "error" in result:
        raise BrokenYaml(f"not valid YAML: {result['error']}", result["name"], result["mapping"])
    return result["value"]


class BrokenYaml(ValueError):
    """YAML that does not load, with what its parser still read: see root_reading()."""

    def __init__(self, message: str, name: str | None, mapping: bool) -> None:
        super().__init__(message)
        self.name = name
        self.mapping = mapping


def name_in(data: Any) -> str | None:
    """The `name` a template's YAML declares: "" when it declares none, None when it is not text."""
    if not isinstance(data, dict) or data.get("name") is None:
        return ""
    return data["name"] if isinstance(data["name"], str) else None


def front_matter(text: str) -> tuple[dict[str, Any], str]:
    """Split a Markdown template's YAML front matter from its body.

    Front matter opens with a `---` line and closes at the next `---` line at
    the margin, so an indented `---` inside a YAML block is its text; what it
    holds must be a YAML mapping, so an opening `---` rule over Markdown stays
    part of the body.
    """
    lines = lines_of(text).split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, text
    for index, line in enumerate(lines[1:], start=1):
        if re.fullmatch(r"---[ \t]*", line):
            block = "\n".join(lines[1:index])
            try:
                data = load_yaml(block)
            except BrokenYaml as error:
                # Markdown between two rules is often not YAML; a block whose root
                # PyYAML reads as a mapping, such as one opening with `name:`, was meant
                # to be. `![` opens a Markdown image: no YAML tag holds a `[`.
                opening = next((line for line in block.split("\n") if line.strip() and not line.lstrip().startswith("#")), "")
                if error.mapping and not opening.lstrip().startswith("!["):
                    raise BrokenYaml(f"cannot read the front matter: {error}", error.name, True) from error
                return {}, text
            if isinstance(data, dict):
                return data, "\n".join(lines[index + 1 :])
            return {}, text
    return {}, text


def declared_name(text: str) -> str | None:
    """A form's top-level `name`: "" when it declares none, None when it cannot be read."""
    try:
        return name_in(load_yaml(text))
    except BrokenYaml as error:
        return error.name


def form_template(path: str, text: str, need_name: bool = True) -> Template:
    """Headings of a GitHub issue form: one `###` per field that is not Markdown.

    GitHub renders each answered or empty field as `### <label>` followed by
    the answer or `_No response_`. The form is read with PyYAML's safe
    loader; a form it cannot read, or a field without a text label, is an
    error, so a body is never checked against part of a form.
    """

    def failure(message: str, name: str = "") -> CheckError:
        error = CheckError(f"{path}: {message}; pass --template PATH")
        error.name = name
        return error

    try:
        data = load_yaml(text)
    except BrokenYaml as error:
        # Its name, read on its own, keeps the error from blocking a check that names another template.
        raise failure(f"cannot read the issue form: {error}", error.name or "") from error
    if not isinstance(data, dict):
        raise failure("the issue form is not a YAML mapping")
    declared = name_in(data)
    if declared is None and need_name:
        # A name the form declares but that is not text: it may be any template's.
        raise failure("cannot read the issue form's name")
    name = declared or Path(path).stem
    body = data.get("body", [])
    if not isinstance(body, list):
        raise failure("the issue form's body is not a list of fields", name)
    found: list[Heading] = []
    for number, item in enumerate(body, start=1):
        if not isinstance(item, dict) or not isinstance(item.get("type"), str):
            raise failure(f"cannot read the type of field {number}", name)
        if item["type"] == "markdown":
            continue
        attributes = item.get("attributes")
        label = attributes.get("label") if isinstance(attributes, dict) else None
        if not isinstance(label, str) or not label.strip():
            raise failure(f"cannot read the label of field {number}", name)
        # Rendered later as a heading, which folds whitespace outside inline code itself.
        found.append(Heading(3, re.sub(r"[\r\n]+", " ", label).strip()))
    return Template(path, name, found)


def markdown_template(path: str, text: str, renderer: Callable[[str], str], need_name: bool = True) -> Template:
    try:
        fields, body = front_matter(text)
    except BrokenYaml as error:
        failure = CheckError(f"{path}: {error}; pass --template PATH")
        failure.name = error.name or ""
        raise failure from error
    declared = name_in(fields)
    if declared is None and need_name:
        # A name that is not text may be any template's; a template passed by path needs none.
        raise CheckError(f"{path}: cannot read the template's name; pass --template PATH")
    return Template(path, declared or Path(path).stem, standalone(headings(renderer(body), source=body, github=False), renderer, body))


def parse_template(path: str, text: str, renderer: Callable[[str], str] | None = None, need_name: bool = True) -> Template:
    text = lines_of(text.removeprefix("\ufeff"))
    renderer = renderer or render
    if path.lower().endswith((".yml", ".yaml")):
        template = form_template(path, text, need_name)
        # GitHub shows each label as a rendered heading, so compare it as one.
        if template.headings:
            shown = headings(renderer("\n\n".join(f"### {heading.text}" for heading in template.headings)), github=False)
            if len(shown) == len(template.headings):
                for heading, rendered in zip(template.headings, shown):
                    # Reported as the label GitHub renders it from, which shows the same heading.
                    heading.written, heading.text = f"### {heading.text}", rendered.text
        return template
    return markdown_template(path, text, renderer, need_name)


class Source:
    """Template files in a checkout or, through gh, on a repository's default branch."""

    def __init__(
        self,
        root: Path | None = None,
        repo: str | None = None,
        run: Callable[[list[str]], str | None] | None = None,
    ) -> None:
        self.root = root
        self.repo = repo
        self.run = run
        # A host-qualified HOST/OWNER/REPO sends each request to that host.
        parts = (repo or "").split("/")
        self.slug = "/".join(parts[-2:])
        self.route = ["--hostname", parts[0]] if len(parts) == 3 else []

    def entries(self, directory: str) -> list[tuple[str, bool]]:
        """Names in a directory with whether each is a directory; [] when absent."""
        if self.root is not None:
            path = self.root / directory
            if not path.is_dir():
                return []
            return sorted((entry.name, entry.is_dir()) for entry in path.iterdir())
        assert self.run is not None
        endpoint = f"repos/{self.slug}/contents" + (f"/{directory}" if directory else "")
        output = self.run(["api", *self.route, endpoint])
        if output is None and not directory:
            raise CheckError(f"repository {self.repo} was not found or is not accessible")
        if output is None:
            return []
        listing = json.loads(output)
        if not isinstance(listing, list):
            return []
        return sorted((entry["name"], entry.get("type") == "dir") for entry in listing)

    def read(self, path: str) -> str:
        if self.root is not None:
            return (self.root / path).read_text(encoding="utf-8")
        assert self.run is not None
        output = self.run(
            ["api", *self.route, "-H", "Accept: application/vnd.github.raw", f"repos/{self.slug}/contents/{path}"]
        )
        if output is None:
            raise CheckError(f"template {path} disappeared from {self.repo}")
        return output


def may_be_named(path: str, text: str, name: str) -> bool:
    """Whether a template can be the one named; one whose name cannot be read may be."""
    wanted = name.casefold()
    if wanted in {Path(path).name.casefold(), Path(path).stem.casefold()}:
        return True
    text = text.removeprefix("\ufeff")
    if path.lower().endswith((".yml", ".yaml")):
        declared = declared_name(text)
        if not declared:
            return True  # Every form declares a name; one not read here may be this one.
    else:
        try:
            declared = name_in(front_matter(text)[0])
        except BrokenYaml as error:
            declared = error.name
        if declared is None:
            return True
    return (declared or Path(path).stem).casefold() == wanted


def discover(
    source: Source, kind: str, renderer: Callable[[str], str] | None = None, wanted: str | None = None
) -> list[Template | CheckError]:
    """Every template GitHub would offer for a new issue or pull request.

    A template that cannot be read is returned as its error, so it blocks only
    a check that needs it.
    """
    single = "pull_request_template.md" if kind == "pr" else "issue_template.md"
    folder = "pull_request_template" if kind == "pr" else "issue_template"
    suffixes = (".md",) if kind == "pr" else (".md", ".yml", ".yaml")
    paths: list[str] = []
    for directory in TEMPLATE_DIRS:
        for name, is_dir in source.entries(directory):
            path = f"{directory}/{name}" if directory else name
            if not is_dir and name.lower() == single:
                paths.append(path)
            elif is_dir and name.lower() == folder:
                paths.extend(
                    f"{path}/{child}"
                    for child, child_is_dir in source.entries(path)
                    if not child_is_dir
                    and child.lower().endswith(suffixes)
                    # config.yml configures the chooser; it is not a template.
                    and child.lower() not in {"config.yml", "config.yaml"}
                )
    found: list[Template | CheckError] = []
    skipped: list[str] = []
    for path in paths:
        try:
            try:
                text = source.read(path)
            except (OSError, ValueError) as error:
                raise CheckError(f"cannot read template {path}: {error}") from error
            if wanted and not may_be_named(path, text, wanted):
                skipped.append(path)
                continue  # Never rendered: it cannot be the template named.
            try:
                found.append(parse_template(path, text, renderer))
            except CheckError as error:
                # Keep the declared name, so a check naming another template ignores it.
                if not error.name:
                    if path.lower().endswith((".yml", ".yaml")):
                        error.name = declared_name(text.removeprefix("\ufeff")) or ""  # Unknown blocks a named check.
                    else:
                        try:
                            declared = name_in(front_matter(text.removeprefix("\ufeff"))[0])
                        except BrokenYaml as broken:
                            declared = broken.name
                        error.name = "" if declared is None else declared or Path(path).stem
                raise
            except ValueError as error:
                failure = CheckError(f"cannot read template {path}: {error}")
                # Keep the form's declared name, so a check that names it still sees the error.
                # Only the name line is read, so the field that failed cannot fail it too.
                failure.name = declared_name(text.removeprefix("\ufeff")) or ""
                raise failure from error
        except CheckError as error:
            error.path = path
            found.append(error)
    if wanted and skipped and not found:
        raise CheckError(f"no template named {wanted!r}; found: {', '.join(skipped)}")
    return found


def named(template: Template, name: str) -> bool:
    path = Path(template.path)
    return name.casefold() in {template.name.casefold(), path.name.casefold(), path.stem.casefold()}


def readable(found: list[Template | CheckError], name: str | None) -> list[Template]:
    """The templates a check can use, raising the error of one it needs.

    Without a name every template competes, so any unreadable one is needed.
    With a name, an unreadable template is needed when its file or declared
    name is that name, when its declared name could not be read, or when no
    readable template has it.
    """
    templates = [entry for entry in found if isinstance(entry, Template)]
    failures = [entry for entry in found if isinstance(entry, CheckError)]
    if not failures:
        return templates
    if not name:
        raise failures[0]
    for failure in failures:
        path = Path(failure.path)
        # A template whose declared name is unknown may be the one named.
        if not failure.name or name.casefold() in {
            failure.name.casefold(), path.name.casefold(), path.stem.casefold()
        }:
            raise failure
    if not any(named(template, name) for template in templates):
        raise failures[0]
    return templates


def longest_run(rows: list[int], cols: list[int], same: Callable[[int, int], bool]) -> list[tuple[int, int]]:
    """The longest in-order run of pairs between two index lists, by `same`."""
    lengths = [[0] * (len(cols) + 1) for _ in range(len(rows) + 1)]
    for a in range(len(rows) - 1, -1, -1):
        for b in range(len(cols) - 1, -1, -1):
            if same(rows[a], cols[b]):
                lengths[a][b] = lengths[a + 1][b + 1] + 1
            else:
                lengths[a][b] = max(lengths[a + 1][b], lengths[a][b + 1])
    pairs, a, b = [], 0, 0
    while a < len(rows) and b < len(cols):
        if same(rows[a], cols[b]) and lengths[a][b] == lengths[a + 1][b + 1] + 1:
            pairs.append((rows[a], cols[b]))
            a, b = a + 1, b + 1
        elif lengths[a + 1][b] >= lengths[a][b + 1]:
            a += 1
        else:
            b += 1
    return pairs


def in_order_pairs(expected: list[Heading], actual: list[Heading]) -> list[tuple[int, int]]:
    """The template headings the body keeps in order: exact copies first, then by text alone.

    Headings the body copied at the template's level pair first. Between
    them, a heading whose level changed pairs by its text, unless the body
    also holds an exact copy elsewhere, which is then out of order instead;
    so a subsection that shares a section's name does not take its place.
    """
    exact = longest_run(
        list(range(len(expected))),
        list(range(len(actual))),
        lambda i, j: (expected[i].level, expected[i].text) == (actual[j].level, actual[j].text),
    )
    kept = {j for _, j in exact}
    elsewhere = {
        i for i, heading in enumerate(expected)
        if any(j not in kept and (actual[j].level, actual[j].text) == (heading.level, heading.text) for j in range(len(actual)))
    }
    pairs = list(exact)
    bounds = [(-1, -1), *exact, (len(expected), len(actual))]
    for (i0, j0), (i1, j1) in zip(bounds, bounds[1:]):
        rows = [i for i in range(i0 + 1, i1) if i not in elsewhere]
        pairs += longest_run(rows, list(range(j0 + 1, j1)), lambda i, j: expected[i].text == actual[j].text)
    return sorted(pairs)


def similarity(left: Heading, right: Heading) -> float:
    return difflib.SequenceMatcher(None, left.text.casefold(), right.text.casefold()).ratio()


def compare(expected: list[Heading], actual: list[Heading]) -> list[dict[str, Any]]:
    """Problems with the body's copy of each template heading, in template order.

    Body headings the template does not name, such as subsections, are allowed.
    """
    pairs = in_order_pairs(expected, actual)
    matched = dict(pairs)
    used = set(matched.values())
    problems: list[dict[str, Any]] = []

    def problem(kind: str, index: int, found: Heading | None, detail: str) -> None:
        if expected[index].defined_elsewhere:
            detail += "; it uses a link or footnote defined elsewhere in the template, so copy that definition too"
        problems.append({
            "kind": kind,
            "templateIndex": index,
            "expected": str(expected[index]),
            "actual": str(found) if found else None,
            "line": found.line if found else None,
            "detail": detail,
        })

    placed: dict[int, Heading] = {}
    anchors = dict(pairs)  # Template index to body position, kept in order.

    def rename(index: int, position: int) -> None:
        used.add(position)
        placed[index] = actual[position]
        anchors[index] = position
        problem("renamed", index, actual[position], f"{actual[position]} should be {expected[index]}")

    for index, position in pairs:
        placed[index] = actual[position]
        if actual[position].level != expected[index].level:
            problem("renamed", index, actual[position], f"{actual[position]} should be {expected[index]}")

    for index, heading in enumerate(expected):
        if index in matched:
            continue
        # The copy at the template's level first, so a subsection is not taken for it.
        position = min(
            (j for j, found in enumerate(actual) if j not in used and found.text == heading.text),
            key=lambda j: (actual[j].level != heading.level, j),
            default=None,
        )
        if position is None:
            continue
        used.add(position)
        placed[index] = actual[position]
        previous = f"after {expected[index - 1]}" if index else "first"
        problem("out-of-order", index, actual[position], f"{heading} belongs {previous}")
        if actual[position].level != heading.level:
            problem("renamed", index, actual[position], f"{actual[position]} should be {heading}")

    # A renamed heading keeps its place between the headings the body kept in
    # order. Pair the most similar wording first, then a different heading at
    # the same level that stands in the template heading's place.

    def gap(index: int) -> range:
        before = max((j for i, j in anchors.items() if i < index), default=-1)
        after = min((j for i, j in anchors.items() if i > index), default=len(actual))
        return range(before + 1, after)

    scored = sorted(
        (
            (-similarity(heading, actual[j]), index, j)
            for index, heading in enumerate(expected)
            if index not in placed
            for j in gap(index)
            if j not in used and similarity(heading, actual[j]) >= RENAME_SIMILARITY
        ),
    )
    for _, index, position in scored:
        if index in placed or position in used or position not in gap(index):
            continue
        rename(index, position)
    for index, heading in enumerate(expected):
        if index in placed:
            continue
        position = next(
            (j for j in gap(index) if j not in used and actual[j].level == heading.level), None
        )
        if position is None:
            problem("missing", index, None, f"{heading} is missing")
        else:
            rename(index, position)

    for index, found in placed.items():
        if not found.has_content:
            problem("empty", index, found, f"{found} has no content; write None or the reason")

    order = {"missing": 0, "renamed": 1, "out-of-order": 2, "empty": 3}
    problems.sort(key=lambda item: (item["templateIndex"], order[item["kind"]]))
    return problems


def select(
    templates: list[Template], body: list[Heading], name: str | None
) -> tuple[Template, list[dict[str, Any]]]:
    """The named template, or the one the body follows most closely."""
    if name:
        chosen = [template for template in templates if named(template, name)]
        if not chosen:
            choices = ", ".join(template.name for template in templates)
            raise CheckError(f"no template named {name!r}; found: {choices}")
        templates = chosen
    scored = []
    for template in templates:
        problems = compare(template.headings, body)
        # Kept by text, at any level: a template the body follows keeps the most.
        kept = len(longest_run(
            list(range(len(template.headings))), list(range(len(body))),
            lambda i, j: template.headings[i].text == body[j].text,
        ))
        # Most template headings kept first, so a body missing a heading from
        # the template it follows does not match a smaller template instead.
        scored.append(((-kept, len(problems)), template, problems))
    scored.sort(key=lambda entry: entry[0])
    best_score, best, problems = scored[0]
    tied = [
        template
        for score, template, _ in scored[1:]
        if score == best_score and [(h.level, h.text) for h in template.headings] != [(h.level, h.text) for h in best.headings]
    ]
    if tied:
        choices = ", ".join(template.name for template in [best, *tied])
        raise CheckError(f"the body fits several templates equally ({choices}); pass --template-name")
    return best, problems


def gh_runner(args: list[str]) -> str | None:
    """Run gh and return its output, or None for a resource GitHub reports missing."""
    try:
        completed = subprocess.run(
            ["gh", *args], text=True, encoding="utf-8", capture_output=True, timeout=60, check=False,
        )
    except FileNotFoundError as error:
        raise CheckError("gh is not installed or not on PATH") from error
    except subprocess.TimeoutExpired as error:
        raise CheckError("gh timed out after 60s") from error
    if completed.returncode != 0:
        message = (completed.stderr or completed.stdout).strip()
        if "HTTP 404" in message:
            return None
        raise CheckError(message or f"gh exited {completed.returncode}")
    return completed.stdout


def live_body(kind: str, number: int, repo: str | None) -> str:
    args = [kind, "view", str(number), "--json", "body"]
    if repo:
        args.extend(["--repo", repo])
    output = gh_runner(args)
    if output is None:
        raise CheckError(f"{kind} #{number} was not found")
    try:
        return str(json.loads(output)["body"] or "")
    except (ValueError, KeyError, TypeError) as error:
        raise CheckError(f"gh returned no body for {kind} #{number}") from error


def checkout_root() -> Path:
    completed = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], text=True, capture_output=True, check=False
    )
    if completed.returncode != 0:
        raise CheckError("not in a git checkout; pass --root or --repo")
    return Path(completed.stdout.strip())


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    body = result.add_mutually_exclusive_group(required=True)
    body.add_argument("--body", help="body file, or - for standard input")
    body.add_argument("--pr", type=int, help="read the live body of this pull request")
    body.add_argument("--issue", type=int, help="read the live body of this issue")
    result.add_argument("--template", type=Path, help="template file; skips discovery")
    result.add_argument("--template-name", help="template to use among several, by front matter name or file name")
    result.add_argument("--kind", choices=("issue", "pr"), help="template kind to discover for --body")
    result.add_argument("--repo", help="OWNER/REPO for --pr, --issue and, without --root, template discovery")
    result.add_argument("--root", type=Path, help="checkout to discover templates in (default: current checkout)")
    result.add_argument("--json", action="store_true")
    return result


def github_host(host: str) -> str:
    """A host as gh resolves it: www and SSH-over-443 aliases of github.com are github.com."""
    host = host.lower()
    return "github.com" if host in ("www.github.com", "ssh.github.com") else host


def repository(name: str | None) -> str | None:
    """OWNER/REPO or HOST/OWNER/REPO, also from a repository URL gh accepts."""
    if not name:
        return name
    scp = re.fullmatch(r"[\w.-]+@([\w.-]+):(?!//)(.+)", name)
    if scp:  # An SSH clone URL, such as git@github.com:cli/cli.git.
        name = f"ssh://{scp.group(1)}/{scp.group(2)}"
    if "://" not in name:
        parts = name.split("/")
        if len(parts) not in (2, 3) or not all(parts):
            raise CheckError(f"--repo {name} is not OWNER/REPO, HOST/OWNER/REPO or a repository URL")
        return "/".join([github_host(parts[0]), *parts[1:]]) if len(parts) == 3 else name
    url = urlparse(name)
    path = url.path.strip("/").removesuffix(".git")
    if not url.hostname or path.count("/") != 1:
        raise CheckError(f"--repo {name} names no repository")
    return f"{github_host(url.hostname)}/{path}"


def run(args: argparse.Namespace) -> dict[str, Any]:
    args.repo = repository(args.repo)
    if args.pr is not None:
        source_label, text = f"pr #{args.pr}", live_body("pr", args.pr, args.repo)
    elif args.issue is not None:
        source_label, text = f"issue #{args.issue}", live_body("issue", args.issue, args.repo)
    elif args.body == "-":
        source_label, text = "stdin", sys.stdin.read()
    else:
        source_label = args.body
        try:
            text = Path(args.body).read_text(encoding="utf-8")
        except (OSError, ValueError) as error:
            raise CheckError(f"cannot read body: {error}") from error
    kind = "pr" if args.pr is not None else "issue" if args.issue is not None else args.kind
    if not kind and args.template and args.template.suffix.lower() in (".yml", ".yaml"):
        kind = "issue"  # Only issues have forms.
    if args.template:
        try:
            templates = [parse_template(str(args.template), args.template.read_text(encoding="utf-8"), need_name=False)]
        except (OSError, ValueError) as error:
            raise CheckError(f"cannot read template: {error}") from error
        absent = f"{args.template} has no headings"
    else:
        if not kind:
            raise CheckError("--kind issue|pr is required to discover a template for --body")
        if args.root and not args.root.is_dir():
            raise CheckError(f"--root {args.root} is not a directory")
        if args.root or not args.repo:
            source = Source(root=args.root or checkout_root())
        else:
            source = Source(repo=args.repo, run=gh_runner)
        templates = readable(discover(source, kind, None, args.template_name), args.template_name)
        absent = (
            f"the {kind} template named {args.template_name} has no headings"
            if args.template_name
            else f"no {kind} template with headings found"
        )
    templates = [template for template in templates if template.headings]
    if not templates:
        return {"state": "no-template", "body": source_label, "problems": [], "reason": absent}

    # Without a kind, as with --template alone, the body reads as a pull request's.
    text = lines_of(text.removeprefix("\ufeff"))
    body = standalone(headings(render(text), kind or "pr", text, github=False), render, text)
    template, problems = select(templates, body, args.template_name)
    return {
        "state": "mismatch" if problems else "match",
        "body": source_label,
        "template": {"path": template.path, "name": template.name, "headings": [str(h) for h in template.headings]},
        "problems": problems,
        "reason": f"{len(problems)} heading problem(s)" if problems else "headings match the template",
    }


def main() -> int:
    args = parser().parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")  # A label the terminal cannot encode.
    try:
        result = run(args)
    # A check that could not run must not read as a mismatch to fix.
    except (CheckError, OSError, ValueError, KeyError, TypeError) as error:
        result = {"state": "operational-error", "problems": [], "reason": str(error)}
    except Exception as error:  # A defect in this checker is no verdict on the body either.
        result = {"state": "operational-error", "problems": [], "reason": f"checker failed: {error!r}"}
    if args.json:
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    else:
        if "template" in result:
            print(f"template: {result['template']['path']} ({result['template']['name']})")
        for problem in result["problems"]:
            print(f"{problem['kind']}: {problem['detail']}")
        print(f"{result['state']}: {result['reason']}")
    return {"match": 0, "no-template": 0, "mismatch": 1}.get(result["state"], 2)


if __name__ == "__main__":
    sys.exit(main())
