import html
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


sys.dont_write_bytecode = True  # Loading the script below must not cache it in the skill tree.

SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "check_template.py"
SPEC = importlib.util.spec_from_file_location("check_template", SCRIPT_PATH)
assert SPEC and SPEC.loader
CHECK_TEMPLATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECK_TEMPLATE  # dataclasses resolve their module by name.
SPEC.loader.exec_module(CHECK_TEMPLATE)


def mini_render(text):
    """Enough of GitHub's rendering for these tests' plain bodies.

    Parsing tests use HTML GitHub rendered, from github_rendered.json.
    """
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    out = []
    for line in text.split("\n"):
        line = line.strip()
        heading = re.fullmatch(r"(#{1,6})\s+(.*)", line)
        item = re.fullmatch(r"(?:[-*+]|[0-9]+[.)])(?:\s+(.*))?", line)
        if not line:
            continue
        if re.fullmatch(r"-{3,}", line):
            out.append("<hr>")
        elif heading:
            level = len(heading.group(1))
            out.append(f"<h{level}>{html.escape(heading.group(2))}</h{level}>")
        elif item:
            out.append(f"<ul><li>{html.escape(item.group(1) or '')}</li></ul>")
        else:
            out.append("<p>" + re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(line)) + "</p>")
    return "\n".join(out)

# Parsing and comparison tests read Markdown through the stand-in; the real
# renderer, cmark-gfm, is tested against GitHub's own output below.
HAS_RENDERER = all(importlib.util.find_spec(package) is not None for package in ("cmarkgfm", "yaml"))
REAL_RENDER = CHECK_TEMPLATE.render
CHECK_TEMPLATE.render = mini_render
# CI installs the renderer, so its tests never skip there.
needs_renderer = unittest.skipUnless(HAS_RENDERER or os.environ.get("CI"), "cmarkgfm or PyYAML is not installed")
RENDERED = json.loads((Path(__file__).parent / "github_rendered.json").read_text(encoding="utf-8"))


def md_headings(text, kind=None):
    return CHECK_TEMPLATE.headings(mini_render(text), kind)


ISSUE_TEMPLATE = """---
name: Issue
about: Propose a feature, fix, or scoped change
title: ""
---

## Summary

What should change?

## Why

Why is this needed?

## Current behavior

What happens today?

## Expected behavior

What should happen instead?

## Scope notes

Constraints, non-goals, related issues, or implementation notes.
"""

BUG_FORM = """name: Bug report
description: Something is broken
body:
  - type: markdown
    attributes:
      value: |
        ## Thanks for reporting
  - type: input
    id: version
    attributes:
      label: Version
      placeholder: "1.2.3"
    validations:
      required: true
  - type: textarea
    attributes:
      label: "Steps to reproduce"
  - type: checkboxes
    attributes:
      label: Checks
      options:
        - label: I searched existing issues
"""

# Fake gh: answers each argument list from the scenario file; anything else is
# a missing resource, which gh reports as HTTP 404.
FAKE_GH = r"""#!/usr/bin/env python3
import json, os, pathlib, sys

responses = json.loads(pathlib.Path(os.environ["FAKE_GH_SCENARIO"]).read_text())
answer = responses.get(" ".join(sys.argv[1:]))
if answer is None:
    print("gh: Not Found (HTTP 404)", file=sys.stderr)
    sys.exit(1)
print(answer, end="")
"""


def body(*sections):
    return "\n\n".join(f"{heading}\n\n{text}" if text else heading for heading, text in sections) + "\n"


FULL = [
    ("## Summary", "Add the flag."),
    ("## Why", "Users asked."),
    ("## Current behavior", "No flag."),
    ("## Expected behavior", "A flag."),
    ("## Scope notes", "None."),
]


class RenderedHeadingTests(unittest.TestCase):
    """Headings read from HTML that GitHub's Markdown API rendered for each case."""

    def read(self, case, kind=None):
        return [(heading.text, heading.has_content) for heading in CHECK_TEMPLATE.headings(RENDERED[case]["html"], kind)]

    def test_a_placeholder_list_item_is_not_content(self):
        self.assertEqual(
            self.read("placeholders"), [("Summary", False), ("Steps", False), ("Tasks", False), ("Filled", True)]
        )

    def test_headings_in_code_comments_quotes_lists_and_tables_are_content(self):
        self.assertEqual(self.read("code_comment_quote"), [("A", True), ("B", True)])

    def test_a_fence_inside_a_list_item_keeps_its_heading_as_code(self):
        self.assertEqual(self.read("list_fence"), [("Summary", True)])

    def test_a_section_runs_to_the_next_heading_at_the_same_or_higher_level(self):
        self.assertEqual(
            self.read("sections"),
            [("Title", True), ("Summary", True), ("Detail", True), ("Empty", False), ("Media", True)],
        )

    def test_a_pull_requests_review_note_is_not_content(self):
        self.assertEqual(self.read("review_note", "pr"), [("Summary", True), ("Testing", False)])
        self.assertEqual(
            self.read("review_note", "issue"), [("Summary", True), ("Testing", True), ("After the note", False)]
        )
        self.assertEqual(self.read("rule_only", "pr"), [("Testing", True)])

    def test_only_the_generated_attribution_note_is_dropped_from_an_issue(self):
        self.assertEqual(self.read("attribution", "issue"), [("Related", False)])
        self.assertEqual(self.read("attribution", "pr"), [("Related", True)])
        self.assertEqual(self.read("note_by_person", "issue"), [("Related", True)])

    def test_an_attribution_note_with_more_in_it_is_content(self):
        self.assertEqual(self.read("attribution_with_more", "issue"), [("Related", True)])

    def test_a_heading_inside_an_alert_is_content(self):
        self.assertEqual(self.read("alert_heading"), [("A", True), ("B", True)])

    def test_a_heading_inside_details_is_a_section(self):
        self.assertEqual(self.read("details"), [("Summary", True), ("Inside details", True)])

    def test_text_after_a_comment_on_its_line_is_no_heading(self):
        self.assertEqual(self.read("comment_line_heading"), [("Summary", True)])

    def test_a_setext_heading_is_a_heading_as_github_shows_it(self):
        self.assertEqual(self.read("setext"), [("A topic", True)])

    def test_the_footnotes_github_appends_are_no_section(self):
        self.assertEqual(self.read("footnotes"), [("Summary", True)])
        self.assertEqual(self.read("footnote_after_last"), [("Summary", True), ("Testing", False)])

    def test_nested_placeholders_are_no_content_and_a_nested_answer_is(self):
        self.assertEqual(self.read("nested_placeholders"), [("A", False), ("B", True)])
        nested = "<h2>A</h2><ul><li>[ ]<ul><li>[ ]</li></ul></li></ul>"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(nested)], [False])

    def test_an_image_in_a_heading_compares_by_its_label_and_source(self):
        self.assertEqual(self.read("image_heading"), [("Release ![production](<https://example.org/production.svg>)", True)])
        texts = {
            CHECK_TEMPLATE.headings(html)[0].text
            for html in (
                '<h2>Release <img src="https://example.org/production.svg" alt="production"></h2>',
                '<h2>Release <img src="https://example.org/staging.svg" alt="production"></h2>',
                "<h2>Release production</h2>",
            )
        }
        self.assertEqual(len(texts), 3)

    def test_a_review_note_may_name_a_short_commit_after_other_words(self):
        for line in ("Edit: `41c14b` reviewed", "Edit: reviewed `41c14b4`"):
            with self.subTest(line=line):
                found = md_headings(f"## A\n\n-\n\n---\n\n{line}\n", "pr")
                self.assertEqual([(h.text, h.has_content) for h in found], [("A", False)])

    def test_only_a_closing_edit_line_naming_a_head_is_the_review_note(self):
        for line in ("Edit: plain words", "Edit: `config.yml` changed"):
            with self.subTest(line=line):
                found = md_headings(f"## A\n\nx\n\n---\n\n{line}\n\n## B\n\ny\n", "pr")
                self.assertEqual([(h.text, h.has_content) for h in found], [("A", True), ("B", True)])

    def test_a_line_after_the_attribution_in_its_paragraph_is_content(self):
        note = (
            '<h2>Related</h2><div class="markdown-alert markdown-alert-note"><p class="markdown-alert-title">Note</p>'
            "<p>Created on behalf of @someone using Some Model.<br>All tests passed.</p></div>"
        )
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(note, "issue")], [True])

    def test_a_review_note_may_name_its_commit_inside_other_formatting(self):
        note = "<h2>Testing</h2><hr><p>Edit: <strong><code>abc1234</code></strong> reviewed</p>"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(note, "pr")], [False])

    def test_a_heading_keeps_its_inline_code_apart_from_text(self):
        plain, code = (
            CHECK_TEMPLATE.headings(html)[0].text
            for html in ("<h2>:warning: Testing</h2>", "<h2><code>:warning:</code> Testing</h2>")
        )
        self.assertEqual((plain, code), (":warning: Testing", "`:warning:` Testing"))

    def test_an_unclosed_paragraph_closes_at_the_next_heading(self):
        body = "<p>Intro.<h2>Testing</h2><hr><p>Edit: <code>abc1234</code> reviewed</p>"
        self.assertEqual([(h.text, h.has_content) for h in CHECK_TEMPLATE.headings(body, "pr")], [("Testing", False)])

    def test_literal_backticks_never_pass_for_inline_code(self):
        literal, code = (
            CHECK_TEMPLATE.headings(html)[0].text for html in ("<h2>`make` it</h2>", "<h2><code>make</code> it</h2>")
        )
        self.assertNotEqual(literal, code)

    def test_literal_markers_in_image_alt_text_never_pass_for_formatting(self):
        image, emphasis = (
            CHECK_TEMPLATE.headings(html)[0].text
            for html in ('<h2><img src="https://example.org/r.svg" alt="*Ready*"></h2>', "<h2><em>Ready</em></h2>")
        )
        self.assertNotEqual(image, emphasis)

    def test_an_author_link_with_the_anchor_class_keeps_its_destination(self):
        texts = {
            CHECK_TEMPLATE.headings(f'<h2><a class="anchor" href="{href}">Flags</a></h2>')[0].text
            for href in ("/reference", "/unrelated")
        }
        self.assertEqual(len(texts), 2)

    def test_struck_out_and_emphasized_words_are_part_of_a_heading(self):
        texts = [
            CHECK_TEMPLATE.headings(html)[0].text
            for html in ("<h2>Do not deploy</h2>", "<h2>Do <del>not</del> deploy</h2>", "<h2>Do <em>not</em> deploy</h2>", "<h2>Do *not* deploy</h2>")
        ]
        self.assertEqual(len(set(texts)), 4)

    def test_sub_and_superscript_are_part_of_a_heading(self):
        texts = {CHECK_TEMPLATE.headings(html)[0].text for html in ("<h2>H<sub>2</sub>O</h2>", "<h2>H2O</h2>", "<h2>H<sup>2</sup>O</h2>")}
        self.assertEqual(len(texts), 3)

    def test_only_a_checked_task_box_is_content(self):
        hidden = '<h2>Testing</h2><p><input type="hidden" checked=""></p>'
        box = '<h2>Testing</h2><ul><li><input type="checkbox" checked="" disabled=""> </li></ul>'
        self.assertEqual([CHECK_TEMPLATE.headings(html)[0].has_content for html in (hidden, box)], [False, True])

    def test_a_malformed_repository_is_an_error(self):
        # Four parts, joined here so the text holds no repository name to look up.
        for name in ("/".join(["github.com", "extra", "cli", "cli"]), "cli//cli", "cli"):
            with self.subTest(name=name), self.assertRaises(CHECK_TEMPLATE.CheckError):
                CHECK_TEMPLATE.repository(name)

    def test_the_uv_fallback_clears_inherited_package_sources(self):
        seen = {}
        saved = (CHECK_TEMPLATE.cmarkgfm, CHECK_TEMPLATE.shutil.which, CHECK_TEMPLATE.subprocess.run)
        os.environ.update({"UV_INDEX": "private=https://packages.example.invalid/simple", "UV_WORKING_DIR": "/nowhere", "UV_PROJECT": "/nowhere"})

        def run(command, **options):
            seen.update(command=command, env=options["env"])
            return subprocess.CompletedProcess(command, 0, "<h2>A</h2>", "")

        CHECK_TEMPLATE.cmarkgfm, CHECK_TEMPLATE.shutil.which, CHECK_TEMPLATE.subprocess.run = None, lambda name: "uv", run
        try:
            REAL_RENDER("## A\n")
        finally:
            CHECK_TEMPLATE.cmarkgfm, CHECK_TEMPLATE.shutil.which, CHECK_TEMPLATE.subprocess.run = saved
            for key in ("UV_INDEX", "UV_WORKING_DIR", "UV_PROJECT"):
                os.environ.pop(key, None)
        self.assertFalse({"UV_INDEX", "UV_WORKING_DIR", "UV_PROJECT"} & set(seen["env"]))
        self.assertIn("https://pypi.org/simple", seen["command"])

    def test_github_host_aliases_resolve_to_github_com(self):
        self.assertEqual(
            [CHECK_TEMPLATE.repository(name) for name in ("ssh://git@ssh.github.com:443/cli/cli.git", "www.github.com/cli/cli")],
            ["github.com/cli/cli", "github.com/cli/cli"],
        )

    def test_a_review_note_inside_a_wrapper_ends_the_body(self):
        body = "<div><h2>Testing</h2><hr><p>Edit: <code>abc1234</code> reviewed</p></div>"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(body, "pr")], [False])

    def test_a_review_note_needs_blank_lines_around_its_rule_in_the_source(self):
        cramped = "## Summary\n---\nEdit: `abc1234` reviewed\n\n## Testing\n\nRan it.\n"
        spaced = "## Summary\n\nText.\n\n---\n\nEdit: `abc1234` reviewed\n\n## Testing\n\nRan it.\n"
        read = lambda text: [h.text for h in CHECK_TEMPLATE.headings(mini_render(text), "pr", text)]
        self.assertEqual((read(cramped), read(spaced)), (["Summary", "Testing"], ["Summary"]))

    def test_an_uppercase_commit_names_the_head(self):
        body = "<h2>Testing</h2><hr><p>Edit: <code>ABC1234</code> reviewed</p>"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(body, "pr")], [False])

    def test_a_link_in_a_heading_compares_by_its_destination(self):
        texts = {
            CHECK_TEMPLATE.headings(html)[0].text
            for html in ('<h2><a href="https://example.org/a">Testing</a></h2>', '<h2><a href="https://example.org/b">Testing</a></h2>', "<h2>Testing</h2>")
        }
        self.assertEqual(len(texts), 3)

    @needs_renderer
    def test_a_raw_rule_inside_the_review_note_does_not_open_another(self):
        body = "## Summary\n\n---\n\nEdit: `abc1234` reviewed\n\n<hr>\n\nEdit: `def5678` also\n"
        found = CHECK_TEMPLATE.headings(REAL_RENDER(body), "pr", body)
        self.assertEqual([(h.text, h.has_content) for h in found], [("Summary", False)])

    def test_an_authors_footnotes_section_keeps_its_headings(self):
        html = '<section class="footnotes"><h2>Sources</h2><p>x</p></section>'
        self.assertEqual([h.text for h in CHECK_TEMPLATE.headings(html)], ["Sources"])

    def test_a_partly_formatted_alert_marker_is_no_attribution_note(self):
        quote = "<h2>Related</h2><blockquote><p>[!<em>NOTE</em>]\nCreated on behalf of @someone using Some Model.</p></blockquote>"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(quote, "issue")], [True])

    def test_a_link_around_a_badge_and_text_is_the_authors(self):
        linked = '<h2><a href="https://example.org/b.svg"><img src="https://example.org/b.svg" alt="badge"> <em>Status</em></a></h2>'
        plain = '<h2><img src="https://example.org/b.svg" alt="badge"> <em>Status</em></h2>'
        self.assertNotEqual(*(CHECK_TEMPLATE.headings(html)[0].text for html in (linked, plain)))

    def test_a_quoted_attribution_example_is_content(self):
        quote = "<h2>Related</h2><blockquote><p><code>[!NOTE]</code>\nCreated on behalf of @someone using Some Model.</p></blockquote>"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(quote, "issue")], [True])

    def test_an_earlier_wrapped_example_does_not_stand_for_the_review_note(self):
        body = (
            "<div><hr><p>Edit: <code>abc1234</code> example</p></div>"
            "<h2>Testing</h2><p>Ran it.</p><hr><p>Edit: <code>def5678</code> reviewed</p>"
        )
        self.assertEqual([(h.text, h.has_content) for h in CHECK_TEMPLATE.headings(body, "pr")], [("Testing", True)])

    def test_literal_brackets_never_pass_for_a_link(self):
        literal, link = (
            CHECK_TEMPLATE.headings(html)[0].text
            for html in ("<h2>[Setup](/setup)</h2>", '<h2><a href="/setup">Setup</a></h2>')
        )
        self.assertNotEqual(literal, link)

    def test_an_image_in_the_attribution_note_is_content(self):
        note = (
            '<h2>Related</h2><div class="markdown-alert markdown-alert-note"><p class="markdown-alert-title">Note</p>'
            '<p>Created on behalf of @someone using Some Model. <img src="https://example.org/shot.png" alt=""></p></div>'
        )
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(note, "issue")], [True])

    def test_www_github_com_is_github_com(self):
        self.assertEqual(CHECK_TEMPLATE.repository("https://www.github.com/cli/cli"), "github.com/cli/cli")

    def test_without_the_renderer_or_uv_rendering_is_an_operational_error(self):
        original = (CHECK_TEMPLATE.cmarkgfm, CHECK_TEMPLATE.shutil.which)
        CHECK_TEMPLATE.cmarkgfm, CHECK_TEMPLATE.shutil.which = None, lambda name: None
        try:
            with self.assertRaisesRegex(CHECK_TEMPLATE.CheckError, "pip install cmarkgfm"):
                REAL_RENDER("## A\n")
        finally:
            CHECK_TEMPLATE.cmarkgfm, CHECK_TEMPLATE.shutil.which = original

    def test_a_check_with_no_template_renders_nothing(self):
        original = CHECK_TEMPLATE.render

        def unavailable(markdown):
            raise AssertionError("rendered without a template")

        CHECK_TEMPLATE.render = unavailable
        try:
            with tempfile.TemporaryDirectory() as directory:
                args = CHECK_TEMPLATE.parser().parse_args(["--root", directory, "--kind", "pr", "--body", os.devnull])
                self.assertEqual(CHECK_TEMPLATE.run(args)["state"], "no-template")
        finally:
            CHECK_TEMPLATE.render = original

    def test_a_repository_url_names_its_host(self):
        self.assertEqual(
            [CHECK_TEMPLATE.repository(name) for name in ("https://ghe.example.com/cli/cli.git", "cli/cli", None)],
            ["ghe.example.com/cli/cli", "cli/cli", None],
        )

    def test_an_attribution_in_another_kind_of_alert_is_content(self):
        warning = (
            '<h2>Related</h2><div class="markdown-alert markdown-alert-warning"><p class="markdown-alert-title">Warning</p>'
            "<p>Created on behalf of @someone using an expired token.</p></div>"
        )
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(warning, "issue")], [True])

    def test_a_footer_that_adds_a_sentence_is_content(self):
        note = (
            '<h2>Related</h2><div class="markdown-alert markdown-alert-note"><p class="markdown-alert-title">Note</p>'
            "<p>Created on behalf of @someone using Some Model. All tests passed.</p></div>"
        )
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(note, "issue")], [True])

    def test_an_attribution_naming_a_versioned_model_is_dropped(self):
        note = (
            '<h2>Related</h2><div class="markdown-alert markdown-alert-note"><p class="markdown-alert-title">Note</p>'
            "<p>Created on behalf of @someone using GPT-5.4 High.</p></div>"
        )
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(note, "issue")], [False])

    def test_a_line_break_in_a_heading_is_part_of_it(self):
        self.assertEqual(self.read("line_break_heading"), [("Rollout<br>plan", True)])

    def test_a_checked_task_item_is_content_and_an_unchecked_one_is_not(self):
        self.assertEqual(self.read("checked_task"), [("Done", True), ("Open", False)])

    def test_the_review_note_cut_falls_at_the_rule_before_it(self):
        self.assertEqual(self.read("two_rules", "pr"), [("Summary", True), ("Testing", True)])


@needs_renderer
class RendererParityTests(unittest.TestCase):
    """cmark-gfm, rendering locally, yields the headings GitHub's own rendering does."""

    def test_the_fallback_program_reads_and_writes_utf8_whatever_the_stream_encoding(self):
        # Streams in Windows' cp1252, which cannot decode the emoji's UTF-8 bytes.
        cp1252 = (
            "import io, sys\n"
            "sys.stdin = io.TextIOWrapper(sys.stdin.buffer, encoding='cp1252')\n"
            "sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='cp1252')\n"
        )
        completed = subprocess.run(
            [sys.executable, "-I", "-c", cp1252 + CHECK_TEMPLATE.RENDER],
            input="## \U0001F4C1 Files\n".encode("utf-8"), capture_output=True, check=True,
        )
        self.assertEqual([h.text for h in CHECK_TEMPLATE.headings(completed.stdout.decode("utf-8"))], ["\U0001F4C1 Files"])

    def test_the_fallback_program_never_imports_from_the_directory_it_runs_in(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "cmarkgfm.py").write_text("raise SystemExit('shadowed')\n", encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, "-I", "-c", CHECK_TEMPLATE.RENDER],
                input=b"## A\n", cwd=directory, capture_output=True, check=True,
            )
        self.assertEqual([h.text for h in CHECK_TEMPLATE.headings(completed.stdout.decode("utf-8"))], ["A"])

    # Resolves cmarkgfm from PyPI through uv, so it runs only when asked for.
    @unittest.skipUnless(shutil.which("uv") and os.environ.get("TEMPLATE_CHECK_UV_TESTS"), "set TEMPLATE_CHECK_UV_TESTS=1")
    def test_the_uv_fallback_never_imports_from_the_directory_it_runs_in(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "cmarkgfm.py").write_text("raise SystemExit('shadowed')\n", encoding="utf-8")
            saved = (CHECK_TEMPLATE.cmarkgfm, CHECK_TEMPLATE.tempfile.gettempdir)
            CHECK_TEMPLATE.cmarkgfm, CHECK_TEMPLATE.tempfile.gettempdir = None, lambda: directory
            try:
                self.assertEqual([h.text for h in CHECK_TEMPLATE.headings(REAL_RENDER("## A\n"))], ["A"])
            finally:
                CHECK_TEMPLATE.cmarkgfm, CHECK_TEMPLATE.tempfile.gettempdir = saved

    def test_a_markdown_heading_reports_its_source_line(self):
        self.assertEqual([h.line for h in CHECK_TEMPLATE.headings(REAL_RENDER("Intro.\n\n## A\n\n## B\n"))], [3, 5])

    def test_only_a_blank_lined_dash_rule_opens_the_review_note(self):
        body = (
            "## Summary\n\nAn example:\n\n```\n\n---\n\nEdit: `abc1234` reviewed\n```\n\n"
            "***\nEdit: `def5678` is how a note reads\n\n## Testing\n\nRan it.\n"
        )
        found = CHECK_TEMPLATE.headings(REAL_RENDER(body), "pr", body)
        self.assertEqual([(h.text, h.has_content) for h in found], [("Summary", True), ("Testing", True)])

    def test_only_a_plain_edit_opening_starts_the_review_note(self):
        for line in ("**Edit:** `abc1234` is how a note reads", "*Edit*: `abc1234` is how a note reads"):
            with self.subTest(line=line):
                body = f"## Summary\n\nAn example:\n\n---\n\n{line}\n\n## Testing\n\nRan it.\n"
                found = CHECK_TEMPLATE.headings(REAL_RENDER(body), "pr", body)
                self.assertEqual([(h.text, h.has_content) for h in found], [("Summary", True), ("Testing", True)])

    def test_a_raw_rule_naming_a_source_position_is_no_separator(self):
        for position in ("x", "9:1-9:3"):
            with self.subTest(position=position):
                body = (
                    f'## Summary\n\nAn example:\n\n<hr data-sourcepos="{position}">\n\n'
                    "Edit: `abc1234` is how a note reads\n\n---\n\n## Testing\n\nRan it.\n"
                )
                found = CHECK_TEMPLATE.headings(REAL_RENDER(body), "pr", body)
                self.assertEqual([(h.text, h.has_content) for h in found], [("Summary", True), ("Testing", True)])

    def test_a_reported_code_heading_reads_back_as_the_same_heading(self):
        for heading in ("## `` a`b ``", "## ``` ``a`` ```", "## `x` and ``y`z``"):
            with self.subTest(heading=heading):
                reported = CHECK_TEMPLATE.headings(REAL_RENDER(heading + "\n"))[0]
                again = CHECK_TEMPLATE.headings(REAL_RENDER(f"{reported}\n"))[0]
                self.assertEqual(str(again), str(reported))

    def test_only_a_contiguous_dash_rule_opens_the_review_note(self):
        body = "## Summary\n\nSee below.\n\n- - -\n\nEdit: introduced in `abc1234`.\n\n## Testing\n\nRan it.\n"
        found = CHECK_TEMPLATE.headings(REAL_RENDER(body), "pr", body)
        self.assertEqual([(h.text, h.has_content) for h in found], [("Summary", True), ("Testing", True)])

    def test_links_differing_in_destination_never_compare_equal(self):
        inside, after = (
            CHECK_TEMPLATE.headings(REAL_RENDER(heading))[0].text
            for heading in ("## [read](<https://example.org/page)>)\n", "## [read](https://example.org/page))\n")
        )
        self.assertNotEqual(inside, after)

    def test_a_reported_heading_with_literal_markup_reads_back_as_the_same_heading(self):
        for heading in ("## Version \\#", "## snake\\_case", "## Fish &amp;amp; chips", "## C:\\\\temp", "## [a](<x>y>)"):
            with self.subTest(heading=heading):
                reported = CHECK_TEMPLATE.headings(REAL_RENDER(heading + "\n"))[0]
                again = CHECK_TEMPLATE.headings(REAL_RENDER(f"{reported}\n"))[0]
                self.assertEqual(str(again), str(reported))

    def test_text_beside_the_attribution_note_is_content(self):
        body = "## Related\n\n> [!NOTE]\n> Created on behalf of @someone using Some Model.\n>\n> <!-- details -->Reproduced on Linux.\n"
        found = CHECK_TEMPLATE.headings(REAL_RENDER(body), "issue", body)
        self.assertEqual([h.has_content for h in found], [True])

    def test_a_footnote_reference_in_a_heading_compares_by_its_label(self):
        template = "## Rollout [^ref]\n\n[^ref]: r\n"
        body = "Intro.[^a]\n\n## Rollout [^ref]\n\n[^a]: a\n[^ref]: r\n"
        texts = [[h.text for h in CHECK_TEMPLATE.headings(REAL_RENDER(text))] for text in (template, body)]
        self.assertEqual(texts, [["Rollout [^ref]"], ["Rollout [^ref]"]])
        self.assertEqual(CHECK_TEMPLATE.footnote_label("#user-content-fn-ref-e42c25f642414e4141c39e11533dd6f0"), "ref")

    def test_a_review_note_inside_a_section_ends_the_body(self):
        body = "## Summary\n\nx\n\n<section>\n\n---\n\nEdit: `abc1234` reviewed\n\n## Testing\n\nRan.\n\n</section>\n"
        found = CHECK_TEMPLATE.headings(REAL_RENDER(body), "pr", body)
        self.assertEqual([(h.text, h.has_content) for h in found], [("Summary", True)])

    def test_a_reported_link_heading_with_a_literal_bracket_reads_back(self):
        reported = CHECK_TEMPLATE.headings(REAL_RENDER("## [Flags \\]](/reference)\n"))[0]
        self.assertEqual(str(CHECK_TEMPLATE.headings(REAL_RENDER(f"{reported}\n"))[0]), str(reported))

    def test_nested_emphasis_stays_apart_from_bold_and_reads_back(self):
        headings = ("## *_Important_*", "## **Important**", "## ***Important***", "## **_Important_**")
        reported = [CHECK_TEMPLATE.headings(REAL_RENDER(heading + "\n"))[0] for heading in headings]
        self.assertEqual(len({h.text for h in reported}), len(headings))
        for heading in reported:
            with self.subTest(heading=str(heading)):
                self.assertEqual(str(CHECK_TEMPLATE.headings(REAL_RENDER(f"{heading}\n"))[0]), str(heading))

    def test_a_footnote_label_compares_in_any_case(self):
        texts = [
            CHECK_TEMPLATE.headings(REAL_RENDER(f"## Rollout [^ref]\n\n[^{label}]: r\n"))[0].text for label in ("ref", "Ref")
        ]
        self.assertEqual(texts[0], texts[1])

    def test_a_reported_link_with_an_entity_shaped_destination_reads_back(self):
        reported = CHECK_TEMPLATE.headings(REAL_RENDER("## [Notice](https://example.org/?a=1&amp;copy;)\n"))[0]
        self.assertEqual(str(CHECK_TEMPLATE.headings(REAL_RENDER(f"{reported}\n"))[0]), str(reported))

    def test_an_authors_link_around_its_own_badge_keeps_its_destination(self):
        texts = {
            CHECK_TEMPLATE.headings(REAL_RENDER(f"## [![Status](/{name}.svg)](/{name}.svg)\n"))[0].text for name in ("build", "status")
        }
        self.assertEqual(len(texts), 2)

    def test_a_reported_heading_with_a_plain_url_stays_plain_where_written_back(self):
        reported = CHECK_TEMPLATE.headings(REAL_RENDER("## https&#58;//example.org and www&#46;example.org\n"))[0]
        self.assertEqual(str(CHECK_TEMPLATE.headings(REAL_RENDER(f"{reported}\n"))[0]), str(reported))

    def test_an_unreadable_source_position_on_a_raw_heading_leaves_no_line(self):
        found = CHECK_TEMPLATE.headings(REAL_RENDER('<h2 data-sourcepos="2-4">Testing</h2>\n'))
        self.assertEqual([(h.text, h.line) for h in found], [("Testing", None)])

    def test_a_non_ascii_footnote_label_compares_in_any_case(self):
        texts = {
            CHECK_TEMPLATE.headings(REAL_RENDER(f"## Rollout [^résumé]\n\n[^{label}]: r\n"))[0].text for label in ("résumé", "RÉSUMÉ")
        }
        self.assertEqual(texts, {"Rollout [^résumé]"})

    def test_adjacent_emphasis_reads_back_as_written(self):
        for heading in ("## _Risk:_**Critical**", "## **Risk:**_Critical_", "## *a* *b*"):
            with self.subTest(heading=heading):
                reported = CHECK_TEMPLATE.headings(REAL_RENDER(heading + "\n"))[0]
                self.assertEqual(str(CHECK_TEMPLATE.headings(REAL_RENDER(f"{reported}\n"))[0]), str(reported))

    def test_an_empty_link_destination_is_still_a_link(self):
        texts = {CHECK_TEMPLATE.headings(REAL_RENDER(heading))[0].text for heading in ("## [Summary]()\n", "## Summary\n")}
        self.assertEqual(len(texts), 2)

    def test_a_template_heading_is_reported_as_written(self):
        template = "## API**v2**_beta_\n\nTitle\n=====\n\n## Done ##\n\n<h2>Raw</h2>\n"
        self.assertEqual(
            [str(h) for h in CHECK_TEMPLATE.parse_template("t.md", template, REAL_RENDER).headings],
            ["## API**v2**_beta_", "# Title", "## Done", "## Raw"],
        )

    def test_a_heading_that_needs_a_definition_elsewhere_is_reported_as_written_and_marked(self):
        template = "## [Docs][doc]\n\n## Plain\n\n## Rollout [^linux|mac]\n\n[doc]: https://example.org/docs\n[^linux|mac]: x\n"
        self.assertEqual(
            [(str(h), h.defined_elsewhere) for h in CHECK_TEMPLATE.parse_template("t.md", template, REAL_RENDER).headings],
            [("## [Docs][doc]", True), ("## Plain", False), ("## Rollout [^linux|mac]", True)],
        )

    def test_spaces_inside_inline_code_are_compared_as_written(self):
        texts = {CHECK_TEMPLATE.headings(REAL_RENDER(heading))[0].text for heading in ("## `foo   bar`\n", "## `foo bar`\n")}
        self.assertEqual(len(texts), 2)

    def test_an_authors_new_tab_link_around_its_image_keeps_its_destination(self):
        texts = {
            CHECK_TEMPLATE.headings(REAL_RENDER(f'## <a target="_blank" href="/{env}.svg"><img src="/{env}.svg" alt="Env"></a>\n'))[0].text
            for env in ("prod", "staging")
        }
        self.assertEqual(len(texts), 2)

    def test_a_heading_whose_footnote_is_defined_elsewhere_says_to_copy_it(self):
        template = CHECK_TEMPLATE.parse_template("t.md", "## Testing[^docs]\n\n-\n\n[^docs]: How we test.\n", REAL_RENDER)
        text = "## Testing[^docs]\n\nRan it.\n"
        body = CHECK_TEMPLATE.standalone(CHECK_TEMPLATE.headings(REAL_RENDER(text), "pr", text), REAL_RENDER)
        [problem] = CHECK_TEMPLATE.compare(template.headings, body)
        self.assertIn("copy that definition", problem["detail"])

    def test_a_setext_heading_ending_in_hashes_is_reported_so_it_reads_back(self):
        [heading] = CHECK_TEMPLATE.parse_template("t.md", "Testing ###\n===========\n", REAL_RENDER).headings
        self.assertEqual((str(heading), heading.defined_elsewhere), ("# Testing \\###", False))
        self.assertEqual(CHECK_TEMPLATE.headings(REAL_RENDER(f"{heading}\n"))[0].text, heading.text)

    def test_reported_headings_read_back_as_the_same_heading(self):
        for template in (
            "Rollout\\\nplan\n=======\n",
            "<h2>Contact helpful@example.com</h2>\n",
            "Run `x  \ny`\n=========\n",
            "<h2>Check<em>!</em></h2>\n",
            "[Docs](/docs) `x  \ny`\n===========\n",
        ):
            with self.subTest(template=template):
                [heading] = CHECK_TEMPLATE.parse_template("t.md", template, REAL_RENDER).headings
                self.assertFalse(heading.defined_elsewhere)
                self.assertEqual(CHECK_TEMPLATE.headings(REAL_RENDER(f"{heading}\n"))[0].text, heading.text)

    def test_a_form_label_keeps_the_spaces_in_its_inline_code(self):
        form = "body:\n  - type: input\n    attributes:\n      label: Run `cmd  arg`\n"
        [label] = CHECK_TEMPLATE.parse_template("f.yml", form, REAL_RENDER).headings
        self.assertEqual(label.text, CHECK_TEMPLATE.headings(REAL_RENDER("### Run `cmd  arg`\n"))[0].text)

    def test_an_attribution_followed_by_blank_blocks_is_no_content(self):
        for after in ("---\n", "<div></div>\n"):
            with self.subTest(after=after):
                body = f"## Related\n\n> [!NOTE]\n> Created on behalf of @someone using Some Model.\n\n{after}"
                self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(REAL_RENDER(body), "issue", body)], [False])

    def test_non_ascii_whitespace_inside_inline_code_is_compared_as_written(self):
        texts = {
            CHECK_TEMPLATE.headings(REAL_RENDER(f"<h2><code>foo{space}bar</code></h2>\n"))[0].text for space in ("&nbsp;", " ")
        }
        self.assertEqual(len(texts), 2)

    def test_a_list_item_showing_brackets_as_code_is_content(self):
        found = CHECK_TEMPLATE.headings(REAL_RENDER("## Steps\n\n- `[ ]`\n"))
        self.assertEqual([h.has_content for h in found], [True])

    def test_a_form_label_is_reported_as_written(self):
        form = "body:\n  - type: input\n    attributes:\n      label: \"***Required***~~optional~~\"\n"
        [heading] = CHECK_TEMPLATE.parse_template("f.yml", form, REAL_RENDER).headings
        self.assertEqual(CHECK_TEMPLATE.headings(REAL_RENDER(f"{heading}\n"))[0].text, heading.text)

    def test_an_empty_picture_is_no_content(self):
        found = CHECK_TEMPLATE.headings(REAL_RENDER("## Evidence\n\n<picture></picture>\n"))
        self.assertEqual([h.has_content for h in found], [False])
        shown = CHECK_TEMPLATE.headings(REAL_RENDER('## Evidence\n\n<picture><img src="/a.png" alt="a"></picture>\n'))
        self.assertEqual([h.has_content for h in shown], [True])

    def test_a_comment_inside_heading_text_does_not_change_it(self):
        texts = {
            CHECK_TEMPLATE.headings(REAL_RENDER(heading))[0].text
            for heading in ("## https&#58;//example.org\n", "## https<!-- guide -->&#58;//example.org\n")
        }
        self.assertEqual(len(texts), 1)

    def test_definition_checks_render_once_for_all_headings(self):
        template = "".join(f"## [Docs {i}][doc]\n\n" for i in range(20)) + "[doc]: https://example.org\n"
        calls = []

        def counting(markdown):
            calls.append(markdown)
            return REAL_RENDER(markdown)

        headings = CHECK_TEMPLATE.parse_template("t.md", template, counting).headings
        self.assertTrue(all(h.defined_elsewhere for h in headings))
        self.assertLessEqual(len(calls), 3)

    def test_a_bracket_placeholder_beside_an_empty_code_block_is_no_content(self):
        found = CHECK_TEMPLATE.headings(REAL_RENDER("## Steps\n\n- [ ]\n\n  ```\n  ```\n"))
        self.assertEqual([h.has_content for h in found], [False])

    def test_an_alias_in_front_matter_reads_as_its_value(self):
        template = CHECK_TEMPLATE.parse_template("t.md", "---\nname: &n Bug\ntitle: *n\n---\n## A\n", REAL_RENDER)
        self.assertEqual((template.name, [str(h) for h in template.headings]), ("Bug", ["## A"]))

    def test_front_matter_that_does_not_load_is_an_error_naming_its_template(self):
        with self.assertRaises(CHECK_TEMPLATE.CheckError) as raised:
            CHECK_TEMPLATE.parse_template("t.md", "---\nname: Bug\ntitle: *missing\n---\n## A\n", REAL_RENDER)
        self.assertEqual(raised.exception.name, "Bug")
    def test_an_authored_alert_class_wrapper_keeps_its_heading(self):
        template = '<div class="markdown-alert">\n\n## Summary\n\n</div>\n'
        self.assertEqual([str(h) for h in CHECK_TEMPLATE.parse_template("t.md", template, REAL_RENDER).headings], ["## Summary"])

    def test_a_comment_in_flow_front_matter_ends_at_its_line(self):
        template = "---\n{about: Report a problem, # chooser text\n name: Bug Report}\n---\n## A\n"
        self.assertEqual(CHECK_TEMPLATE.parse_template("t.md", template, REAL_RENDER).name, "Bug Report")

    def test_deeply_nested_adjacent_emphasis_reads_quickly(self):
        inner = "<strong>x</strong>"
        for _ in range(20):
            inner = f"<strong>y*{inner}y</strong>"  # Each level's deep side follows a literal `*`.
        started = time.monotonic()
        CHECK_TEMPLATE.headings(f"<h2>{inner}</h2>")
        self.assertLess(time.monotonic() - started, 1)

    def test_nonbreaking_spaces_and_destination_spaces_are_compared_as_written(self):
        for pair in (("## A&nbsp;&nbsp;B\n", "## A B\n"), ('<h2><a href="/a  b">x</a></h2>\n', '<h2><a href="/a b">x</a></h2>\n')):
            with self.subTest(pair=pair):
                self.assertEqual(len({CHECK_TEMPLATE.headings(REAL_RENDER(text))[0].text for text in pair}), 2)

    def test_a_bracket_placeholder_in_a_plain_span_is_no_content(self):
        found = CHECK_TEMPLATE.headings(REAL_RENDER("## Steps\n\n- <span>[ ]</span>\n"))
        self.assertEqual([h.has_content for h in found], [False])

    def test_html_github_removes_is_no_content_and_escaped_html_is(self):
        for html, shown in (('<embed src="https://example.org/results.pdf">', False), ("<script>alert(1)</script>", True)):
            with self.subTest(html=html):
                found = CHECK_TEMPLATE.headings(REAL_RENDER(f"## Evidence\n\n{html}\n"))
                self.assertEqual([h.has_content for h in found], [shown])

    def test_a_misplaced_exact_heading_is_out_of_order_not_a_subsection_to_promote(self):
        template = CHECK_TEMPLATE.headings(REAL_RENDER("# Summary\n\n# Testing\n"))
        text = "Summary\n-------\n\nx\n\n# Testing\n\ny\n\n# Summary\n\nz\n"
        problems = CHECK_TEMPLATE.compare(template, CHECK_TEMPLATE.headings(REAL_RENDER(text), "pr", text))
        self.assertEqual([(p["kind"], p["actual"]) for p in problems], [("out-of-order", "# Summary")])

    def test_a_plain_span_does_not_change_adjacent_emphasis(self):
        texts = {CHECK_TEMPLATE.headings(REAL_RENDER(h))[0].text for h in ("## **A**<em>B</em>\n", "## <span>**A**</span><em>B</em>\n")}
        self.assertEqual(len(texts), 1)

    def test_explicit_yaml_keys_are_front_matter(self):
        template = CHECK_TEMPLATE.parse_template("t.md", "---\n? name\n: Bug Report\n---\n## A\n", REAL_RENDER)
        self.assertEqual((template.name, [str(h) for h in template.headings]), ("Bug Report", ["## A"]))

    def test_wrapped_and_unclosed_bracket_placeholders_are_no_content(self):
        for body in ("## Steps\n\n- <div>[ ]</div>\n", "## Steps\n\n<ul><li>[ ]<li>[ ]</ul>\n"):
            with self.subTest(body=body):
                self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(REAL_RENDER(body))], [False])

    def test_text_split_by_a_span_compares_as_one_run(self):
        texts = {CHECK_TEMPLATE.headings(REAL_RENDER(h))[0].text for h in ("## https<span>://example.org</span>\n", "## https:&#47;/example.org\n")}
        self.assertEqual(len(texts), 1)

    def test_a_template_passed_by_path_needs_no_text_name(self):
        template = CHECK_TEMPLATE.parse_template("t.md", "---\nname: [a, b]\n---\n## A\n", REAL_RENDER, need_name=False)
        self.assertEqual((template.name, [str(h) for h in template.headings]), ("t", ["## A"]))
    def test_a_picture_heading_compares_its_responsive_sources(self):
        texts = {
            CHECK_TEMPLATE.headings(REAL_RENDER(
                f'## <picture><source media="(prefers-color-scheme: dark)" srcset="/{dark}.svg"><img src="/light.svg" alt="Build"></picture>\n'
            ))[0].text
            for dark in ("dark", "other")
        }
        self.assertEqual(len(texts), 2)

    def test_a_review_note_inside_details_ends_the_body(self):
        body = "## Testing\n\n<details>\n\n---\n\nEdit: `abc1234` reviewed\n\n</details>\n"
        found = CHECK_TEMPLATE.headings(REAL_RENDER(body), "pr", body, github=False)
        self.assertEqual([h.has_content for h in found], [False])

    def test_a_bare_carriage_return_in_a_live_body_keeps_the_review_note(self):
        saved = CHECK_TEMPLATE.render, CHECK_TEMPLATE.live_body
        CHECK_TEMPLATE.render = REAL_RENDER
        CHECK_TEMPLATE.live_body = lambda kind, number, repo: "## Summary\n\nOne\rtwo.\n\n## Testing\n\n---\n\nEdit: `abc1234` reviewed\n"
        try:
            with tempfile.TemporaryDirectory() as directory:
                template = Path(directory) / "t.md"
                template.write_text("## Summary\n\n-\n\n## Testing\n\n-\n", encoding="utf-8")
                args = CHECK_TEMPLATE.parser().parse_args(["--template", str(template), "--pr", "1", "--repo", "cli/cli"])
                result = CHECK_TEMPLATE.run(args)
        finally:
            CHECK_TEMPLATE.render, CHECK_TEMPLATE.live_body = saved
        self.assertEqual([p["kind"] for p in result["problems"]], ["empty"])

    def test_a_placeholder_list_in_a_nested_quote_is_no_content(self):
        for nested, shown in (("- [ ]", False), ("- Answered", True)):
            with self.subTest(nested=nested):
                found = CHECK_TEMPLATE.headings(REAL_RENDER(f"## Steps\n\n- [ ]\n  > {nested}\n"))
                self.assertEqual([h.has_content for h in found], [shown])

    def test_front_matter_keys_may_be_any_word(self):
        template = CHECK_TEMPLATE.parse_template("t.md", "---\n版本: 2\n---\n## A\n", REAL_RENDER)
        self.assertEqual([str(h) for h in template.headings], ["## A"])

    def test_an_indented_rule_inside_a_front_matter_block_is_its_text(self):
        template = "---\nname: Bug\nabout: |\n  Top\n  ---\n  More detail\n---\n## A\n"
        parsed = CHECK_TEMPLATE.parse_template("t.md", template, REAL_RENDER)
        self.assertEqual((parsed.name, [str(h) for h in parsed.headings]), ("Bug", ["## A"]))

    def test_a_placeholder_list_inside_a_wrapper_is_no_content(self):
        html = "<h2>Steps</h2><ul><li>[ ]<div><ul><li>[ ]</li></ul></div></li></ul>"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(html)], [False])

    def test_the_attribution_inside_a_wrapper_is_no_content(self):
        body = "## Related\n\n<div>\n\n> [!NOTE]\n> Created on behalf of @someone using Some Model.\n\n</div>\n"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(REAL_RENDER(body), "issue", body, github=False)], [False])

    def test_markdown_between_opening_rules_that_is_not_yaml_stays_the_body(self):
        template = CHECK_TEMPLATE.parse_template("t.md", "---\n**Note**: Use this template.\n---\n\n## A\n", REAL_RENDER)
        # Read as GitHub renders it: the closing rule underlines the line above it.
        self.assertEqual([str(h) for h in template.headings], ["## **Note**: Use this template.", "## A"])

    def test_an_explicit_line_break_is_part_of_a_heading(self):
        texts = {CHECK_TEMPLATE.headings(REAL_RENDER(h))[0].text for h in ("## Rollout<br>plan\n", "## Rollout plan\n")}
        self.assertEqual(len(texts), 2)

    def test_yaml_aliases_that_expand_past_the_bound_are_an_error(self):
        lines = ["a0: &a0 [x, x, x, x, x, x, x, x, x, x]"]
        lines += [f"a{n}: &a{n} [{', '.join([f'*a{n - 1}'] * 10)}]" for n in range(1, 7)]
        form = "\n".join([*lines, "body:", "  - type: input", "    attributes: {label: A}", ""])
        with self.assertRaisesRegex(CHECK_TEMPLATE.CheckError, "expands to more than"):
            CHECK_TEMPLATE.form_template("f.yml", form)

    def test_a_setext_hard_break_matches_an_atx_break(self):
        texts = {CHECK_TEMPLATE.headings(REAL_RENDER(h))[0].text for h in ("Rollout\\\nplan\n-------\n", "## Rollout<br>plan\n")}
        self.assertEqual(len(texts), 1)

    def test_yaml_merges_and_self_references_past_the_bound_are_errors(self):
        merges = ["a0: &a0 {k0: x}"] + [f"a{n}: &a{n} {{<<: [*a{n - 1}, *a{n - 1}], k{n}: x}}" for n in range(1, 40)]
        for yaml_text in ("\n".join(merges), "a: &a [*a]"):
            with self.subTest(yaml_text=yaml_text[:30]):
                with self.assertRaises(ValueError):
                    CHECK_TEMPLATE.load_yaml(yaml_text)

    def test_an_indented_broken_front_matter_keeps_its_name(self):
        with self.assertRaises(CHECK_TEMPLATE.CheckError) as raised:
            CHECK_TEMPLATE.parse_template("t.md", "---\n  name: Bug\n  labels: [open\n---\n## A\n", REAL_RENDER)
        self.assertEqual(raised.exception.name, "Bug")

    def test_a_multiline_setext_heading_keeps_its_line_break_as_github_shows_it(self):
        texts = [CHECK_TEMPLATE.headings(REAL_RENDER(h))[0].text for h in ("Deploy\nplan\n------\n", "## Deploy<br>plan\n", "## Deploy plan\n")]
        self.assertEqual((texts[0] == texts[1], texts[0] == texts[2]), (True, False))
        [heading] = CHECK_TEMPLATE.parse_template("t.md", "Deploy\nplan\n------\n", REAL_RENDER).headings
        self.assertEqual(str(heading), "## Deploy<br>plan")

    def test_spaces_just_inside_emphasis_do_not_change_a_heading(self):
        texts = {CHECK_TEMPLATE.headings(REAL_RENDER(h))[0].text for h in ("## <em> Steps </em>\n", "## *Steps*\n")}
        self.assertEqual(len(texts), 1)

    def test_broken_flow_front_matter_is_an_error_naming_its_template(self):
        with self.assertRaises(CHECK_TEMPLATE.CheckError) as raised:
            CHECK_TEMPLATE.parse_template("t.md", "---\n{name: Bug, about: *missing}\n---\n## A\n", REAL_RENDER)
        self.assertEqual(raised.exception.name, "Bug")

    def test_broken_explicit_key_front_matter_is_an_error(self):
        with self.assertRaises(CHECK_TEMPLATE.CheckError):
            CHECK_TEMPLATE.parse_template("t.md", "---\n? name\n: Bug\nabout: [open\n---\n## A\n", REAL_RENDER)

    def test_broken_front_matter_opening_with_an_anchor_or_tag_is_an_error(self):
        for opening in ("&root\nname: Bug", "!!map\nname: Bug", "&root name: Bug", "!<tag:yaml.org,2002:map>\nname: Bug", "&root # metadata\nname: Bug"):
            with self.subTest(opening=opening), self.assertRaises(CHECK_TEMPLATE.CheckError) as raised:
                CHECK_TEMPLATE.parse_template("t.md", f"---\n{opening}\nabout: [open\n---\n## A\n", REAL_RENDER)
            self.assertEqual(raised.exception.name, "Bug")

    def test_broken_front_matter_that_may_merge_its_name_blocks_every_named_check(self):
        self.assertTrue(CHECK_TEMPLATE.may_be_named("t.md", "---\nbase: &b {name: Bug}\n<<: *b\nabout: *missing\n---\n## A\n", "Bug"))

    def test_an_image_between_two_rules_stays_markdown(self):
        text = "---\n![x](y) about: [open\n---\n## A\n"
        self.assertEqual(CHECK_TEMPLATE.front_matter(text), ({}, text))

    def test_an_attribution_quoted_in_code_is_content(self):
        body = "## Related\n\n> [!NOTE]\n> `Created on behalf of @someone using Some Model.`\n"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(REAL_RENDER(body), "issue", body, github=False)], [True])

    def test_a_literal_bang_before_a_link_is_no_image(self):
        texts = {CHECK_TEMPLATE.headings(REAL_RENDER(h))[0].text for h in ("## ![CI](https://example.org/ci.svg)\n", "## \\![CI](https://example.org/ci.svg)\n")}
        self.assertEqual(len(texts), 2)

    def test_placeholders_and_the_attribution_inside_any_wrapper_are_no_content(self):
        html = "<h2>Steps</h2><ul><li>[ ]<section><ul><li>[ ]</li></ul></section></li></ul>"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(html)], [False])
        body = "## Related\n\n<details>\n\n> [!NOTE]\n> Created on behalf of @someone using Some Model.\n\n</details>\n"
        self.assertEqual([h.has_content for h in CHECK_TEMPLATE.headings(REAL_RENDER(body), "issue", body, github=False)], [False])

    def test_a_local_image_compares_by_the_source_it_shows(self):
        texts = {
            CHECK_TEMPLATE.headings(REAL_RENDER(h), github=False)[0].text
            for h in ('## <img src="/staging.svg" data-canonical-src="/production.svg" alt="Env">\n', '## <img src="/production.svg" alt="Env">\n')
        }
        self.assertEqual(len(texts), 2)

    def test_footnote_escapes_that_are_not_utf8_stay_apart(self):
        texts = {
            CHECK_TEMPLATE.headings(REAL_RENDER(f"## Rollout [^{label}]\n\n[^{label}]: r\n"))[0].text for label in ("check%FF", "check%FE")
        }
        self.assertEqual(len(texts), 2)

    def test_footnote_labels_written_with_and_without_percent_escapes_stay_apart(self):
        texts = {
            CHECK_TEMPLATE.headings(REAL_RENDER(f"## Rollout [^{label}]\n\n[^{label}]: r\n"))[0].text for label in ("ref%41", "refA")
        }
        self.assertEqual(len(texts), 2)

    def test_every_reported_heading_reads_back_unless_it_needs_a_definition(self):
        for case, fixture in RENDERED.items():
            for heading in CHECK_TEMPLATE.parse_template("t.md", fixture["markdown"], REAL_RENDER).headings:
                with self.subTest(case=case, heading=str(heading)):
                    shown = CHECK_TEMPLATE.headings(REAL_RENDER(f"{heading}\n"))
                    self.assertTrue(heading.defined_elsewhere or [(h.level, h.text) for h in shown] == [(heading.level, heading.text)])

    def test_every_captured_case_reads_as_github_rendered_it(self):
        for case, fixture in RENDERED.items():
            for kind in (None, "pr", "issue"):
                with self.subTest(case=case, kind=kind):
                    expected = [(h.text, h.has_content) for h in CHECK_TEMPLATE.headings(fixture["html"], kind)]
                    local = [(h.text, h.has_content) for h in CHECK_TEMPLATE.headings(REAL_RENDER(fixture["markdown"]), kind)]
                    self.assertEqual(local, expected)


@needs_renderer
class TemplateParsingTests(unittest.TestCase):
    def test_form_labels_compare_as_github_renders_them(self):
        template = CHECK_TEMPLATE.parse_template(
            "f.yml",
            "body:\n  - type: input\n    attributes:\n      label: Run `--help`\n",
            lambda markdown: mini_render(markdown.replace("`", "")),
        )
        self.assertEqual([(h.text, str(h)) for h in template.headings], [("Run --help", "### Run `--help`")])

    def test_a_name_continues_below_a_comment_after_its_key(self):
        self.assertEqual(CHECK_TEMPLATE.declared_name("name: # shown in the chooser\n  bug-report\nbody:\n"), "bug-report")

    def test_a_form_name_this_reader_cannot_read_is_an_error(self):
        with self.assertRaises(CHECK_TEMPLATE.CheckError) as raised:
            CHECK_TEMPLATE.parse_template("f.yml", 'name: "Bug\nbody:\n  - type: input\n    attributes:\n      label: "A"\n')
        self.assertEqual(raised.exception.name, "")

    def test_a_label_may_continue_on_the_lines_below_its_value(self):
        for label, expected in (
            ("Steps to reproduce the problem\n        on a clean install", "Steps to reproduce the problem on a clean install"),
            ('"Steps: to\n        reproduce"', "Steps: to reproduce"),
        ):
            with self.subTest(label=label):
                form = f"body:\n  - type: input\n    attributes:\n      label: {label}\n      description: x\n"
                self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], [expected])

    def test_a_label_may_start_below_a_comment_after_its_key(self):
        form = "body:\n  - type: input\n    attributes:\n      label: # Shown in the issue\n        Steps to reproduce\n"
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["Steps to reproduce"])

    def test_an_anchored_body_list_is_read(self):
        form = "body: &fields\n  - type: input\n    attributes:\n      label: A\n"
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["A"])

    def test_an_anchored_markdown_type_needs_no_label(self):
        form = "body:\n  - type: &intro markdown\n    attributes:\n      value: Hi\n  - type: input\n    attributes:\n      label: A\n"
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["A"])

    def test_a_quoted_flow_label_may_follow_an_anchor(self):
        form = 'body:\n  - type: input\n    attributes: {label: &title "Repro, expected", description: x}\n'
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["Repro, expected"])

    def test_an_anchor_may_precede_a_block_label_or_flow_attributes(self):
        for attributes in ("\n      label: &title >-\n        Steps to reproduce\n", " &field {label: Steps to reproduce}\n"):
            with self.subTest(attributes=attributes):
                form = f"body:\n  - type: input\n    attributes:{attributes}"
                self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["Steps to reproduce"])

    def test_a_quoted_label_may_continue_on_a_line_starting_with_a_hash(self):
        form = 'body:\n  - type: input\n    attributes:\n      label: "Error seen in the\n        #general channel"\n'
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["Error seen in the #general channel"])

    def test_an_anchored_quoted_label_may_continue_past_a_colon(self):
        form = 'body:\n  - type: input\n    attributes:\n      label: &title "First line\n        continuation: more"\n'
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["First line continuation: more"])

    def test_a_yaml_alias_in_a_form_reads_as_its_value(self):
        form = "body:\n  - type: input\n    attributes: {label: &steps Steps}\n  - type: textarea\n    attributes: {label: *steps}\n"
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["Steps", "Steps"])
    def test_a_markdown_bullet_inside_a_form_value_is_text(self):
        form = (
            "body:\n  - type: markdown\n    attributes:\n      value: |\n        * Note: read this first\n"
            "  - type: input\n    attributes:\n      label: A\n"
        )
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["A"])

    def test_an_escaped_line_break_in_a_quoted_label_joins_its_lines(self):
        form = 'body:\n  - type: input\n    attributes:\n      label: "Steps to re\\\n        produce"\n'
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["Steps to reproduce"])

    def test_a_quoted_type_may_continue_past_an_escaped_line_break(self):
        form = 'body:\n  - type: "mark\\\n      down"\n    attributes:\n      value: Hi\n  - type: input\n    attributes:\n      label: A\n'
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["A"])

    def test_a_plain_form_name_may_continue_below(self):
        self.assertEqual(CHECK_TEMPLATE.declared_name("name: Bug\n  Report\nbody:\n  - type: input\n"), "Bug Report")

    def test_an_ssh_clone_url_names_its_repository(self):
        self.assertEqual(CHECK_TEMPLATE.repository("git@github.com:cli/cli.git"), "github.com/cli/cli")

    def test_a_block_indicator_may_follow_the_label_key_on_its_own_line(self):
        form = "body:\n  - type: input\n    attributes:\n      label:\n        |-\n          Steps\n      description: x\n"
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["Steps"])

    def test_a_label_that_is_not_text_is_an_error(self):
        for label in ("[Expected, Actual]", "{a: b}", "''"):
            with self.subTest(label=label):
                with self.assertRaisesRegex(CHECK_TEMPLATE.CheckError, "label of field 1"):
                    CHECK_TEMPLATE.form_template("f.yml", f"body:\n  - type: input\n    attributes: {{label: {label}}}\n")
    def test_a_form_passed_by_path_needs_no_text_name(self):
        form = "name: [Bug, Report]\nbody:\n  - type: input\n    attributes:\n      label: A\n"
        template = CHECK_TEMPLATE.form_template("f.yml", form, need_name=False)
        self.assertEqual((template.name, [h.text for h in template.headings]), ("f", ["A"]))
        with self.assertRaisesRegex(CHECK_TEMPLATE.CheckError, "name"):
            CHECK_TEMPLATE.form_template("f.yml", form)
    def test_an_indentation_indicator_below_the_label_key_counts_from_the_key(self):
        form = "body:\n  - type: input\n    attributes:\n      label:\n        >2\n        Summary\n"
        self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["Summary"])

    def test_a_block_type_below_its_key_and_a_spaced_name_read_as_yaml_reads_them(self):
        form = (
            'name: "Bug  Report\n  again"\nbody:\n  - type:\n      >-\n      markdown\n    attributes:\n      value: x\n'
            "  - type: input\n    attributes:\n      label: A\n"
        )
        template = CHECK_TEMPLATE.form_template("f.yml", form)
        self.assertEqual((template.name, [h.text for h in template.headings]), ("Bug  Report again", ["A"]))

    def test_a_label_yaml_reads_as_a_date_is_an_error(self):
        form = "body:\n  - type: input\n    attributes:\n      label: 2025-11-20T10:30:00Z\n"
        with self.assertRaisesRegex(CHECK_TEMPLATE.CheckError, "label of field 1"):
            CHECK_TEMPLATE.form_template("f.yml", form)

    def test_a_broken_form_after_a_document_marker_keeps_its_indented_name(self):
        self.assertEqual(CHECK_TEMPLATE.declared_name("---\n  name: Legacy\n  body: [unclosed\n"), "Legacy")

    def test_a_broken_flow_form_keeps_its_name(self):
        form = "{name: Legacy, body: [{type: input, attributes: {label: *missing}}]}\n"
        self.assertEqual(CHECK_TEMPLATE.declared_name(form), "Legacy")

    def test_a_broken_flow_form_ignores_a_commented_name(self):
        form = "{\n  # name: Legacy\n  name: Bug,\n  body: [*missing]\n}\n"
        self.assertEqual(CHECK_TEMPLATE.declared_name(form), "Bug")

    def test_a_commented_document_marker_does_not_hide_an_indented_name(self):
        self.assertEqual(CHECK_TEMPLATE.declared_name("--- # form\n  name: Legacy\n  body: [unclosed\n"), "Legacy")

    def test_aliases_repeating_long_text_past_the_bound_are_an_error(self):
        text = "a: &a '" + "x" * 1000 + "'\nb: [" + ", ".join(["*a"] * 2000) + "]\n"
        with self.assertRaisesRegex(ValueError, "expands to more than"):
            CHECK_TEMPLATE.load_yaml(text)

    def test_a_form_with_a_disallowed_character_keeps_its_name(self):
        self.assertEqual(CHECK_TEMPLATE.declared_name("name: Legacy\nbody: \x07\n"), "Legacy")

    def test_a_broken_flow_form_after_a_preamble_keeps_its_name(self):
        self.assertEqual(CHECK_TEMPLATE.declared_name("---\n# form\n{name: Legacy, body: [*missing]}\n"), "Legacy")

    def test_flow_name_recovery_honors_escaped_quotes(self):
        form = '{description: "say \\", name: Other, \\"", name: Bug, body: [*missing]}\n'
        self.assertEqual(CHECK_TEMPLATE.declared_name(form), "Bug")

    def test_an_explicit_name_key_is_recovered_from_broken_yaml(self):
        self.assertEqual(CHECK_TEMPLATE.declared_name("? name\n: Other\nabout: [open\n"), "Other")

    def test_a_quoted_name_key_is_recovered_from_a_broken_flow_form(self):
        self.assertEqual(CHECK_TEMPLATE.declared_name('{"name":"Broken","body":[}\n'), "Broken")

    def test_a_broken_form_names_only_what_its_root_mapping_declares(self):
        cases = {
            "{description: tracking name:Legacy, name: Bug, body: [*missing]}\n": "Bug",
            "? name # shown in the chooser\n: Other\nabout: [open\n": "Other",
            "description: |\n  name: Legacy\nname: Bug\nbody: [open\n": "Bug",
            "name: Bug\nname: Other\nbody: [open\n": None,
            'name: Other\nname: "Bug\n': None,
            "name: Other\nname: [Bug\n": None,
            "&key name: Legacy\n*key : Bug\nbody: [open\n": None,
            "n: &k name\n*k : Bug\nbody: [open\n": "Bug",
            "base: &b {name: Bug}\n<<: *b\nbody: *missing\n": None,
            "<<: {name: Other}\nname: Bug\nbody: [open\n": "Bug",
            "name: B\x07ug\n": None,
            "body: [*missing]\nname: Legacy\n": "Legacy",
            "name: [Bug]\nbody: [open\n": None,
            "body: [open\nname: Bug\n": None,
        }
        for form, name in cases.items():
            with self.subTest(form=form):
                self.assertEqual(CHECK_TEMPLATE.declared_name(form), name)

    def test_a_form_body_that_is_not_a_list_is_an_error(self):
        for body in ("false", "0", "{}", "''"):
            with self.subTest(body=body), self.assertRaisesRegex(CHECK_TEMPLATE.CheckError, "body is not a list"):
                CHECK_TEMPLATE.form_template("f.yml", f"name: Bug\nbody: {body}\n")

    def test_the_uv_reader_reads_yaml_as_this_process_does(self):
        # The program uv runs, here on this Python, which has PyYAML installed.
        script = str(Path(CHECK_TEMPLATE.__file__).resolve())
        for text in ("name: Bug\nbody: [a, 1, 2025-01-01]\n", "name: Bug\nbody: [open\n", "a: &a [*a]\n", "name: Legacy\nbody: \x07\n"):
            with self.subTest(text=text):
                completed = subprocess.run(
                    [sys.executable, "-I", "-c", CHECK_TEMPLATE.LOAD, script], input=text.encode("utf-8"),
                    capture_output=True, check=True, cwd=tempfile.gettempdir(),
                )
                self.assertEqual(json.loads(completed.stdout), CHECK_TEMPLATE.read_yaml(text))

    def test_a_quoted_form_name_may_wrap_onto_the_lines_below(self):
        for quote in ('"', "'"):
            with self.subTest(quote=quote):
                form = f"name: {quote}Bug\n  report{quote}\nbody:\n  - type: input\n    attributes:\n      label: A\n"
                self.assertEqual(CHECK_TEMPLATE.parse_template("f.yml", form).name, "Bug report")

    def test_a_type_given_as_a_block_scalar_is_read(self):
        template = CHECK_TEMPLATE.parse_template(
            "f.yml",
            "body:\n  - type: >-\n      markdown\n    attributes:\n      value: hi\n"
            "  - type: input\n    attributes:\n      label: A\n",
        )
        self.assertEqual([str(h) for h in template.headings], ["### A"])

    def test_a_comment_after_a_type_key_leaves_it_to_continue_below(self):
        template = CHECK_TEMPLATE.parse_template(
            "f.yml",
            "body:\n  - type: # explanation\n      markdown\n    attributes:\n      value: hi\n"
            "  - type: input\n    attributes:\n      label: A\n",
        )
        self.assertEqual([str(h) for h in template.headings], ["### A"])

    def test_front_matter_may_be_indented_or_one_flow_mapping(self):
        for front in ("{name: Bug report, about: Report a bug}", "  name: Bug report\n  about: Report a bug"):
            with self.subTest(front=front):
                template = CHECK_TEMPLATE.parse_template("bug.md", f"---\n{front}\n---\n## Summary\n")
                self.assertEqual((template.name, [str(h) for h in template.headings]), ("Bug report", ["## Summary"]))

    def test_a_flow_key_needs_a_space_after_its_colon(self):
        with self.assertRaises(CHECK_TEMPLATE.CheckError):
            CHECK_TEMPLATE.parse_template("f.yml", "body:\n  - type: input\n    attributes: {label:Summary}\n")

    def test_a_name_type_or_label_may_continue_below_its_key(self):
        template = CHECK_TEMPLATE.parse_template(
            "f.yml",
            "name:\n  bug-report\nbody:\n  - type:\n      markdown\n    attributes:\n      value: hi\n"
            "  - type: input\n    attributes:\n      label:\n        Steps\n",
        )
        self.assertEqual((template.name, [str(h) for h in template.headings]), ("bug-report", ["### Steps"]))

    def test_issue_form_reads_flow_attributes_and_rejects_an_unreadable_field(self):
        form = "\n".join([
            "body:",
            "  - type: textarea",
            "    attributes:",
            "      label: What happened",
            "  - type: textarea",
            "    attributes: {label: 'Steps to reproduce', description: How}",
        ])
        template = CHECK_TEMPLATE.parse_template("form.yml", form)
        self.assertEqual([str(h) for h in template.headings], ["### What happened", "### Steps to reproduce"])
        with self.assertRaisesRegex(CHECK_TEMPLATE.CheckError, "field 2"):
            CHECK_TEMPLATE.parse_template("form.yml", form.replace("{label: 'Steps to reproduce', description: How}", "[odd]"))
    def test_an_opening_rule_over_markdown_is_not_front_matter(self):
        template = CHECK_TEMPLATE.parse_template("pull_request_template.md", "---\n\n## Summary\n\n-\n\n---\n\nMore.\n")
        self.assertEqual([str(h) for h in template.headings], ["## Summary"])

    def test_flow_attributes_read_the_label_key_not_text_inside_another_value(self):
        template = CHECK_TEMPLATE.parse_template(
            "form.yml",
            'body:\n  - type: textarea\n    attributes: {description: "Choose a value, label: example", label: Steps}\n',
        )
        self.assertEqual([str(h) for h in template.headings], ["### Steps"])

    def test_issue_form_keys_may_be_quoted_and_its_name_may_follow_the_body(self):
        form = 'body:\n  - "type": markdown\n    attributes:\n      value: hi\n  - type: input\n    attributes:\n      label: A\nname: Late\n'
        template = CHECK_TEMPLATE.parse_template("form.yml", form)
        self.assertEqual((template.name, [str(h) for h in template.headings]), ("Late", ["### A"]))
        with self.assertRaises(CHECK_TEMPLATE.CheckError) as raised:
            CHECK_TEMPLATE.parse_template("form.yml", form.replace("value: hi", "value: hi\n  - type: input\n    attributes: [odd]"))
        self.assertEqual(raised.exception.name, "Late")

    def test_front_matter_may_end_its_yaml_document_with_dots(self):
        self.assertEqual(CHECK_TEMPLATE.parse_template("x.md", "---\nname: Bug\n...\n---\n## A\n").name, "Bug")

    def test_front_matter_may_close_a_flow_list_at_the_margin(self):
        self.assertEqual(CHECK_TEMPLATE.parse_template("x.md", "---\nname: Bug\nlabels: [\n  bug,\n]\n---\n## A\n").name, "Bug")

    def test_a_form_field_dash_may_stand_alone_above_its_mapping(self):
        form = "body:\n  -\n    type: textarea\n    attributes:\n      label: Summary\n  - type: input\n    attributes: {label: Steps}\n"
        self.assertEqual(
            [str(h) for h in CHECK_TEMPLATE.parse_template("form.yml", form).headings], ["### Summary", "### Steps"]
        )
        deeper = form.replace("    type: textarea\n    attributes:\n      label", "      type: textarea\n      attributes:\n        label")
        self.assertEqual(
            [str(h) for h in CHECK_TEMPLATE.parse_template("form.yml", deeper).headings], ["### Summary", "### Steps"]
        )

    def test_a_comment_may_follow_inline_form_attributes(self):
        template = CHECK_TEMPLATE.parse_template(
            "form.yml", "body:\n  - type: input\n    attributes: {label: 'C# guide'} # Required entry\n"
        )
        self.assertEqual([str(h) for h in template.headings], ["### C# guide"])

    def test_front_matter_may_put_a_sequence_dash_on_its_own_line(self):
        self.assertEqual(
            CHECK_TEMPLATE.parse_template("x.md", "---\nname: Bug Report\nlabels:\n-\n  bug\n---\n## A\n").name, "Bug Report"
        )

    def test_the_yaml_end_marker_may_carry_a_comment(self):
        self.assertEqual(CHECK_TEMPLATE.parse_template("x.md", "---\nname: Bug\n... # end\n---\n## A\n").name, "Bug")

    def test_front_matter_keys_may_contain_spaces(self):
        template = CHECK_TEMPLATE.parse_template("x.md", "---\nname: Bug Report\ncustom display: ignored\n---\n## A\n")
        self.assertEqual(template.name, "Bug Report")

    def test_a_folded_form_name_names_the_form_and_its_errors(self):
        with self.assertRaises(CHECK_TEMPLATE.CheckError) as raised:
            CHECK_TEMPLATE.parse_template("report.yml", "name: >-\n  Bug\nbody:\n  - type: input\n    attributes: [odd]\n")
        self.assertEqual(raised.exception.name, "Bug")

    def test_front_matter_with_a_wrapped_value_keeps_its_name(self):
        template = CHECK_TEMPLATE.parse_template("x.md", "---\nname: Bug Report\nabout: 'Tell us\nwhat broke'\n---\n## A\n")
        self.assertEqual(template.name, "Bug Report")

    def test_a_form_written_as_one_flow_mapping_keeps_its_name(self):
        self.assertEqual(
            CHECK_TEMPLATE.declared_name("{name: bug-report, body: [{type: input, attributes: {label: A}}]}\n"), "bug-report"
        )

    def test_a_field_key_column_follows_the_padding_after_its_dash(self):
        template = CHECK_TEMPLATE.parse_template("f.yml", "body:\n  -   type: input\n      attributes:\n        label: A\n")
        self.assertEqual([str(h) for h in template.headings], ["### A"])

    def test_a_field_whose_dash_is_followed_by_a_tab_is_never_skipped(self):
        with self.assertRaises(CHECK_TEMPLATE.CheckError):
            CHECK_TEMPLATE.parse_template(
                "f.yml", "body:\n  - type: input\n    attributes: {label: A}\n  -\t{type: input, attributes: {label: B}}\n"
            )

    def test_a_comment_only_dash_takes_its_key_column_from_the_first_key(self):
        form = "body:\n  -  # instructions\n    type: markdown\n    attributes:\n      value: hi\n  - type: input\n    attributes:\n      label: A\n"
        self.assertEqual([str(h) for h in CHECK_TEMPLATE.parse_template("f.yml", form).headings], ["### A"])

    def test_a_comment_with_a_colon_on_a_dash_line_is_not_a_key(self):
        form = "body:\n  -  # Overview: context\n    type: input\n    attributes:\n      label: A\n"
        self.assertEqual([str(h) for h in CHECK_TEMPLATE.parse_template("f.yml", form).headings], ["### A"])

    def test_yaml_that_does_not_load_is_an_error(self):
        for attributes in ("{label: Steps, description: [unfinished}}", '{label: "\\UFFFFFFFF"}'):
            with self.subTest(attributes=attributes):
                with self.assertRaisesRegex(CHECK_TEMPLATE.CheckError, "cannot read the issue form"):
                    CHECK_TEMPLATE.form_template("f.yml", f"body:\n  - type: input\n    attributes: {attributes}\n")

    def test_labels_read_as_yaml_reads_them_in_any_style(self):
        cases = {
            "{label: Use ':' in code}": "Use ':' in code",
            '{"label":"Steps, logs"}': "Steps, logs",
            '{options: ["] , label: Wrong, ]"], label: Correct}': "Correct",
            "{label: What's wrong, description: Details}": "What's wrong",
            "{label: 'It''s, ok', description: x}": "It's, ok",
            '{label: "OS \\x28optional\\x29"}': "OS (optional)",
            '{label: "Before\\_after"}': "Before\xa0after",
            "{\n      label: Steps to\n      reproduce }": "Steps to reproduce",
            "\n      {\n        label: Version,\n        description: x }": "Version",
            "{label: Terms, options: [{label: I agree}\n      ]}": "Terms",
        }
        for attributes, label in cases.items():
            with self.subTest(attributes=attributes):
                form = f"body:\n  - type: input\n    attributes: {attributes}\n"
                self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], [label])
        for form in ('body: [{"type": "input", "attributes": {"label": "Report"}}]\n', "body:\n  - {type: input,\n    attributes: {label: Report}\n    }\n"):
            with self.subTest(form=form):
                self.assertEqual([h.text for h in CHECK_TEMPLATE.form_template("f.yml", form).headings], ["Report"])
    def test_a_bracket_line_inside_a_block_value_is_text(self):
        form = "body:\n  - type: markdown\n    attributes:\n      value: |\n        [Read the guide](https://example.org/guide)\n  - type: input\n    attributes:\n      label: A\n"
        self.assertEqual([str(h) for h in CHECK_TEMPLATE.parse_template("f.yml", form).headings], ["### A"])

    def test_issue_form_fields_become_level_three_headings(self):
        template = CHECK_TEMPLATE.parse_template("bug.yml", BUG_FORM)

        self.assertEqual(template.name, "Bug report")
        self.assertEqual(
            [str(heading) for heading in template.headings],
            ["### Version", "### Steps to reproduce", "### Checks"],
        )

    def test_issue_form_layouts_and_label_styles(self):
        template = CHECK_TEMPLATE.parse_template(
            "bug.yaml",
            "\n".join([
                "name: 'It''s a form'",
                "body:",
                "- type: input",
                "  attributes:",
                "    label: \"Version: \\\"exact\\\"\" # quoted, with a comment",
                "- type: textarea",
                "  attributes:",
                "    label: >-",
                "      Steps to",
                "      reproduce",
                "    description: Folded label above",
                "- type: textarea",
                "  attributes:",
                "    label: Logs # plain, with a comment",
                "- type: textarea",
                "  attributes:",
                "    label: |2-",
                "        # Hash",
                "      line",
                "# A comment between fields",
                "- type: input",
                "  attributes:",
                "    label: After the comment",
            ]),
        )

        self.assertEqual(template.name, "It's a form")
        self.assertEqual(
            [str(heading) for heading in template.headings],
            ['### Version: "exact"', "### Steps to reproduce", "### Logs", "### # Hash line", "### After the comment"],
        )

    def test_byte_order_mark_does_not_hide_the_first_heading(self):
        template = CHECK_TEMPLATE.parse_template("bom.md", "\ufeff## Summary\n")

        self.assertEqual([str(heading) for heading in template.headings], ["## Summary"])

    def test_markdown_template_front_matter_names_it(self):
        template = CHECK_TEMPLATE.parse_template("default.md", ISSUE_TEMPLATE)

        self.assertEqual(template.name, "Issue")
        self.assertEqual(len(template.headings), 5)


class CompareTests(unittest.TestCase):
    def compare(self, sections):
        # The template's own headings, past its front matter, so comparing needs no YAML reader.
        expected = md_headings(ISSUE_TEMPLATE.split("\n---\n", 1)[1])
        return [
            (problem["kind"], problem["expected"], problem["actual"])
            for problem in CHECK_TEMPLATE.compare(expected, md_headings(body(*sections)))
        ]

    def test_matching_body_with_extra_subsections_has_no_problems(self):
        sections = [*FULL[:2], ("### Detail", "More."), *FULL[2:]]

        self.assertEqual(self.compare(sections), [])

    def test_dropped_and_prose_only_bodies_report_missing_headings(self):
        self.assertEqual(
            self.compare([FULL[0], FULL[1], FULL[3]]),
            [
                ("missing", "## Current behavior", None),
                ("missing", "## Scope notes", None),
            ],
        )
        self.assertEqual(
            [kind for kind, _, _ in self.compare([("Plain prose.", "")])],
            ["missing"] * 5,
        )

    def test_renamed_headings_pair_with_their_closest_wording(self):
        # Seen in practice: "Expected" and "Notes" replaced two later headings,
        # and two earlier ones were dropped.
        self.assertEqual(
            self.compare([FULL[0], ("## Expected", "A flag."), ("## Notes", "None.")]),
            [
                ("missing", "## Why", None),
                ("missing", "## Current behavior", None),
                ("renamed", "## Expected behavior", "## Expected"),
                ("renamed", "## Scope notes", "## Notes"),
            ],
        )

    def test_case_level_and_wholesale_renames_are_renames(self):
        self.assertEqual(
            self.compare([
                ("## summary", "Add the flag."),
                ("### Why", "Users asked."),
                ("## Motivation and context", "No flag."),
                *FULL[3:],
            ]),
            [
                ("renamed", "## Summary", "## summary"),
                ("renamed", "## Why", "### Why"),
                ("renamed", "## Current behavior", "## Motivation and context"),
            ],
        )

    def test_moved_heading_is_out_of_order(self):
        self.assertEqual(
            self.compare([FULL[0], FULL[2], FULL[1], *FULL[3:]]),
            [("out-of-order", "## Why", "## Why")],
        )

    def test_heading_with_nothing_under_it_is_empty(self):
        self.assertEqual(
            self.compare([*FULL[:4], ("## Scope notes", "<!-- nothing -->")]),
            [("empty", "## Scope notes", "## Scope notes")],
        )

    def test_subsection_named_like_a_later_section_does_not_take_its_place(self):
        self.assertEqual(
            self.compare([*FULL[:4], ("### Scope notes", "A subsection."), FULL[4]]),
            [],
        )
        self.assertEqual(
            self.compare([*FULL[:4], ("### Scope notes", "None.")]),
            [("renamed", "## Scope notes", "### Scope notes")],
        )


class SelectTests(unittest.TestCase):
    def test_body_missing_a_heading_still_selects_the_template_it_follows(self):
        smaller = CHECK_TEMPLATE.parse_template("small.md", "## Summary\n\n## Testing\n")
        larger = CHECK_TEMPLATE.parse_template("large.md", "## Summary\n\n## Why\n\n## Testing\n\n## Notes\n")
        found = md_headings(body(("## Summary", "A."), ("## Why", "B."), ("## Testing", "C.")))

        template, problems = CHECK_TEMPLATE.select([smaller, larger], found, None)

        self.assertEqual(template.path, "large.md")
        self.assertEqual([(problem["kind"], problem["expected"]) for problem in problems], [("missing", "## Notes")])


    def test_a_same_level_preference_does_not_shrink_the_kept_headings(self):
        larger = CHECK_TEMPLATE.Template("larger.md", "larger", md_headings("## Summary\n## Rationale\n## Testing\n## Scope\n"))
        smaller = CHECK_TEMPLATE.Template("smaller.md", "smaller", md_headings("## Testing\n## Scope\n"))
        found = md_headings("## Testing\nx\n## Scope\nx\n### Summary\nx\n### Rationale\nx\n### Testing\nx\n")

        template, problems = CHECK_TEMPLATE.select([larger, smaller], found, None)

        self.assertEqual(template.name, "larger")
        self.assertTrue(problems)


@needs_renderer
class CommandTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.scenario = self.root / "gh.json"
        self.scenario.write_text("{}", encoding="utf-8")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "FAKE_GH_SCENARIO": str(self.scenario),
            # Keep git from finding a checkout above a temporary directory.
            "GIT_CEILING_DIRECTORIES": str(self.root.parent),
        }
        for key in ("GH_HOST", "GH_REPO"):
            self.env.pop(key, None)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()

    def tearDown(self):
        self.directory.cleanup()

    def write(self, relative, text):
        path = self.checkout / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def run_check(self, *args, stdin=None, cwd=None):
        result = subprocess.run(
            [sys.executable, str(SCRIPT_PATH), *args, "--json"],
            cwd=cwd or self.root,
            env=self.env,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=60,
        )
        return result.returncode, json.loads(result.stdout)

    def test_exit_status_follows_the_comparison(self):
        template = self.write("template.md", ISSUE_TEMPLATE)
        matching = self.write("matching.md", body(*FULL))

        code, result = self.run_check("--template", str(template), "--body", str(matching))
        self.assertEqual((code, result["state"]), (0, "match"))

        code, result = self.run_check("--template", str(template), "--body", "-", stdin="Prose only.\n")
        self.assertEqual((code, result["state"], len(result["problems"])), (1, "mismatch", 5))

        code, result = self.run_check("--template", str(self.checkout / "absent.md"), "--body", str(matching))
        self.assertEqual((code, result["state"]), (2, "operational-error"))

    def test_discovery_picks_among_several_issue_templates(self):
        self.write(".github/ISSUE_TEMPLATE/default.md", ISSUE_TEMPLATE)
        self.write(".github/ISSUE_TEMPLATE/bug.yml", BUG_FORM)
        self.write(".github/ISSUE_TEMPLATE/config.yml", "blank_issues_enabled: false\n")
        form_body = body(("### Version", "1.2.3"), ("### Steps to reproduce", "Run it."), ("### Checks", "- [x] Searched"))
        common = ("--root", str(self.checkout), "--kind", "issue", "--body", "-")

        code, result = self.run_check(*common, stdin=form_body)
        self.assertEqual((code, result["template"]["name"]), (0, "Bug report"))

        code, result = self.run_check(*common, "--template-name", "Issue", stdin=form_body)
        self.assertEqual((code, result["template"]["name"], len(result["problems"])), (1, "Issue", 5))

        code, result = self.run_check(*common, "--template-name", "absent", stdin=form_body)
        self.assertEqual((code, result["state"]), (2, "operational-error"))

    def test_checkout_without_a_template_has_nothing_to_compare(self):
        code, result = self.run_check("--root", str(self.checkout), "--kind", "pr", "--body", "-", stdin="Prose.\n")
        self.assertEqual((code, result["state"]), (0, "no-template"))

        prose = self.write("prose.md", "A template without headings.\n")
        code, result = self.run_check("--template", str(prose), "--body", "-", stdin="Prose.\n")
        self.assertEqual((code, result["state"]), (0, "no-template"))

    def test_a_named_template_without_headings_says_so(self):
        self.write(".github/ISSUE_TEMPLATE/default.md", ISSUE_TEMPLATE)
        self.write(".github/ISSUE_TEMPLATE/plain.md", "---\nname: Plain\nabout: x\n---\nWrite anything.\n")
        code, result = self.run_check(
            "--root", str(self.checkout), "--kind", "issue", "--template-name", "Plain", "--body", "-", stdin="Prose.\n"
        )
        self.assertEqual((code, result["state"], result["reason"]), (0, "no-template", "the issue template named Plain has no headings"))

    def test_a_raw_html_template_heading_compares_as_rendered_locally(self):
        heading = '<h2><a target="_blank" href="/build.svg"><img src="/build.svg" alt="Build"></a></h2>\n'
        template = self.write("template.md", heading)
        code, result = self.run_check("--template", str(template), "--body", "-", stdin=f"{heading}\nIt builds.\n")
        self.assertEqual((code, result["state"]), (0, "match"))

    def test_a_form_named_by_an_alias_blocks_a_named_check(self):
        self.write(".github/ISSUE_TEMPLATE/bad.yml", "name: *display\nbody:\n  - type: input\n    attributes:\n      label: A\n")
        self.write(".github/ISSUE_TEMPLATE/report.md", "---\nname: report\nabout: x\n---\n## Summary\n")
        code, result = self.run_check(
            "--root", str(self.checkout), "--kind", "issue", "--template-name", "report", "--body", "-", stdin="## Summary\n\nx\n"
        )
        self.assertEqual((code, result["state"]), (2, "operational-error"))

    def test_an_undecodable_field_the_check_does_not_use_blocks_nothing(self):
        self.write(".github/ISSUE_TEMPLATE/other.md", '---\n  name: Other\n  about: "\\UFFFFFFFF"\n---\n## Other\n')
        self.write(".github/ISSUE_TEMPLATE/bug.md", "---\nname: Bug\n---\n## Summary\n\n-\n")
        code, result = self.run_check(
            "--root", str(self.checkout), "--kind", "issue", "--body", "-", "--template-name", "Bug", stdin="## Summary\n\nText.\n"
        )
        self.assertEqual((code, result["state"]), (0, "match"))

    def test_a_form_passed_by_path_checks_an_issue_body(self):
        template = self.write("form.yml", "name: Bug\nbody:\n  - type: textarea\n    attributes:\n      label: A\n")
        body = "### A\n\n> [!NOTE]\n> Created on behalf of @someone using Some Model.\n"
        code, result = self.run_check("--template", str(template), "--body", "-", stdin=body)
        self.assertEqual((code, [p["kind"] for p in result["problems"]]), (1, ["empty"]))

    def test_a_check_that_cannot_run_is_an_operational_error(self):
        undecodable = self.root / "latin1.md"
        undecodable.write_bytes("## Caf\xe9\n".encode("latin-1"))
        template = self.write("template.md", ISSUE_TEMPLATE)
        for name, args in (
            ("undecodable body", ("--template", str(template), "--body", str(undecodable))),
            ("outside a git checkout", ("--kind", "pr", "--body", "-")),
            ("unreachable repository", ("--repo", "owner/absent", "--kind", "pr", "--body", "-")),
        ):
            with self.subTest(name):
                code, result = self.run_check(*args, stdin="## Summary\n")
                self.assertEqual((code, result["state"]), (2, "operational-error"))

    def test_a_named_template_is_checked_when_another_cannot_be_read(self):
        self.write(".github/ISSUE_TEMPLATE/default.md", ISSUE_TEMPLATE)
        self.write(".github/ISSUE_TEMPLATE/odd.yml", "name: Odd\nbody: [{type: input, attributes: {label: A}}\n")
        common = ("--root", str(self.checkout), "--kind", "issue", "--body", "-")

        code, result = self.run_check(*common, "--template-name", "Issue", stdin=body(*FULL))
        self.assertEqual((code, result["state"]), (0, "match"))

        for name in ((), ("--template-name", "odd")):
            with self.subTest(name=name):
                code, result = self.run_check(*common, *name, stdin=body(*FULL))
                self.assertEqual((code, result["state"]), (2, "operational-error"))
                self.assertIn("odd.yml", result["reason"])

    def test_a_root_that_is_not_a_directory_is_an_operational_error(self):
        for root in (self.checkout / "absent", self.write("file.md", "## Summary\n")):
            with self.subTest(root=root.name):
                code, result = self.run_check("--root", str(root), "--kind", "pr", "--body", "-", stdin="## Summary\n")
                self.assertEqual((code, result["state"]), (2, "operational-error"))

    def test_an_explicit_template_without_a_kind_reads_the_body_as_a_pull_request(self):
        template = self.write("template.md", "## Testing\n\nx\n")
        code, result = self.run_check("--template", str(template), "--body", "-", stdin="## Testing\n\n---\n\nEdit: `abc1234` reviewed\n")
        self.assertEqual((code, result["state"]), (1, "mismatch"))

    def test_an_unreadable_form_is_needed_when_its_declared_name_is_chosen(self):
        self.write(".github/ISSUE_TEMPLATE/report.yml", "name: bug-report\nbody:\n  - type: textarea\n    attributes: [odd]\n")
        self.write(".github/ISSUE_TEMPLATE/bug-report.md", "---\nname: Other\n---\n## Summary\n\n-\n")
        code, result = self.run_check(
            "--root", str(self.checkout), "--kind", "issue", "--body", "-", "--template-name", "bug-report",
            stdin="## Summary\n\nText.\n",
        )
        self.assertEqual((code, result["state"]), (2, "operational-error"))
        self.assertIn("report.yml", result["reason"])

    def test_a_template_that_cannot_be_decoded_blocks_every_check(self):
        # Its declared name cannot be read, so it may be the template named.
        self.write(".github/ISSUE_TEMPLATE/default.md", ISSUE_TEMPLATE)
        (self.checkout / ".github/ISSUE_TEMPLATE/other.md").write_bytes(b"\xff\xfe")
        common = ("--root", str(self.checkout), "--kind", "issue", "--body", "-")
        for name in ((), ("--template-name", "Issue")):
            with self.subTest(name=name):
                code, result = self.run_check(*common, *name, stdin=body(*FULL))
                self.assertEqual((code, result["state"]), (2, "operational-error"))
                self.assertIn("other.md", result["reason"])

    def test_a_template_with_an_invalid_escape_blocks_only_a_check_that_needs_it(self):
        self.write(".github/ISSUE_TEMPLATE/default.md", ISSUE_TEMPLATE)
        self.write(".github/ISSUE_TEMPLATE/odd.yml", 'name: Odd\nbody:\n  - type: input\n    attributes: {label: "\\UFFFFFFFF"}\n')
        code, result = self.run_check(
            "--root", str(self.checkout), "--kind", "issue", "--body", "-", "--template-name", "Issue", stdin=body(*FULL)
        )
        self.assertEqual((code, result["state"]), (0, "match"))

    def test_a_named_check_needs_a_broken_form_whose_name_hides_in_another_value(self):
        self.write(".github/ISSUE_TEMPLATE/broken.yml", "{description: tracking name:Legacy, name: Bug, body: [*missing]}\n")
        self.write(".github/ISSUE_TEMPLATE/bug.md", "---\nname: Bug\n---\n## Summary\n\n-\n")
        code, result = self.run_check(
            "--root", str(self.checkout), "--kind", "issue", "--body", "-", "--template-name", "Bug", stdin="## Summary\n\nText.\n"
        )
        self.assertEqual((code, result["state"]), (2, "operational-error"))
        self.assertIn("broken.yml", result["reason"])

    def test_a_form_that_fails_to_parse_keeps_its_declared_name(self):
        self.write(".github/ISSUE_TEMPLATE/form.yml", 'name: Bug report\nbody:\n  - type: input\n    attributes: {label: "\\UFFFFFFFF"}\n')
        self.write(".github/ISSUE_TEMPLATE/bug.md", "---\nname: Bug report\n---\n## Summary\n\n-\n")
        code, result = self.run_check(
            "--root", str(self.checkout), "--kind", "issue", "--body", "-", "--template-name", "Bug report",
            stdin="## Summary\n\nText.\n",
        )
        self.assertEqual((code, result["state"]), (2, "operational-error"))
        self.assertIn("form.yml", result["reason"])

    def test_a_failing_template_keeps_its_declared_name(self):
        for failing in (
            (".github/ISSUE_TEMPLATE/form.yml", '\ufeffname: Bug report\nbody:\n  - type: input\n    attributes: {label: "\\UFFFFFFFF"}\n'),
        ):
            with self.subTest(failing=failing[0]):
                self.directory.cleanup()
                self.setUp()
                self.write(*failing)
                self.write(".github/ISSUE_TEMPLATE/bug.md", "---\nname: Bug report\n---\n## Summary\n\n-\n")
                code, result = self.run_check(
                    "--root", str(self.checkout), "--kind", "issue", "--body", "-", "--template-name", "Bug report",
                    stdin="## Summary\n\nText.\n",
                )
                self.assertEqual((code, result["state"]), (2, "operational-error"))

    def test_a_failing_form_whose_name_cannot_be_read_blocks_a_named_check(self):
        self.write(".github/ISSUE_TEMPLATE/report.yml", 'name: "\\U00110000"\nbody:\n  - type: input\n    attributes: [odd]\n')
        self.write(".github/ISSUE_TEMPLATE/bug.md", "---\nname: Bug report\n---\n## Summary\n\n-\n")
        code, result = self.run_check(
            "--root", str(self.checkout), "--kind", "issue", "--body", "-", "--template-name", "Bug report",
            stdin="## Summary\n\nText.\n",
        )
        self.assertEqual((code, result["state"]), (2, "operational-error"))
        self.assertIn("report.yml", result["reason"])

    def test_a_host_qualified_repository_discovers_templates_on_its_host(self):
        route = "api --hostname ghe.example.com"
        listing = lambda *names: json.dumps([{"name": name, "type": kind} for name, kind in names])
        self.scenario.write_text(json.dumps({
            f"{route} repos/cli/cli/contents": listing((".github", "dir")),
            f"{route} repos/cli/cli/contents/.github": listing(("pull_request_template.md", "file")),
            f"{route} -H Accept: application/vnd.github.raw repos/cli/cli/contents/.github/pull_request_template.md":
                "## Summary\n\n## Testing\n",
        }), encoding="utf-8")
        code, result = self.run_check("--repo", "ghe.example.com/cli/cli", "--kind", "pr", "--body", "-", stdin="## Summary\n\nDone.\n")
        self.assertEqual((code, [p["expected"] for p in result["problems"]]), (1, ["## Testing"]))

    def test_a_flow_style_form_after_a_document_marker_is_read(self):
        self.write(".github/ISSUE_TEMPLATE/form.yml", "---\n{name: Bug report, body: [{type: input, attributes: {label: A}}]}\n")
        code, result = self.run_check(
            "--root", str(self.checkout), "--kind", "issue", "--body", "-", "--template-name", "Bug report",
            stdin="### A\n\nText.\n",
        )
        self.assertEqual((code, result["state"], result["template"]["path"]), (0, "match", ".github/ISSUE_TEMPLATE/form.yml"))
    def test_live_pull_request_body_against_its_repository_template(self):
        repo = "cli/cli"
        listing = lambda *names: json.dumps([{"name": name, "type": kind} for name, kind in names])
        self.scenario.write_text(json.dumps({
            f"pr view 7 --json body --repo {repo}": json.dumps({"body": "## Summary\r\n\r\nDone.\r\n"}),
            f"api repos/{repo}/contents": listing(("README.md", "file"), (".github", "dir")),
            f"api repos/{repo}/contents/.github": listing(("PULL_REQUEST_TEMPLATE.md", "file")),
            f"api -H Accept: application/vnd.github.raw repos/{repo}/contents/.github/PULL_REQUEST_TEMPLATE.md":
                "## Summary\n\n## Testing\n",
        }), encoding="utf-8")

        code, result = self.run_check("--pr", "7", "--repo", repo)

        self.assertEqual(code, 1)
        self.assertEqual(result["template"]["path"], ".github/PULL_REQUEST_TEMPLATE.md")
        self.assertEqual(
            [(problem["kind"], problem["expected"]) for problem in result["problems"]],
            [("missing", "## Testing")],
        )


if __name__ == "__main__":
    unittest.main()
