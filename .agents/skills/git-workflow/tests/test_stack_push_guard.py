import copy
import importlib.util
import io
import itertools
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.parse

SKILL = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("stack_push_guard", SKILL / "scripts/stack_push_guard.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.admission = {"directory": "/fixture", "remote": "upstream", "url": "/remote",
                          "refs": [{"ref": "refs/heads/feature/naïve-key", "source": "a" * 40, "expected": "b" * 40}]}
        row = self.admission["refs"][0]
        self.line = f'{row["ref"]} {row["source"]} {row["ref"]} {row["expected"]}\n'

    def test_nested_unicode_refs_and_sha256_are_not_fixture_specific(self):
        self.assertEqual(len(guard.validate_updates(self.admission, "upstream", "/remote", self.line)), 1)
        c = copy.deepcopy(self.admission)
        c["refs"][0].update(source="a" * 64, expected="0" * 64)
        self.assertEqual(guard.validate_admission(c), c)

    def test_bad_scope_or_object_cannot_be_admitted(self):
        for field, value in [("ref", "refs/tags/release"), ("ref", "refs/heads/.hidden"),
                             ("ref", "refs/heads/a..b"), ("ref", "refs/heads/a\nb"),
                             ("source", "0" * 40), ("source", "HEAD"), ("expected", "f" * 64)]:
            with self.subTest(field=field, value=value):
                c = copy.deepcopy(self.admission)
                c["refs"][0][field] = value
                with self.assertRaises(guard.GuardError):
                    guard.validate_admission(c)
        c = copy.deepcopy(self.admission)
        c["refs"] *= 2
        with self.assertRaises(guard.GuardError):
            guard.validate_admission(c)

    def test_a_misnamed_key_is_refused_with_the_keys_the_entry_needs(self):
        c = copy.deepcopy(self.admission)
        c["refs"][0]["name"] = c["refs"][0].pop("ref")
        with self.assertRaises(guard.GuardError) as raised:
            guard.validate_admission(c)
        self.assertEqual(str(raised.exception), 'invalid admitted ref fields in refs[0]: unexpected "name"; '
                         'missing "ref"; the keys are "ref", "source" and "expected"')
        c = copy.deepcopy(self.admission)
        c["refs"].append({"name": "refs/heads/other", "source": "c" * 40, "expect": "d" * 40})
        with self.assertRaises(guard.GuardError) as raised:
            guard.validate_admission(c)
        self.assertEqual(str(raised.exception), 'invalid admitted ref fields in refs[1]: unexpected "name" and "expect"; '
                         'missing "ref" and "expected"; the keys are "ref", "source" and "expected"')
        c = copy.deepcopy(self.admission)
        c["refs"][0] = ["refs/heads/feature/naïve-key"]
        with self.assertRaisesRegex(guard.GuardError, r'invalid admitted ref fields in refs\[0\]: expected a JSON object'):
            guard.validate_admission(c)
        c = copy.deepcopy(self.admission)
        c["refs"][0]["re\u2028f"] = c["refs"][0].pop("ref")
        with self.assertRaises(guard.GuardError) as raised:
            guard.validate_admission(c)
        self.assertIn('unexpected "re\\u2028f"', str(raised.exception))
        self.assertEqual(len(str(raised.exception).splitlines()), 1)

    def test_corrupt_redirected_deleted_or_duplicated_updates_fail(self):
        for text in ["invalid\n", self.line * 2, self.line.replace("feature/naïve-key", "other", 1),
                     self.line.replace("a" * 40, "0" * 40), self.line.replace("b" * 40, "c" * 40)]:
            with self.subTest(text=text), self.assertRaises(guard.GuardError):
                guard.validate_updates(self.admission, "upstream", "/remote", text)
        for remote, url in [("origin", "/remote"), ("upstream", "/other")]:
            with self.assertRaises(guard.GuardError):
                guard.validate_updates(self.admission, remote, url, self.line)
        self.assertEqual(guard.validate_updates(self.admission, "upstream", "/remote", ""), [])

    def test_no_arbitrary_commands_or_hook_bypass_in_run(self):
        valid = ["gh", "stack", "submit", "--auto", "--remote", "upstream"]
        guard.validate_native_command(valid, self.admission)
        guard.validate_native_command(["gh", "stack", "push", "--remote", "upstream"], self.admission)
        guard.validate_native_command(["gh", "stack", "link", "12", "feature/naïve-key", "--remote", "upstream"], self.admission)
        for command in [valid + ["--no-verify"], ["sh", "-c", "anything"],
                        ["gh", "stack", "merge"], ["gh", "stack", "link", "12", "unapproved", "--remote", "upstream"],
                        valid[:-1] + ["other"], ["gh", "stack", "push", "--remote", "other"],
                        ["gh", "stack", "push", "--remote", "upstream", "--no-verify"]]:
            with self.subTest(command=command), self.assertRaises(guard.GuardError):
                guard.validate_native_command(command, self.admission)

    def test_link_accepts_several_numbers_or_admitted_branches(self):
        for targets in [["12", "13"], ["1639", "1644", "1645", "1649", "1656"], ["7", "48", "feature/naïve-key"],
                        ["12", "feature/naïve-key", "13"]]:
            with self.subTest(targets=targets):
                guard.validate_native_command(["gh", "stack", "link", *targets, "--remote", "upstream"], self.admission)

    def test_malformed_link_is_refused(self):
        flagged = copy.deepcopy(self.admission)
        flagged["refs"].append({"ref": "refs/heads/--open", "source": "c" * 40, "expected": "d" * 40})
        numeric = copy.deepcopy(self.admission)
        numeric["refs"] += [{"ref": "refs/heads/" + name, "source": "c" * 40, "expected": "d" * 40}
                            for name in ("+13", "013")]
        for targets, admission in [
                (["12"], self.admission), (["12", "13", "12"], self.admission),
                (["12", "feature/naïve-key", "unapproved"], self.admission),
                (["feature/naïve-key", "12"], self.admission), (["0", "12"], self.admission),
                (["012", "13"], self.admission), (["12", "²"], self.admission),
                (["12", "https://github.com/github/gh-stack/pull/13"], self.admission),
                (["12", "13", "--open"], self.admission), (["12", "13", "--base", "main"], self.admission),
                (["12", "--open"], flagged), (["12", "1٣"], self.admission), (["12", "13x"], self.admission),
                (["12", "+13"], numeric), (["12", "013"], numeric)]:
            with self.subTest(targets=targets):
                with self.assertRaises(guard.GuardError):
                    guard.validate_native_command(["gh", "stack", "link", *targets, "--remote", "upstream"], admission)
        for command in [["gh", "stack", "link", "12", "13"], ["gh", "stack", "link", "12", "13", "--remote", "other"],
                        ["gh", "stack", "link", "12", "13", "--remote", "upstream", "--no-verify"],
                        ["gh", "stack", "link", "--remote", "upstream", "12", "13"]]:
            with self.subTest(command=command), self.assertRaises(guard.GuardError):
                guard.validate_native_command(command, self.admission)

    def test_duplicate_json_and_incomplete_config_fail(self):
        with self.assertRaises(guard.GuardError):
            guard.load_json('{"remote":"origin","remote":"elsewhere"}')
        for env in [{"GIT_CONFIG_COUNT": "01"}, {"GIT_CONFIG_COUNT": "1"}, {"GIT_CONFIG_COUNT": "-1"}]:
            with self.assertRaises(guard.GuardError):
                guard.config_count(env)


class FakeGitHub:
    """Answers the guard's two GitHub lookups from fixed pull requests and run counts."""

    def __init__(self, pulls=(), runs=None, fail=None, full_name="example-org/app"):
        self.pulls, self.runs, self.fail, self.calls = list(pulls), runs or {}, fail, []
        self.full_name = full_name

    def __call__(self, host, path):
        self.calls.append((host, path))
        if self.fail:
            raise guard.GuardError(self.fail)
        if "?" not in path:
            return {"full_name": self.full_name}
        if "/pulls?" in path:
            # Like GitHub, an owner other than the current one matches nothing.
            owner, head = urllib.parse.unquote(path.split("head=", 1)[1]).split(":", 1)
            return [p for p in self.pulls if p["head"]["ref"] == head
                    and owner.lower() == self.full_name.split("/")[0].lower()]
        query = urllib.parse.parse_qs(path.split("?", 1)[1])
        found = self.runs.get(query["head_sha"][0], [])
        if isinstance(found, int):  # that many finished, passed runs of one workflow
            found = many_runs(found)
        size, page = int(query["per_page"][0]), int(query.get("page", ["1"])[0])
        return {"total_count": len(found), "workflow_runs": found[(page - 1) * size:page * size]}


RUN_IDS = itertools.count(1000)


def run(status="completed", conclusion="success", workflow=1, run_id=None, name="CI", event="pull_request"):
    return {"id": next(RUN_IDS) if run_id is None else run_id, "name": name, "status": status, "event": event,
            "conclusion": conclusion if status == "completed" else None, "workflow_id": workflow}


def many_runs(count, **fields):
    return [run(**fields) for _ in range(count)]


def pull(number, branch, sha, draft=True, repository="example-org/app"):
    return {"number": number, "draft": draft, "head": {"ref": branch, "sha": sha, "repo": {"full_name": repository}}}


class RewriteTests(unittest.TestCase):
    def setUp(self):
        self.admission = guard.validate_admission({
            "directory": "/fixture", "remote": "origin", "url": "https://github.com/example-org/app.git",
            "refs": [{"ref": "refs/heads/stack/one", "source": "a" * 40, "expected": "b" * 40},
                     {"ref": "refs/heads/stack/two", "source": "c" * 40, "expected": "d" * 40}]})

    def with_rewrite(self, *refs):
        return guard.validate_admission({**self.admission, "rewrite": [
            {"ref": ref, "reason": "final rebase before merging the whole stack"} for ref in refs]})

    def test_draft_pull_requests_without_runs_pass(self):
        github = FakeGitHub([pull(12, "stack/one", "b" * 40), pull(13, "stack/two", "d" * 40)])
        observed = guard.check_rewrites(self.admission, github)
        self.assertEqual([o["pullRequest"] for o in observed], [12, 13])
        self.assertEqual({host for host, _ in github.calls}, {"github.com"})
        self.assertEqual(github.calls[0][1], "repos/example-org/app")
        self.assertIn("repos/example-org/app/pulls?state=open&per_page=100&head=example-org%3Astack%2Fone", github.calls[1][1])

    def test_a_transferred_repository_is_checked_under_its_current_owner(self):
        github = FakeGitHub([pull(12, "stack/one", "b" * 40, draft=False, repository="example-renamed/app")],
                            full_name="example-renamed/app")
        with self.assertRaisesRegex(guard.GuardError, "#12"):
            guard.check_rewrites(self.admission, github)

    def test_branch_names_are_encoded_and_other_heads_ignored(self):
        admission = guard.validate_admission({**self.admission, "refs": [
            {"ref": "refs/heads/stack/naïve+&#", "source": "a" * 40, "expected": "b" * 40}]})
        github = FakeGitHub([pull(12, "stack/naïve+&#", "b" * 40, draft=False)])
        with self.assertRaisesRegex(guard.GuardError, "#12"):
            guard.check_rewrites(admission, github)
        self.assertTrue(github.calls[1][1].endswith("head=example-org%3Astack%2Fna%C3%AFve%2B%26%23"))
        fork = FakeGitHub([pull(12, "stack/naïve+&#", "b" * 40, draft=False, repository="example-fork/app")])
        self.assertEqual(guard.check_rewrites(admission, fork), [])

    def test_ready_pull_request_is_refused(self):
        github = FakeGitHub([pull(12, "stack/one", "b" * 40, draft=False), pull(13, "stack/two", "d" * 40)])
        with self.assertRaisesRegex(guard.GuardError, r"1 open pull request\(s\): #12 \(stack/one: ready for review\)"):
            guard.check_rewrites(self.admission, github)

    def test_a_draft_whose_ci_has_not_passed_may_move(self):
        # Not frozen whatever its review state: its CI is queued, running, failed or cancelled.
        for runs in ([run("queued")], [run(), run("in_progress")], [run(conclusion="failure")],
                     [run(conclusion="cancelled")], [run(), run(conclusion="failure", workflow=2)]):
            with self.subTest(runs=runs):
                github = FakeGitHub([pull(12, "stack/one", "b" * 40), pull(13, "stack/two", "d" * 40)],
                                    runs={"b" * 40: runs})
                observed = guard.check_rewrites(self.admission, github)
                self.assertEqual([(o["pullRequest"], o["workflowRuns"], o["ciPassed"]) for o in observed],
                                 [(12, len(runs), False), (13, 0, False)])

    def test_a_draft_whose_ci_passed_is_frozen_and_the_cost_is_named(self):
        # An older cancelled run replaced by a passed run of the same workflow keeps it frozen.
        github = FakeGitHub([pull(12, "stack/one", "b" * 40), pull(13, "stack/two", "d" * 40, draft=False)],
                            runs={"b" * 40: [run(conclusion="cancelled"), run(), run(conclusion="skipped", workflow=2)],
                                  "d" * 40: [run("in_progress")]})
        with self.assertRaises(guard.GuardError) as caught:
            guard.check_rewrites(self.admission, github)
        message = str(caught.exception)
        self.assertIn("#12 (stack/one: draft, CI passed on its head, 3 workflow runs on its head)", message)
        self.assertIn("#13 (stack/two: ready for review, 1 workflow runs on its head)", message)
        self.assertIn("restart CI on 2 of them", message)

    def test_the_freeze_rule_for_each_state_of_a_layer(self):
        # Frozen means ready for review, or CI passed on the exact head with a terminal review;
        # the guard cannot see the review, so it protects every draft whose CI passed.
        admission = guard.validate_admission({**self.admission, "refs": self.admission["refs"][:1]})
        movable = (("no runs", [], "none", "no workflow runs"),
                   ("failed runs", [run(conclusion="failure"), run(workflow=2)], "failed", "failed or was cancelled"),
                   ("runs still going", [run("in_progress"), run("queued", workflow=2)], "running", "has not finished"))
        for case, runs, ci, reason in movable:
            with self.subTest(case=case):
                github = FakeGitHub([pull(12, "stack/one", "b" * 40)], runs={"b" * 40: runs})
                [observed] = guard.check_rewrites(admission, github)
                self.assertEqual((observed["pullRequest"], observed["ci"], observed["ciPassed"]), (12, ci, False))
                self.assertIn(reason, observed["reason"])
                self.assertIn("not frozen", observed["reason"])
        refused = (("a draft whose runs all passed", True, [run(), run(conclusion="skipped", workflow=2)],
                    "draft, CI passed on its head", "frozen once its review is terminal"),
                   ("a ready pull request without runs", False, [], "ready for review)", "ready for review is frozen"),
                   ("a ready pull request whose CI failed", False, [run(conclusion="failure")], "ready for review,",
                    "ready for review is frozen"))
        for case, draft, runs, state, advice in refused:
            with self.subTest(case=case):
                github = FakeGitHub([pull(12, "stack/one", "b" * 40, draft=draft)], runs={"b" * 40: runs})
                with self.assertRaises(guard.GuardError) as caught:
                    guard.check_rewrites(admission, github)
                message = str(caught.exception)
                self.assertIn(f"#12 (stack/one: {state}", message)
                self.assertIn(advice, message)
                self.assertIn("new top layer", message)
                # The listed ref is the explicit override for a protected layer.
                self.assertEqual(guard.check_rewrites(self.with_rewrite("refs/heads/stack/one"), github), [])

    def test_the_newest_run_of_a_workflow_and_event_decides(self):
        admission = guard.validate_admission({**self.admission, "refs": self.admission["refs"][:1]})
        cases = (("a newer failure after an older success", [run(run_id=100), run(conclusion="failure", run_id=101)],
                  "failed"),
                 ("a newer success after an older failure", [run(conclusion="failure", run_id=100), run(run_id=101)],
                  "passed"),
                 # Not green as the pull request gate counts it until the cancelled run is rerun,
                 # whether it was a duplicate, a manual cancellation or a cancelled rerun.
                 ("a later cancellation after an older success", [run(run_id=100),
                                                                  run(conclusion="cancelled", run_id=101)], "failed"),
                 ("a cancelled rerun after a cancellation", [run(conclusion="cancelled", run_id=100),
                                                             run(conclusion="cancelled", run_id=101)], "failed"),
                 ("a later cancellation after only failures", [run(conclusion="failure", run_id=100),
                                                               run(conclusion="cancelled", run_id=101)], "failed"),
                 ("an older run still going beside a newer success", [run("in_progress", run_id=100),
                                                                       run(run_id=101)], "passed"),
                 ("another event of the same workflow failed", [run(run_id=100),
                                                                run(conclusion="failure", run_id=101, event="push")],
                  "failed"))
        for case, runs, ci in cases:
            with self.subTest(case=case):
                self.assertEqual(guard.ci_state(len(runs), runs, True, 12)["ci"], ci)
                github = FakeGitHub([pull(12, "stack/one", "b" * 40)], runs={"b" * 40: runs})
                if ci == "passed":
                    with self.assertRaisesRegex(guard.GuardError, "draft, CI passed"):
                        guard.check_rewrites(admission, github)
                else:
                    self.assertEqual(guard.check_rewrites(admission, github)[0]["ci"], "failed")

    def test_a_draft_only_rewrite_moves_a_green_draft_but_never_a_ready_pull_request(self):
        admission = guard.validate_admission({**self.admission, "refs": self.admission["refs"][:1], "rewrite": [
            {"ref": "refs/heads/stack/one", "reason": "its review has not finished", "draftOnly": True}]})
        green = FakeGitHub([pull(12, "stack/one", "b" * 40)], runs={"b" * 40: [run()]})
        [observed] = guard.check_rewrites(admission, green)
        self.assertEqual((observed["pullRequest"], observed["ci"]), (12, "passed"))
        self.assertIn("admitted reason", observed["reason"])
        # Still looked up at the push: a pull request marked ready in between, or a
        # second ready pull request on the same branch, is refused.
        for pulls in ([pull(12, "stack/one", "b" * 40, draft=False)],
                      [pull(12, "stack/one", "b" * 40), pull(14, "stack/one", "b" * 40, draft=False)]):
            with self.subTest(pulls=[p["number"] for p in pulls]):
                github = FakeGitHub(pulls, runs={"b" * 40: [run()]})
                with self.assertRaisesRegex(guard.GuardError, "ready for review.*never moves a ready pull request"):
                    guard.check_rewrites(admission, github)
        url = "https://github.com/example-org/app.git"
        line = f"refs/heads/stack/one {'a' * 40} refs/heads/stack/one {'b' * 40}\n"
        ready = FakeGitHub([pull(12, "stack/one", "b" * 40, draft=False)])
        with self.assertRaisesRegex(guard.GuardError, "ready for review"):
            guard.admit_updates(admission, "origin", url, line, ready)
        for bad in ({"draftOnly": False}, {"draftOnly": "yes"}, {"extra": 1}):
            with self.subTest(bad=bad), self.assertRaises(guard.GuardError):
                guard.validate_admission({**self.admission, "rewrite": [
                    {"ref": "refs/heads/stack/one", "reason": "x", **bad}]})

    def test_long_run_lists_are_read_page_by_page(self):
        cases = ((many_runs(100) + [run("queued")], False, 2),  # a run still going on page two
                 (many_runs(101, conclusion="failure"), False, 2),
                 (many_runs(150), True, 2),
                 ([run(conclusion="failure", workflow=2)] + many_runs(150), False, 2),
                 # An older run still going is replaced by the newer passed runs of its workflow.
                 ([run("queued")] + many_runs(150), True, 2))
        for runs, passed, pages in cases:
            with self.subTest(passed=passed, pages=pages):
                github = FakeGitHub([pull(12, "stack/one", "b" * 40)], runs={"b" * 40: runs})
                admission = guard.validate_admission({**self.admission, "refs": self.admission["refs"][:1]})
                if passed:
                    with self.assertRaisesRegex(guard.GuardError, "draft, CI passed"):
                        guard.check_rewrites(admission, github)
                else:
                    self.assertFalse(guard.check_rewrites(admission, github)[0]["ciPassed"])
                self.assertEqual(sum("actions/runs" in path for _, path in github.calls), pages)

    def test_a_list_that_changes_while_read_or_a_blank_status_refuses(self):
        page_one = many_runs(100)
        for answer in (lambda path: {"total_count": 101, "workflow_runs": page_one if "page=1" in path else [page_one[0]]},
                       lambda path: {"total_count": 101 if "page=1" in path else 102,
                                     "workflow_runs": page_one if "page=1" in path else many_runs(2)}):
            with self.assertRaisesRegex(guard.GuardError, "changed while they were read"):
                guard.head_runs(lambda host, path: answer(path), "github.com", "example-org/app", "b" * 40, 12)
        blank = {"total_count": 1, "workflow_runs": [{**run(), "status": ""}]}
        with self.assertRaisesRegex(guard.GuardError, "incomplete workflow run"):
            guard.head_runs(lambda host, path: blank, "github.com", "example-org/app", "b" * 40, 12)

    def test_the_warning_names_only_pull_request_runs_and_says_when_the_list_was_cut(self):
        listed = [run("queued", run_id=7, name="CI PR"), run("in_progress", run_id=8, name="Release", event="push")]
        state = guard.ci_state(2, listed, True, 12)
        self.assertEqual((state["ciPassed"], state["runsGoing"]), (False, ["CI PR run 7 (queued)"]))
        long = [run("queued", run_id=9)] + many_runs(999)
        total, read, complete = guard.head_runs(
            lambda host, path: {"total_count": 1500, "workflow_runs": long[(int(urllib.parse.parse_qs(path.split("?", 1)[1])["page"][0]) - 1) * 100:][:100]},
            "github.com", "example-org/app", "b" * 40, 12)
        self.assertEqual((total, len(read), complete), (1500, 1000, False))

    def test_incomplete_or_endless_run_lists_refuse(self):
        def lookup(pages):
            return lambda host, path: pages(path)
        for answer, error in ((lambda path: {"total_count": 1}, "no workflow runs"),
                              (lambda path: {"total_count": 1, "workflow_runs": [{"status": "completed"}]},
                               "incomplete workflow run"),
                              (lambda path: {"total_count": 1, "workflow_runs": [
                                  {"status": "completed", "workflow_id": 1, "conclusion": None}]}, "incomplete workflow run"),
                              (lambda path: {"total_count": 2, "workflow_runs": [] if "page=2" in path else [run()]},
                               "fewer workflow runs"),
                              (lambda path: {"total_count": 5000, "workflow_runs": many_runs(100)}, "more than 10 pages")):
            with self.subTest(error=error), self.assertRaisesRegex(guard.GuardError, error):
                guard.head_runs(lookup(answer), "github.com", "example-org/app", "b" * 40, 12)

    def test_listed_rewrite_passes_without_a_lookup(self):
        github = FakeGitHub([pull(12, "stack/one", "b" * 40, draft=False)], runs={"b" * 40: 4})
        self.assertEqual(guard.check_rewrites(self.with_rewrite("refs/heads/stack/one"), github), [])
        self.assertEqual(len(github.calls), 2)  # the repository, then stack/two, which has no open pull request
        with self.assertRaisesRegex(guard.GuardError, "#12"):
            guard.check_rewrites(self.with_rewrite("refs/heads/stack/two"), github)

    def test_invalid_rewrite_entries(self):
        for rewrite in [[{"ref": "refs/heads/stack/three", "reason": "not admitted"}],
                        [{"ref": "refs/heads/stack/one", "reason": "  "}],
                        [{"ref": ["refs/heads/stack/one"], "reason": "x"}],
                        [{"ref": "refs/heads/stack/one", "reason": "x"}] * 2, [], "refs/heads/stack/one"]:
            with self.subTest(rewrite=rewrite), self.assertRaises(guard.GuardError):
                guard.validate_admission({**self.admission, "rewrite": rewrite})
        with self.assertRaisesRegex(guard.GuardError, r'invalid rewrite fields in rewrite\[0\]: missing "reason"'):
            guard.validate_admission({**self.admission, "rewrite": [{"ref": "refs/heads/stack/one"}]})
        with self.assertRaisesRegex(guard.GuardError, 'invalid admission fields: unexpected "rewrites"; '
                                    'the keys are "directory", "remote", "url" and "refs", optionally "rewrite"'):
            guard.validate_admission({**self.admission, "rewrites": []})

    def test_lookup_failure_refuses(self):
        with self.assertRaisesRegex(guard.GuardError, "HTTP 502"):
            guard.check_rewrites(self.admission, FakeGitHub(fail="GitHub lookup failed: HTTP 502"))
        incomplete = FakeGitHub([{"number": 12, "head": {"ref": "stack/one", "sha": "b" * 40}}])
        with self.assertRaisesRegex(guard.GuardError, "incomplete pull request"):
            guard.check_rewrites(self.admission, incomplete)
        with self.assertRaisesRegex(guard.GuardError, "#12 head is"):
            guard.check_rewrites(self.admission, FakeGitHub([pull(12, "stack/one", "e" * 40)]))
        crowded = FakeGitHub([pull(n, "stack/one", "b" * 40) for n in range(1, 101)])
        with self.assertRaisesRegex(guard.GuardError, "more than one page"):
            guard.check_rewrites(self.admission, crowded)
        with self.assertRaisesRegex(guard.GuardError, "names no GitHub repository"):
            guard.check_rewrites({**self.admission, "url": "/srv/git/app.git"}, FakeGitHub())

    def test_the_hook_checks_again_at_the_push(self):
        line = "refs/heads/stack/one " + "a" * 40 + " refs/heads/stack/one " + "b" * 40 + "\n"
        url = self.admission["url"]
        github = FakeGitHub([pull(12, "stack/one", "b" * 40)])
        self.assertEqual(len(guard.check_rewrites(self.admission, github)), 1)
        # Marked ready after the guard was prepared.
        github.pulls[0]["draft"] = False
        with self.assertRaisesRegex(guard.GuardError, "#12"):
            guard.admit_updates(self.admission, "origin", url, line, github)
        updates, observed = guard.admit_updates(self.with_rewrite("refs/heads/stack/one"), "origin", url, line, github)
        self.assertEqual((len(updates), observed), (1, []))
        # Only the refs actually pushed are looked up; an empty push needs none.
        quiet = FakeGitHub(fail="no lookup expected")
        self.assertEqual(guard.admit_updates(self.admission, "origin", url, "", quiet), ([], []))

    def test_missing_gh_refuses(self):
        with tempfile.TemporaryDirectory() as empty, mock.patch.dict(os.environ, {"PATH": empty}):
            with self.assertRaisesRegex(guard.GuardError, "gh is not installed"):
                guard.github_api("github.com", "repos/example-org/app/pulls")

    def test_new_or_unchanged_branches_need_no_lookup(self):
        admission = guard.validate_admission({**self.admission, "url": "/not/github", "refs": [
            {"ref": "refs/heads/stack/one", "source": "a" * 40, "expected": "0" * 40},
            {"ref": "refs/heads/stack/two", "source": "d" * 40, "expected": "d" * 40}]})
        github = FakeGitHub(fail="no lookup expected")
        self.assertEqual(guard.check_rewrites(admission, github), [])
        self.assertEqual(github.calls, [])

    def test_remote_url_forms(self):
        for url, expected in [("https://github.com/example-org/app.git", ("github.com", "example-org/app")),
                              ("https://token@github.example.com/example-org/app", ("github.example.com", "example-org/app")),
                              ("git@github.com:example-org/my.app.git", ("github.com", "example-org/my.app")),
                              ("ssh://git@github.com:22/example-org/app.git/", ("github.com", "example-org/app")),
                              ("ssh://git@ssh.github.com:443/example_org/app.git", ("github.com", "example_org/app"))]:
            with self.subTest(url=url):
                self.assertEqual(guard.github_repository(url), expected)
        for url in ["/srv/git/app.git", "file:///srv/app.git", "https://github.com/example-org", "https://github.com/example-org/app/extra"]:
            with self.subTest(url=url), self.assertRaises(guard.GuardError):
                guard.github_repository(url)


FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
state = json.load(open(os.environ["FAKE_GH_STATE"]))
args = sys.argv[1:]
with open(os.environ["FAKE_GH_STATE"] + ".log", "a") as log:
    log.write(json.dumps(args) + "\n")
path = args[3]
if path != "graphql":
    if path in state.get("restAnswers", {}):
        print(json.dumps(state["restAnswers"][path]))
        sys.exit(0)
    sys.stderr.write(state.get("rest", "gh: API rate limit exceeded for user ID 1. (HTTP 403)") + "\n")
    sys.exit(1)
fields = dict(arg.split("=", 1) for arg in args[4:] if arg != "-f")
if state.get("graphql"):
    print(json.dumps({"errors": [{"type": "RATE_LIMITED", "message": state["graphql"]}]}))
    sys.exit(1)
query = fields["query"]
if query.count("{") != query.count("}"):
    print(json.dumps({"errors": [{"message": "Parse error"}]}))
    sys.exit(1)


def page(items, broken=None):
    """A connection page as GitHub pages it: at most `first`, after the cursor."""
    size = int(query.split("first:", 1)[1].split(",", 1)[0])
    start = int(fields.get("after", "0"))
    more = start + size < len(items)
    info = {"hasNextPage": more, "endCursor": str(start + size) if more else None}
    info.update(broken or {})
    return {"pageInfo": info, "nodes": items[start:start + size]}


if "checkSuites" in query:
    suites = state["suites"].get(fields["oid"], [])
    found = page(suites, state.get("suitePageInfo"))
    # suiteGrows: a suite that arrives after the first page, as on a live commit.
    if state.get("suiteGrows") and "after" in fields:
        suites = suites + [state["suiteGrows"]]
    found["totalCount"] = len(suites)
    answer = {"object": {"checkSuites": found}}
elif "pullRequests" in query:
    pulls = [p for p in state["pulls"] if p["headRefName"] == fields["branch"]]
    found = page(pulls)
    # pullGrows: a pull request reopened behind the cursor after the first page.
    found["totalCount"] = len(pulls) + (1 if state.get("pullGrows") and "after" in fields else 0)
    answer = {"pullRequests": found}
else:
    answer = {"nameWithOwner": state["repository"]}
print(json.dumps({"data": {"repository": answer}}))
'''


def suite(status="COMPLETED", conclusion="SUCCESS", workflow=1, run_id=None, event="pull_request", app="github-actions"):
    """A check suite as GraphQL gives it; with workflow=None, one without a workflow run."""
    return {"status": status, "conclusion": conclusion if status == "COMPLETED" else None, "app": {"slug": app},
            "workflowRun": None if workflow is None else {
                "databaseId": next(RUN_IDS) if run_id is None else run_id, "event": event,
                "workflow": {"databaseId": workflow, "name": "CI"}}}


def other_app(status="QUEUED"):
    return suite(status, conclusion=None, workflow=None, app="vercel")


def graph_pull(number, branch, sha, draft=True, repository="example-org/app"):
    return {"number": number, "isDraft": draft, "headRefName": branch, "headRefOid": sha,
            "headRepository": {"nameWithOwner": repository}}


class SpentRestTests(unittest.TestCase):
    """While GitHub refuses REST for its budget, the default lookup answers through GraphQL."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kgr-fake-gh-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        (root / "gh").write_text(FAKE_GH)
        (root / "gh").chmod(0o755)
        self.state = root / "state.json"
        patch = mock.patch.dict(os.environ, {"PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                                             "FAKE_GH_STATE": str(self.state)})
        patch.start()
        self.addCleanup(patch.stop)
        self.admission = guard.validate_admission({
            "directory": "/fixture", "remote": "origin", "url": "https://github.com/example-org/app.git",
            "refs": [{"ref": "refs/heads/stack/one", "source": "a" * 40, "expected": "b" * 40},
                     {"ref": "refs/heads/stack/two", "source": "c" * 40, "expected": "d" * 40}]})
        self.one = guard.validate_admission({**self.admission, "refs": self.admission["refs"][:1]})

    def answer(self, pulls=(), suites=None, repository="example-org/app", **state):
        Path(str(self.state) + ".log").unlink(missing_ok=True)
        self.state.write_text(json.dumps({"pulls": list(pulls), "suites": suites or {}, "repository": repository,
                                          **state}))

    def calls(self):
        log = Path(str(self.state) + ".log")
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def graphql_variables(self):
        return [dict(a.split("=", 1) for a in call[4:] if a != "-f") for call in self.calls() if call[3] == "graphql"]

    def test_a_frozen_layer_is_still_refused_and_other_apps_suites_are_ignored(self):
        # Another app's suite stays queued with no workflow run; REST lists no run for it.
        self.answer([graph_pull(12, "stack/one", "b" * 40), graph_pull(13, "stack/two", "d" * 40)],
                    {"b" * 40: [suite(), other_app()], "d" * 40: [suite(conclusion="FAILURE")]})
        with self.assertRaisesRegex(guard.GuardError, r"1 open pull request\(s\): #12 \(stack/one: draft, CI passed"):
            guard.check_rewrites(self.admission)
        calls = self.calls()
        self.assertEqual(calls[0][3], "repos/example-org/app")
        self.assertTrue(all(call[:3] == ["api", "--hostname", "github.com"] for call in calls))
        self.assertGreater(sum(call[3] == "graphql" for call in calls), 3)

    def test_a_draft_whose_ci_has_not_passed_may_move_and_forks_are_ignored(self):
        self.answer([graph_pull(12, "stack/one", "b" * 40), graph_pull(14, "stack/one", "e" * 40, draft=False,
                                                                     repository="example-fork/app")],
                    {"b" * 40: [suite(), suite("IN_PROGRESS", workflow=2, run_id=7)]})
        observed = guard.check_rewrites(self.admission)
        self.assertEqual([(o["pullRequest"], o["workflowRuns"], o["ciPassed"], o["runsGoing"]) for o in observed],
                         [(12, 2, False, ["CI run 7 (in_progress)"])])

    def test_a_renamed_repository_and_long_suite_lists(self):
        self.answer([graph_pull(12, "stack/one", "b" * 40, repository="example-renamed/app")],
                    {"b" * 40: [suite() for _ in range(150)] + [other_app()] * 30},
                    repository="example-renamed/app")
        with self.assertRaisesRegex(guard.GuardError, "#12 \\(stack/one: draft, CI passed on its head, 150 workflow"):
            guard.check_rewrites(self.one)
        variables = self.graphql_variables()
        self.assertEqual(variables[1]["owner"], "example-renamed")
        self.assertEqual([v.get("after") for v in variables if "checkSuites" in v["query"]], [None, "100"])

    def test_an_actions_suite_without_its_run_or_a_broken_page_refuses(self):
        # An Actions suite GitHub gives without its run may be a passed run: it is not taken for another app's.
        for suites, state, error in (([suite(), suite(workflow=None)], {}, "GitHub Actions check suite without its run"),
                                     ([suite(), {**other_app(), "app": None}], {}, "without its app"),
                                     ([suite(), None], {}, "incomplete check suites"),
                                     ([suite()], {"suitePageInfo": {"hasNextPage": None}}, "no check suites"),
                                     ([suite()], {"suitePageInfo": {"hasNextPage": True, "endCursor": None}},
                                      "no check suites")):
            with self.subTest(error=error, state=state):
                self.answer([graph_pull(12, "stack/one", "b" * 40)], {"b" * 40: suites}, **state)
                with self.assertRaisesRegex(guard.GuardError, error):
                    guard.check_rewrites(self.one)

    def test_a_run_list_comes_whole_from_one_api(self):
        # REST answers page one, then runs out: GraphQL gives the whole list, and
        # nothing REST read before is kept beside it, duplicate IDs included.
        runs = many_runs(100)
        page_one = "repos/example-org/app/actions/runs?per_page=100&page=1&head_sha=" + "b" * 40
        rest = {page_one: {"total_count": 101, "workflow_runs": runs}}
        suites = [suite(run_id=r["id"]) for r in runs] + [suite(run_id=99999)]
        self.answer([graph_pull(12, "stack/one", "b" * 40)], {"b" * 40: suites}, restAnswers=rest)
        with self.assertRaisesRegex(guard.GuardError, "draft, CI passed on its head, 101 workflow runs"):
            guard.check_rewrites(self.one)
        self.assertIn(page_one, [call[3] for call in self.calls()])
        self.answer([graph_pull(12, "stack/one", "b" * 40)],
                    {"b" * 40: [suite(run_id=r["id"]) for r in runs] + [suite("QUEUED", run_id=99999)]},
                    restAnswers=rest)
        self.assertFalse(guard.check_rewrites(self.one)[0]["ciPassed"])

    def test_fork_pull_requests_do_not_count_toward_the_cutoff(self):
        forks = [graph_pull(n, "patch-1", "e" * 40, draft=False, repository=f"fork-{n}/app") for n in range(100, 250)]
        admission = guard.validate_admission({**self.admission, "refs": [
            {"ref": "refs/heads/patch-1", "source": "a" * 40, "expected": "b" * 40}]})
        self.answer(forks + [graph_pull(12, "patch-1", "b" * 40)], {"b" * 40: [suite(conclusion="FAILURE")]})
        self.assertEqual([o["pullRequest"] for o in guard.check_rewrites(admission)], [12])
        self.answer([graph_pull(n, "patch-1", "b" * 40) for n in range(1, 101)])
        with self.assertRaisesRegex(guard.GuardError, "more than one page"):
            guard.check_rewrites(admission)

    def test_a_pull_request_list_that_changes_while_read_refuses(self):
        # A ready pull request reopened behind the cursor shows only in the count.
        forks = [graph_pull(n, "patch-1", "e" * 40, repository=f"fork-{n}/app") for n in range(100, 201)]
        admission = guard.validate_admission({**self.admission, "refs": [
            {"ref": "refs/heads/patch-1", "source": "a" * 40, "expected": "b" * 40}]})
        self.answer(forks, pullGrows=True)
        with self.assertRaisesRegex(guard.GuardError, "changed while they were read"):
            guard.check_rewrites(admission)
        self.answer(forks + [forks[0]])
        with self.assertRaisesRegex(guard.GuardError, "changed while they were read"):
            guard.check_rewrites(admission)

    def test_other_apps_suites_do_not_count_toward_the_run_limit(self):
        self.answer([graph_pull(12, "stack/one", "b" * 40)],
                    {"b" * 40: [other_app() for _ in range(1100)] + [suite(conclusion="FAILURE")]})
        self.assertEqual([(o["workflowRuns"], o["ciPassed"]) for o in guard.check_rewrites(self.one)], [(1, False)])
        # More runs than the guard reads, even with one still going: which run of a
        # workflow is newest cannot be established, so it refuses.
        self.answer([graph_pull(12, "stack/one", "b" * 40)],
                    {"b" * 40: [suite("QUEUED")] + [suite() for _ in range(1200)]})
        with self.assertRaisesRegex(guard.GuardError, "which run of each workflow decides"):
            guard.check_rewrites(self.one)
        self.answer([graph_pull(12, "stack/one", "b" * 40)], {"b" * 40: [suite() for _ in range(1200)]})
        with self.assertRaisesRegex(guard.GuardError, "more than 10 pages"):
            guard.check_rewrites(self.one)

    def test_a_suite_list_that_changes_while_read_refuses(self):
        # A passed run arriving between pages would otherwise go unseen.
        self.answer([graph_pull(12, "stack/one", "b" * 40)],
                    {"b" * 40: [suite(conclusion="FAILURE", workflow=2)] + [suite() for _ in range(149)]},
                    suiteGrows=suite(workflow=2))
        with self.assertRaisesRegex(guard.GuardError, "changed while they were read"):
            guard.check_rewrites(self.one)

    def test_a_count_cut_short_is_a_lower_bound(self):
        self.answer([graph_pull(12, "stack/one", "b" * 40)],
                    {"b" * 40: [suite("QUEUED")] + [other_app() for _ in range(3100)]})
        with self.assertRaisesRegex(guard.GuardError, "which run of each workflow decides"):
            guard.check_rewrites(self.one)
        self.answer([graph_pull(12, "stack/one", "b" * 40, draft=False)],
                    {"b" * 40: [suite("QUEUED")] + [other_app() for _ in range(3100)]})
        with self.assertRaisesRegex(guard.GuardError, "ready for review, at least 1 workflow runs on its head"):
            guard.check_rewrites(self.one)

    def test_spent_graphql_or_another_rest_failure_still_refuses(self):
        self.answer([graph_pull(12, "stack/one", "b" * 40)], graphql="API rate limit exceeded")
        with self.assertRaisesRegex(guard.GuardError, "REST refused it .*rate limit.*GraphQL did too: API rate limit"):
            guard.check_rewrites(self.admission)
        for message in ("gh: You have exceeded a secondary rate limit. (HTTP 403)", "gh: HTTP 429"):
            with self.subTest(message=message):
                self.answer(rest=message, repository=None)
                with self.assertRaisesRegex(guard.GuardError, "no repository"):
                    guard.check_rewrites(self.admission)
        self.answer([graph_pull(12, "stack/one", "b" * 40)], rest="gh: Bad Gateway (HTTP 502)")
        with self.assertRaisesRegex(guard.GuardError, "HTTP 502"):
            guard.check_rewrites(self.admission)
        self.assertEqual([call[3] for call in self.calls()], ["repos/example-org/app"])

    def test_a_missing_repository_or_an_unknown_lookup_refuses(self):
        self.answer(repository=None)
        with self.assertRaisesRegex(guard.GuardError, "no repository"):
            guard.check_rewrites(self.admission)
        for path in ("repos/example-org/app/issues", "repos/example-org/app/pulls?state=open&per_page=5",
                     "repos/example-org/app/actions/runs?per_page=100"):
            with self.subTest(path=path), self.assertRaisesRegex(guard.GuardError, "rate limit"):
                guard.github_api("github.com", path)


def rest_only(host, path):
    """A REST answer, never the fallback's: a live comparison needs both sides."""
    result = guard.gh_api(host, path)
    if result.returncode:
        raise unittest.SkipTest("REST did not answer: " + guard.last_line(result))
    return json.loads(result.stdout)


@unittest.skipUnless(os.environ.get("KGR_LIVE_GITHUB"), "set KGR_LIVE_GITHUB=1 to ask GitHub itself")
class LiveGraphQLTests(unittest.TestCase):
    """GitHub accepts the fallback's queries, and they give the decision REST gives.
    Reads a public repository with a signed-in gh; set KGR_LIVE_REPOSITORY to choose it."""

    repository = os.environ.get("KGR_LIVE_REPOSITORY", "cli/cli")

    @staticmethod
    def graphql(host, path):
        return guard.graphql_lookup(host, path, "live check")

    def test_github_accepts_the_queries(self):
        # Needs no REST budget: it runs while REST is spent too.
        name = self.graphql("github.com", "repos/" + self.repository)["full_name"]
        self.assertEqual(name.lower(), self.repository.lower())
        head = urllib.parse.quote(self.repository.split("/")[0] + ":main", safe="")
        self.assertIsInstance(self.graphql("github.com", f"repos/{name}/pulls?state=open&per_page=100&head={head}"), list)
        sha = json.loads(subprocess.run(["gh", "api", "graphql", "-f", "query=query($o:String!,$n:String!){repository("
                                         "owner:$o,name:$n){defaultBranchRef{target{oid}}}}",
                                         "-f", "o=" + name.split("/")[0], "-f", "n=" + name.split("/")[1]],
                                        capture_output=True, check=True).stdout)
        sha = sha["data"]["repository"]["defaultBranchRef"]["target"]["oid"]
        self.assertTrue(guard.head_runs(self.graphql, "github.com", name, sha, 0)[2])

    def test_graphql_answers_as_rest_does(self):
        repository = self.repository
        self.assertEqual(self.graphql("github.com", "repos/" + repository)["full_name"],
                         rest_only("github.com", "repos/" + repository)["full_name"])
        pulls = rest_only("github.com", f"repos/{repository}/pulls?state=open&per_page=30")
        with_runs = [p for p in pulls if p["head"]["repo"] and rest_only(
            "github.com", f"repos/{repository}/actions/runs?per_page=1&head_sha={p['head']['sha']}")["total_count"]]
        if not with_runs:
            self.skipTest("no open pull request with workflow runs to compare")
        pull = with_runs[0]
        head = urllib.parse.quote(pull["head"]["repo"]["owner"]["login"] + ":" + pull["head"]["ref"], safe="")
        path = f"repos/{repository}/pulls?state=open&per_page=100&head={head}"
        shape = lambda found: [(p["number"], p["draft"], p["head"]["ref"], p["head"]["sha"],
                                (p["head"]["repo"] or {}).get("full_name")) for p in found]
        self.assertEqual(shape(self.graphql("github.com", path)), shape(rest_only("github.com", path)))
        rest = guard.head_runs(rest_only, "github.com", repository, pull["head"]["sha"], pull["number"])
        fallback = guard.head_runs(self.graphql, "github.com", repository, pull["head"]["sha"], pull["number"])
        self.assertTrue(rest[1])
        self.assertEqual(sorted(r["id"] for r in fallback[1]), sorted(r["id"] for r in rest[1]))
        self.assertEqual(guard.ci_state(*fallback, pull["number"]), guard.ci_state(*rest, pull["number"]))


class StandaloneTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kgr-portable-guard-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        # Only the skill is copied. Neither evals nor npm dependencies exist here.
        shutil.copytree(SKILL, self.root / "installed skill")
        self.helper = self.root / "installed skill/scripts/stack_push_guard.py"
        self.repo = self.root / "repository"
        self.remote = self.root / "remote.git"
        self.repo.mkdir()
        self.git("init", "--bare", "--initial-branch=main", str(self.remote))
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("commit", "--allow-empty", "-m", "initial")
        self.head = self.git("rev-parse", "HEAD")
        self.ref = "refs/heads/feature/portable-guard"
        self.git("branch", self.ref.removeprefix("refs/heads/"))
        self.git("remote", "add", "origin", str(self.remote))
        self.admission = {"directory": str(self.repo), "remote": "origin", "url": str(self.remote),
                          "refs": [{"ref": self.ref, "source": self.head, "expected": "0" * 40}]}

    def git(self, *args, environment=None, check=True):
        result = subprocess.run(["git", *args], cwd=self.repo, env=environment, capture_output=True, text=True)
        if check and result.returncode:
            self.fail(result.stderr)
        return result.stdout.strip() if check else result

    def prepare(self, environment=None, admission=None):
        result = subprocess.run([sys.executable, str(self.helper), "prepare", "--admission", "-"],
                                input=json.dumps(admission or self.admission), capture_output=True, text=True, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def push(self, prepared, environment=None):
        return self.git("push", "origin", f"{self.ref}:{self.ref}",
                        environment={**(environment or os.environ), **prepared["configuration"]}, check=False)

    def test_standalone_copy_pushes_without_bun_or_repository_modules(self):
        prepared = self.prepare()
        result = self.push(prepared)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("ls-remote", "--heads", "origin", self.ref), f"{self.head}\t{self.ref}")
        receipt = json.loads(next(Path(prepared["directory"]).glob("check-*.json")).read_text())
        self.assertTrue(receipt["accepted"])
        self.assertEqual(receipt["updates"][0]["source"], self.head)

    def test_actual_sha256_and_unicode_ref_with_a_non_origin_remote(self):
        self.repo = self.root / "sha256 repository"
        self.remote = self.root / "sha256 remote.git"
        self.repo.mkdir()
        self.git("init", "--bare", "--object-format=sha256", "--initial-branch=main", str(self.remote))
        self.git("init", "--object-format=sha256", "--initial-branch=main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("commit", "--allow-empty", "-m", "sha256 fixture")
        self.head = self.git("rev-parse", "HEAD")
        self.ref = "refs/heads/feature/naïve-\u0085-key"
        self.git("branch", self.ref.removeprefix("refs/heads/"))
        self.git("remote", "add", "upstream", str(self.remote))
        self.admission = {"directory": str(self.repo), "remote": "upstream", "url": str(self.remote),
                          "refs": [{"ref": self.ref, "source": self.head, "expected": "0" * 64}]}
        prepared = self.prepare()
        result = self.git("push", "upstream", f"{self.ref}:{self.ref}",
                          environment={**os.environ, **prepared["configuration"]}, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.head), 64)
        self.assertEqual(self.git("ls-remote", "--heads", "upstream", self.ref), f"{self.head}\t{self.ref}")

    def test_preserves_existing_hook_environment_and_forwards_other_hooks(self):
        # Keep the configured hook directory in Git metadata so it is not dirty.
        hooks = self.repo / ".git" / "custom hooks"
        hooks.mkdir()
        self.git("config", "core.hooksPath", str(hooks))
        observed = self.root / "observed-hook-config"
        other = self.root / "other-hook"
        pre = hooks / "pre-push"
        pre.write_text(f"#!/bin/sh\ngit config --get test.retained > {shlex.quote(str(observed))}\ngit config --get core.hooksPath >> {shlex.quote(str(observed))}\ncat >/dev/null\n")
        pre.chmod(0o755)
        commit_hook = hooks / "pre-commit"
        commit_hook.write_text(f"#!/bin/sh\nprintf yes > {shlex.quote(str(other))}\n")
        commit_hook.chmod(0o755)
        env = {**os.environ, "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "test.retained", "GIT_CONFIG_VALUE_0": "retained"}
        prepared = self.prepare(env)
        result = self.push(prepared, env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(observed.read_text(), f"retained\n{hooks}\n")
        self.git("hook", "run", "pre-commit", environment={**env, **prepared["configuration"]})
        self.assertEqual(other.read_text(), "yes")
        self.assertEqual(self.git("config", "core.hooksPath"), str(hooks))
        self.assertNotIn("GIT_CONFIG_VALUE_0", prepared["configuration"])

    def moved_layer(self):
        """The branch exists on a GitHub-named remote and moves to a new local commit."""
        self.git("remote", "add", "github", "https://github.com/example-org/app.git")
        self.git("commit", "--allow-empty", "-m", "rebased layer")
        self.git("branch", "--force", self.ref.removeprefix("refs/heads/"), "HEAD")
        source = self.git("rev-parse", "HEAD")
        return {"directory": str(self.repo), "remote": "github", "url": "https://github.com/example-org/app.git",
                "refs": [{"ref": self.ref, "source": source, "expected": self.head}]}

    def test_prepare_refuses_a_reviewed_layer_and_admits_a_listed_rewrite(self):
        admission = self.moved_layer()
        github = FakeGitHub([pull(7, "feature/portable-guard", self.head, draft=False)], runs={self.head: 2})
        with self.assertRaisesRegex(guard.GuardError, r"#7 .*restart CI on 1 of them"):
            guard.prepare(admission, github)
        self.assertFalse((self.repo / ".git/kgr-push-guards").exists())
        admission["rewrite"] = [{"ref": self.ref, "reason": "final rebase before merging the whole stack"}]
        prepared = guard.prepare(admission, github)
        record = json.loads((Path(prepared["directory"]) / "admission.json").read_text())["request"]
        self.assertEqual(record["admission"]["rewrite"], admission["rewrite"])
        self.assertEqual(record["pullRequests"], [])

    def test_prepare_moves_a_draft_whose_ci_failed_and_names_the_restarted_runs(self):
        admission = self.moved_layer()
        github = FakeGitHub([pull(7, "feature/portable-guard", self.head)], runs={self.head: [
            run(conclusion="failure", run_id=41, name="CI PR"), run("in_progress", run_id=42, name="Evidence")]})
        with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            prepared = guard.prepare(admission, github)
        record = json.loads((Path(prepared["directory"]) / "admission.json").read_text())["request"]
        self.assertEqual([(o["pullRequest"], o["ci"], o["ciPassed"]) for o in record["pullRequests"]],
                         [(7, "running", False)])
        self.assertIn("not frozen", record["pullRequests"][0]["reason"])
        self.assertIn("moving draft #7 in place: draft whose CI on its head has not finished, so it is not frozen; "
                      "the push supersedes those runs; it restarts its CI (2 workflow runs on its current head); "
                      "once the push lands, cancel any of these pull request runs on the old head that its concurrency "
                      "group did not: Evidence run 42 (in_progress)\n", stderr.getvalue())

    def test_prepare_refuses_when_gh_is_unavailable(self):
        admission = self.moved_layer()
        only_git = self.root / "only-git"
        only_git.mkdir()
        (only_git / "git").symlink_to(shutil.which("git"))
        result = subprocess.run([sys.executable, str(self.helper), "prepare", "--admission", "-"],
                                input=json.dumps(admission), capture_output=True, text=True,
                                env={**os.environ, "PATH": str(only_git)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gh is not installed", result.stderr)
        self.assertFalse((self.repo / ".git/kgr-push-guards").exists())

    def test_hook_refuses_an_existing_branch_admitted_as_new(self):
        # Claiming a branch is new skips the lookup, so the hook must hold the claim.
        self.git("push", "--quiet", "origin", f"{self.ref}:{self.ref}")
        self.git("commit", "--allow-empty", "-m", "rebased layer")
        self.git("branch", "--force", self.ref.removeprefix("refs/heads/"), "HEAD")
        self.admission["refs"][0]["source"] = self.git("rev-parse", "HEAD")
        result = self.push(self.prepare())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("advertised remote head differs from admission", result.stderr)
        self.assertEqual(self.git("ls-remote", "--heads", "origin", self.ref), f"{self.head}\t{self.ref}")

    def test_frozen_helper_change_rejects_before_remote_update(self):
        prepared = self.prepare()
        frozen = Path(prepared["directory"]) / "guard.py"
        frozen.write_text(frozen.read_text() + "\n# changed after admission\n")
        result = self.push(prepared)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("frozen guard configuration or runtime changed", result.stderr)
        self.assertEqual(self.git("ls-remote", "--heads", "origin", self.ref), "")

    def test_changed_admission_and_symlink_replacement_are_rejected(self):
        for mode in ["content", "symlink"]:
            prepared = self.prepare()
            config = Path(prepared["directory"]) / "admission.json"
            value = json.loads(config.read_text())
            if mode == "content":
                value["request"]["admission"]["remote"] = "elsewhere"
                config.write_text(json.dumps(value))
            else:
                target = config.with_suffix(".copy")
                target.write_text(config.read_text())
                config.unlink()
                config.symlink_to(target)
            result = self.push(prepared)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.git("ls-remote", "--heads", "origin", self.ref), "")

    def test_dirty_checkout_and_changed_push_url_do_not_prepare(self):
        for mode in ["dirty", "push-url"]:
            if mode == "dirty":
                (self.repo / "unrelated").write_text("user work")
            else:
                (self.repo / "unrelated").unlink()
                self.git("remote", "set-url", "--push", "origin", str(self.root / "another.git"))
            result = subprocess.run([sys.executable, str(self.helper), "prepare", "--admission", "-"],
                                    input=json.dumps(self.admission), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.repo / ".git/kgr-push-guards").exists())

    def run_with_native_cli(self, version_output, arguments=("submit", "--auto", "--remote", "origin"), version_exit=0):
        # Native argv routing is tested here with a tiny gh stand-in; live tests
        # separately exercise the installed official extension against GitHub.
        gh = self.root / "gh"
        gh.write_text(f'#!/bin/sh\nif [ "$2" = "--version" ]; then printf %s {shlex.quote(version_output)}; exit {version_exit}; fi\n'
                      f'exec git push origin {shlex.quote(self.ref + ":" + self.ref)}\n')
        gh.chmod(0o755)
        return subprocess.run([sys.executable, str(self.helper), "run", "--admission", "-", "--", str(gh),
                               "stack", *arguments],
                              input=json.dumps(self.admission), capture_output=True, text=True)

    def test_run_cli_preserves_guard_and_child_exit_without_an_sdk(self):
        # Any gh-stack version is accepted; the behaviour was checked at 0.3.0.
        for version in ["0.2.1", "0.3.0"]:
            with self.subTest(version=version):
                self.git("push", "--quiet", "origin", "--delete", self.ref, check=False)
                result = self.run_with_native_cli(f"gh stack version {version}\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.git("ls-remote", "--heads", "origin", self.ref), f"{self.head}\t{self.ref}")
        receipts = list((self.repo / ".git/kgr-push-guards").glob("*/run.json"))
        self.assertEqual(len(receipts), 2)
        self.assertEqual([json.loads(r.read_text())["exitCode"] for r in receipts], [0, 0])

    def test_run_cli_routes_a_multi_argument_link(self):
        branch = self.ref.removeprefix("refs/heads/")
        result = self.run_with_native_cli("gh stack version 0.2.1\n", ("link", "1639", "1644", branch, "--remote", "origin"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("ls-remote", "--heads", "origin", self.ref), f"{self.head}\t{self.ref}")
        receipt = json.loads(next((self.repo / ".git/kgr-push-guards").glob("*/run.json")).read_text())
        self.assertEqual(receipt["command"][2:], ["link", "1639", "1644", branch, "--remote", "origin"])

    def test_command_that_is_not_gh_stack_runs_nothing(self):
        for output, code in [("gh version 2.83.0 (2026-10-01)\n", 0), ("gh stack version \n", 0),
                             ("gh stack version 0.2.1\nanother line\n", 0), ("gh-stack 0.2.1\n", 0),
                             ("", 0), ('unknown command "stack" for "gh"\n', 1)]:
            with self.subTest(output=output, code=code):
                self.git("push", "--quiet", "origin", "--delete", self.ref, check=False)
                shutil.rmtree(self.repo / ".git/kgr-push-guards", ignore_errors=True)
                result = self.run_with_native_cli(output, version_exit=code)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("command is not the gh-stack extension", result.stderr)
                self.assertEqual(self.git("ls-remote", "--heads", "origin", self.ref), "")
                self.assertFalse((self.repo / ".git/kgr-push-guards").exists())


if __name__ == "__main__":
    unittest.main()
