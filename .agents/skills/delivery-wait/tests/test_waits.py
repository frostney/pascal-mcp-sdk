#!/usr/bin/env python3
"""Behavioral tests for deterministic GitHub transition commands."""

from __future__ import annotations

import json
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DELIVERY = ROOT / "delivery-wait" / "scripts" / "delivery_wait.py"
REVIEW = ROOT / "address-feedback" / "scripts" / "review_wait.py"


FAKE_GH = r'''#!/usr/bin/env python3
import json, os, pathlib, sys

scenario = json.loads(pathlib.Path(os.environ["FAKE_GH_SCENARIO"]).read_text())
counter_path = pathlib.Path(os.environ["FAKE_GH_COUNTER"])
counter = int(counter_path.read_text()) if counter_path.exists() else 0
counter_path.write_text(str(counter + 1))
args = sys.argv[1:]
stdin = sys.stdin.read() if "--input" in args else ""
# A REST GET asks for headers and may repeat an ETag, as GitHub's API answers them.
include = "--include" in args
sent_etag = None
if "--header" in args:
    at = args.index("--header")
    sent_etag = args[at + 1].split(":", 1)[1].strip()
    del args[at:at + 2]
args = [arg.removeprefix("https://api.github.com/") for arg in args if arg != "--include"]
with open(os.environ["FAKE_GH_COUNTER"] + ".log", "a") as log:
    log.write(json.dumps({"args": args, "etag": sent_etag}) + "\n")
if counter < scenario.get("transientFailures", 0):
    print("connection reset by peer", file=sys.stderr)
    sys.exit(1)

def output(value=None, pages=None):
    """VALUE, or one page of PAGES as the endpoint's page parameter selects."""
    following = None
    if pages is not None:
        from urllib.parse import parse_qsl, urlencode, urlsplit
        path, _, query = endpoint.partition("?")
        params = [(key, item) for key, item in parse_qsl(query) if key != "page"]
        page = int(dict(parse_qsl(query)).get("page", 1))
        value = pages[page - 1]
        if page < len(pages):
            following = "https://api.github.com/" + path + "?" + urlencode(params + [("page", page + 1)])
    body = json.dumps(value)
    if not include:
        print(body)
        sys.exit(0)
    import hashlib
    etag = 'W/"' + hashlib.sha256(body.encode()).hexdigest() + '"'
    headers = ["ETag: " + etag]
    if following:
        headers.append(f'Link: <{following}>; rel="next"')
    if sent_etag == etag:
        print("HTTP/2.0 304 Not Modified\n" + "\r\n".join(headers) + "\r\n\r\n", end="")
        print("gh: HTTP 304", file=sys.stderr)
        sys.exit(1)
    if "coreRemaining" in scenario:
        headers += ["X-Ratelimit-Remaining: " + str(scenario["coreRemaining"]),
                    "X-Ratelimit-Reset: " + str(scenario["coreReset"]), "X-Ratelimit-Resource: core"]
    print("HTTP/2.0 200 OK\n" + "\r\n".join(headers) + "\r\n\r\n" + body)
    sys.exit(0)

def with_connection_counts(value):
    if isinstance(value, dict):
        if "nodes" in value and "pageInfo" in value:
            value["totalCount"] = len(value["nodes"])
        for item in value.values():
            with_connection_counts(item)
    elif isinstance(value, list):
        for item in value:
            with_connection_counts(item)
    return value

if args[:2] == ["api", "graphql"]:
    request = json.loads(stdin)
    query = request.get("query", "")
    if scenario.get("graphqlRateLimited") and counter == 0:
        print("GraphQL API rate limit exceeded", file=sys.stderr)
        sys.exit(1)
    if "resolveReviewThread" in query:
        scenario["thread"]["isResolved"] = True
        pathlib.Path(os.environ["FAKE_GH_SCENARIO"]).write_text(json.dumps(scenario))
        output({"data":{"resolveReviewThread":{"thread":{"id":request["variables"]["thread"],"isResolved":True}}}})
    if "node(id:" in query:
        output({"data":{"node":scenario["thread"]}})
    if "{headRefOid }" in query:
        # The review helper confirms another head by its head alone.
        if scenario.get("reviewHeadsByRequest"):
            heads = scenario["reviewHeadsByRequest"]
            scenario["review"]["headRefOid"] = heads[min(counter, len(heads) - 1)]
        output({"data":{"repository":{"pullRequest":{"headRefOid":scenario["review"]["headRefOid"]}}}})
    if "reviewThreads" in query and scenario.get("reviewCensusTimesOut"):
        print("gh: Something went wrong while executing your query. This may be the result of a timeout (HTTP 502)", file=sys.stderr)
        sys.exit(1)
    if "reviewThreads" in query and scenario.get("reviewQueriesAllowed") is not None:
        allowed = pathlib.Path(os.environ["FAKE_GH_COUNTER"] + ".review-queries")
        used = int(allowed.read_text()) if allowed.exists() else 0
        allowed.write_text(str(used + 1))
        if used >= scenario["reviewQueriesAllowed"]:
            print("gh: Resource limits for this query exceeded (RESOURCE_LIMITS_EXCEEDED)", file=sys.stderr)
            sys.exit(1)
    if "reviewThreads" in query:
        if scenario.get("reviewHeadsByRequest"):
            heads = scenario["reviewHeadsByRequest"]
            scenario["review"]["headRefOid"] = heads[min(counter, len(heads) - 1)]
        for review in scenario["review"]["reviews"]["nodes"]:
            review.setdefault("comments", {"nodes":[], "pageInfo":{"hasNextPage":False}})
        output({"data":{"repository":{"pullRequest":with_connection_counts(scenario["review"])}}})
    if "releaseAssets" in query:
        output({"data":{"repository":scenario["tag"]}})
    if "object(oid:" in query and "commitPages" in scenario:
        # Pages of a commit's rollup, keyed by the cursor that asks for each.
        page = scenario["commitPages"][request["variables"].get("after") or ""]
        output({"data":{"repository":{"object":{"__typename":"Commit","oid":request["variables"]["oid"],"statusCheckRollup":page}}}})
    if "object(oid:" in query:
        # A commit with no pull request; a missing "commit" is one GitHub does not know.
        # "commitsByRequest" gives one commit per lookup, the last repeating.
        commit = scenario.get("commit")
        if scenario.get("commitsByRequest"):
            lookups = pathlib.Path(os.environ["FAKE_GH_COUNTER"] + ".commits")
            seen = int(lookups.read_text()) if lookups.exists() else 0
            lookups.write_text(str(seen + 1))
            commit = scenario["commitsByRequest"][min(seen, len(scenario["commitsByRequest"]) - 1)]
        if commit is not None and "statusCheckRollup" not in query:
            commit = {key: value for key, value in commit.items() if key != "statusCheckRollup"}
        output({"data":{"repository":{"object":commit}}})
    pulls = scenario.get("pullsByRequest") or [scenario["pull"]]
    selected = pulls[min(counter, len(pulls) - 1)]
    if "state" not in query.split("commits(")[0].split():
        selected.pop("state", None)
    output({"data":{"repository":{"pullRequest":selected}}})

endpoint = next((arg for arg in args if arg.startswith("repos/")), "")
import time
if scenario.get("restSecondaryLimited") and include:
    print("HTTP/2.0 403 Forbidden\nRetry-After: 25\r\n\r\n" + json.dumps({"message": "secondary rate limit"}))
    print("gh: You have exceeded a secondary rate limit. (HTTP 403)", file=sys.stderr)
    sys.exit(1)
if scenario.get("restRateLimited") and include and time.time() < scenario["coreReset"]:
    print("HTTP/2.0 403 Forbidden\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: " + str(scenario["coreReset"])
          + "\r\nX-Ratelimit-Resource: core\r\n\r\n" + json.dumps({"message": "API rate limit exceeded"}))
    print("gh: API rate limit exceeded for user ID 1. (HTTP 403)", file=sys.stderr)
    sys.exit(1)
if "per_page=" in endpoint and "expectedRestPageSize" in scenario:
    from urllib.parse import parse_qs, urlsplit
    size = int(parse_qs(urlsplit(endpoint).query)["per_page"][0])
    if size != scenario["expectedRestPageSize"]:
        print("unexpected REST page size: " + str(size), file=sys.stderr)
        sys.exit(3)
if "user" in args:
    output({"login":"maintainer"})
if "/compare/" in endpoint:
    # GitHub's comparison of the observed head with the expected one, keyed "observed...expected".
    import time
    time.sleep(scenario.get("compareSeconds", 0))
    unavailable = pathlib.Path(os.environ["FAKE_GH_COUNTER"] + ".compare-unavailable")
    if scenario.get("compareUnavailableOnce") and not unavailable.exists():
        unavailable.write_text("1")
        print("HTTP/2.0 503 Service Unavailable\r\n\r\n" + json.dumps({"message": "unavailable"}))
        print("gh: Service Unavailable (HTTP 503)", file=sys.stderr)
        sys.exit(1)
    compared = scenario.get("compare", {}).get(endpoint.split("/compare/", 1)[1].split("?", 1)[0])
    if compared is None:
        print("HTTP/2.0 404 Not Found\r\n\r\n" + json.dumps({"message": "Not Found"}))
        print("gh: Not Found (HTTP 404)", file=sys.stderr)
        sys.exit(1)
    output(compared)
if endpoint.endswith("/pulls/comments/10"):
    output({"id":10,"pull_request_url":"https://api.github.com/repos/owner/repo/pulls/7","body":"finding","user":{"login":"reviewer"}})
if endpoint.endswith("/pulls/7"):
    output(scenario["restPull"])
import re
if re.fullmatch(r"repos/[^/]+/[^/]+/commits/[^/?]+", endpoint):
    if "restCommit" not in scenario:
        print("HTTP/2.0 404 Not Found\r\n\r\n" + json.dumps({"message": "Not Found"}))
        print("gh: Not Found (HTTP 404)", file=sys.stderr)
        sys.exit(1)
    output(scenario["restCommit"])
if "/check-runs" in endpoint:
    # GitHub numbers each check run and counts the list, as the census needs.
    page = scenario.get("restChecks", {"check_runs":[]})
    for index, item in enumerate(page["check_runs"]):
        item.setdefault("id", 9000 + index)
    page.setdefault("total_count", len(page["check_runs"]))
    output(pages=[page])
if "/statuses" in endpoint:
    output(pages=[scenario.get("restStatuses", [])])
if endpoint.endswith("/comments?per_page=100"):
    output(pages=[scenario.get("comments", [])])
if endpoint.endswith("/replies"):
    output({"id":901,"body":"created"})
if "/actions/runs?" in endpoint:
    census_path = pathlib.Path(os.environ["FAKE_GH_COUNTER"] + ".census")
    index = int(census_path.read_text()) if census_path.exists() else 0
    if "&page=" not in endpoint:
        census_path.write_text(str(index + 1))
    else:
        index -= 1
    states = scenario.get("census") or [{"runPages": [scenario.get("restWorkflowRuns", {"total_count": 0, "workflow_runs": []})]}]
    output(pages=states[min(index, len(states) - 1)]["runPages"])
if "/actions/runs/" in endpoint and "/jobs" in endpoint:
    census_path = pathlib.Path(os.environ["FAKE_GH_COUNTER"] + ".census")
    index = int(census_path.read_text()) - 1
    states = scenario["census"]
    run_id = endpoint.split("/actions/runs/", 1)[1].split("/", 1)[0]
    output(pages=states[min(index, len(states) - 1)]["jobPages"][run_id])
if "/actions/runs/" in endpoint:
    output(scenario["workflow"])
print("unexpected fake gh invocation: " + repr(args), file=sys.stderr)
sys.exit(3)
'''


def check(
    name: str,
    status: str,
    conclusion: str | None,
    started_at: str = "2026-08-12T08:00:00Z",
    app: str = "automated-review-app",
    completed_at: str | None = None,
    event: str | None = None,
    suite_id: int | None = None,
    workflow: int = 1,
) -> dict:
    """A check run; with an event, a job of a workflow triggered by that event."""
    suite = {"app": {"slug": app}, "databaseId": suite_id}
    if event:
        suite["workflowRun"] = {"event": event, "workflow": {"databaseId": workflow}}
    return {
        "__typename": "CheckRun",
        "id": f"check-{name}-{app}-{started_at}",
        "name": name,
        "status": status,
        "conclusion": conclusion,
        "detailsUrl": "https://example.invalid/check",
        "startedAt": started_at,
        "completedAt": completed_at or (started_at if status == "COMPLETED" else None),
        "checkSuite": suite,
    }


def pull(head: str, checks: list[dict], merged: bool = False, state: str | None = None) -> dict:
    return {
        "headRefOid": head,
        "state": state or ("MERGED" if merged else "OPEN"),
        "merged": merged,
        "mergedAt": "2026-08-12T08:00:00Z" if merged else None,
        "mergeCommit": {"oid": "merge-sha"} if merged else None,
        "commits": {"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":checks}}}}]},
    }


def workflow_job(job_id: int, name: str, status: str = "completed", conclusion: str | None = "success", run_id: int = 101) -> dict:
    return {
        "id": job_id,
        "run_id": run_id,
        "name": name,
        "status": status,
        "conclusion": conclusion,
        "completed_at": "2026-08-12T08:05:00Z" if status == "completed" else None,
    }


def workflow_run(
    run_id: int,
    jobs: list[dict],
    status: str = "completed",
    conclusion: str | None = "success",
    head: str = "head-1",
    name: str = "PR",
    workflow_id: int | None = None,
    event: str = "pull_request",
    check_suite_id: int | None = None,
    attempt: int = 1,
    branch: str = "feature",
    head_repository: int = 1,
    started_at: str | None = None,
    pull_requests: list[int] | None = None,
    created_at: str = "2026-08-12T08:00:00Z",
    updated_at: str = "2026-08-12T08:05:00Z",
) -> dict:
    return {
        "run": {
            "id": run_id,
            "name": name,
            **({"workflow_id": workflow_id} if workflow_id is not None else {}),
            **({"check_suite_id": check_suite_id} if check_suite_id is not None else {}),
            "event": event,
            "run_attempt": attempt,
            "head_sha": head,
            "head_branch": branch,
            "head_repository": {"id": head_repository},
            "created_at": created_at,
            "run_started_at": started_at or created_at,
            **({"pull_requests": [{"number": n} for n in pull_requests]} if pull_requests is not None else {}),
            "updated_at": updated_at,
            "status": status,
            "conclusion": conclusion,
            "html_url": f"https://example.invalid/runs/{run_id}",
        },
        "jobs": jobs,
    }


QUEUED_GH = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ["QUEUED_GH"]
queue = json.loads(open(path).read())
response = queue.pop(0)
open(path, "w").write(json.dumps(queue))
reason = {200: "OK", 304: "Not Modified", 403: "Forbidden", 429: "Too Many Requests"}[response["status"]]
head = "\r\n".join(f"{key}: {value}" for key, value in response["headers"].items())
body = json.dumps(response["body"]) if "body" in response else ""
print(f"HTTP/2.0 {response['status']} {reason}\n{head}\r\n\r\n{body}", end="")
if response["status"] >= 300:
    print(f"gh: {reason} (HTTP {response['status']})", file=sys.stderr)
    sys.exit(1)
'''


def parse_time(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def census(*runs: dict) -> dict:
    """One observation of every workflow run on a head and each run's jobs."""
    return {
        "runPages": [{"total_count": len(runs), "workflow_runs": [item["run"] for item in runs]}],
        "jobPages": {
            str(item["run"]["id"]): [{"total_count": len(item["jobs"]), "jobs": item["jobs"]}]
            for item in runs
        },
    }


def matrix_jobs(count: int, status: str = "completed", conclusion: str | None = "success", start: int = 0, run_id: int = 101) -> list[dict]:
    return [
        workflow_job(1000 + index, f"test ({index})", status, conclusion, run_id)
        for index in range(start, start + count)
    ]


class WaitCommandsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        fake = self.directory / "gh"
        fake.write_text(FAKE_GH)
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.scenario = self.directory / "scenario.json"
        self.counter = self.directory / "counter"
        self.environment = os.environ.copy()
        self.environment.update({
            "PATH": f"{self.directory}{os.pathsep}{self.environment['PATH']}",
            "FAKE_GH_SCENARIO": str(self.scenario),
            "FAKE_GH_COUNTER": str(self.counter),
        })
        self.environment["PYTHONDONTWRITEBYTECODE"] = "1"
        self.policy = self.directory / "policy.json"
        self.policy.write_text(json.dumps({"automations":[{
            "id":"automated-review", "actors":["review-bot[bot]"],
            "check_contexts":["Automated review"], "check_app_slugs":["automated-review-app"],
            "terminal_check_conclusions":["success"], "terminal_review_states":[],
            "nonterminal_review_markers":["rate limit"],
        }]}))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def deadline(self) -> str:
        return (datetime.now(timezone.utc) + timedelta(seconds=3)).isoformat()

    def run_json(self, script: Path, *args: str) -> tuple[subprocess.CompletedProcess[str], dict]:
        result = subprocess.run(
            [sys.executable, str(script), *args, "--json"],
            text=True,
            capture_output=True,
            cwd=self.directory,
            env=self.environment,
            timeout=6,
        )
        self.assertTrue(result.stdout, result.stderr)
        return result, json.loads(result.stdout)

    def write_scenario(self, **values: object) -> None:
        defaults = {
            "pull": pull("head-1", [check("CI", "COMPLETED", "SUCCESS")]),
            "restPull": {"head":{"sha":"head-1"},"merged":False,"merged_at":None,"merge_commit_sha":None},
            "review": {
                "headRefOid":"head-1",
                "comments":{"nodes":[],"pageInfo":{"hasNextPage":False}},
                "reviews":{"nodes":[],"pageInfo":{"hasNextPage":False}},
                "reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":False}},
                "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[check("Automated review","COMPLETED","SUCCESS")],"pageInfo":{"hasNextPage":False}}}}}]},
            },
            "tag":{"ref":None,"release":None},
            "workflow":{"id":44,"head_sha":"head-1","status":"completed","conclusion":"success","html_url":"https://example.invalid/run"},
            "thread":{"id":"thread-1","isResolved":False,"pullRequest":{"number":7,"headRefOid":"head-1","repository":{"nameWithOwner":"owner/repo"}}},
        }
        defaults.update(values)
        self.scenario.write_text(json.dumps(defaults))

    def test_terminal_checks_satisfy_without_model_polling(self) -> None:
        self.write_scenario()
        result, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--check", "CI", "--deadline", self.deadline(), "--interval", "0.01",
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["metrics"]["observations"], 1)

    def test_delivery_inspect_takes_one_snapshot_without_checkpoint(self) -> None:
        self.write_scenario()
        result, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--check", "CI",
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["metrics"]["observations"], 1)

    def test_completed_check_with_stale_status_satisfies_inspect_and_wait(self) -> None:
        completed_at = "2026-08-12T08:01:00Z"
        self.write_scenario(
            pull=pull(
                "head-1",
                [check("CI", "IN_PROGRESS", "SUCCESS", completed_at=completed_at)],
            )
        )
        _, inspected = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--check", "CI",
        )
        _, waited = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--check", "CI", "--deadline", self.deadline(), "--interval", "0.01",
        )
        self.assertEqual(inspected["state"], "satisfied")
        self.assertEqual(waited["state"], "satisfied")
        self.assertEqual(waited["metrics"]["observations"], 1)
        self.assertEqual(inspected["observation"]["checks"][0]["status"], "IN_PROGRESS")
        self.assertEqual(inspected["observation"]["checks"][0]["completedAt"], completed_at)

    def test_success_without_completion_remains_waiting(self) -> None:
        self.write_scenario(
            pull=pull("head-1", [check("CI", "IN_PROGRESS", "SUCCESS")])
        )
        _, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--check", "CI",
        )
        self.assertEqual(output["state"], "waiting")

    def test_a_running_context_keeps_its_check_name_waiting(self) -> None:
        self.write_scenario(
            pull=pull(
                "head-1",
                [
                    check("CI", "COMPLETED", "SUCCESS", "2026-08-12T08:00:00Z"),
                    check("CI", "IN_PROGRESS", None, "2026-08-12T08:01:00Z"),
                ],
            )
        )
        _, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--check", "CI",
        )
        self.assertEqual(output["state"], "waiting")

    def test_wait_rejects_a_deadline_without_timezone(self) -> None:
        self.write_scenario()
        result, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--check", "CI",
            "--deadline", "2026-08-12T12:00:00", "--interval", "0.01",
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(output["state"], "operational-error")
        self.assertIn("timezone", output["reason"])

    def test_head_change_invalidates(self) -> None:
        self.write_scenario(pull=pull("head-2", []), compare={"head-2...head-1": {"status": "behind"}})
        _, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--check", "CI", "--deadline", self.deadline(), "--interval", "0.01",
        )
        self.assertEqual(output["state"], "invalidated")
        self.assertEqual(output["observation"]["head"], "head-2")
        self.assertIn("a later commit than the expected one", output["reason"])
        self.assertEqual(output["metrics"]["observations"], 1)

    def lagging_head_wait(self, *selector: str, state: Path | None = None, seconds: float = 3) -> dict:
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()
        return self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
            *(selector or ("--check", "CI")), "--deadline", deadline, "--interval", "0.05",
            *(("--state", str(state)) if state else ()),
        )[1]

    def test_a_wait_armed_right_after_a_push_waits_for_github_to_move_the_head(self) -> None:
        # Seen in practice: GitHub still reported the head before the push.
        for relation, status in (("ancestor", "ahead"), ("diverged", "diverged")):
            with self.subTest(relation=relation):
                self.counter.unlink(missing_ok=True)
                before = pull("head-0", [check("CI", "COMPLETED", "SUCCESS")])
                self.write_scenario(
                    pullsByRequest=[before] * 4 + [pull("head-1", [check("CI", "IN_PROGRESS", None)])] * 4
                    + [pull("head-1", [check("CI", "COMPLETED", "SUCCESS")])],
                    compare={"head-0...head-1": {"status": status}},
                )
                output = self.lagging_head_wait(state=self.directory / f"{relation}.json")
                self.assertEqual(output["state"], "satisfied", output["reason"])
                self.assertEqual(output["observation"]["head"], "head-1")
                self.assertGreaterEqual(output["metrics"]["observations"], 4)

    def test_a_lagging_head_is_reported_as_waiting_with_its_relation(self) -> None:
        self.write_scenario(pull=pull("head-0", []), compare={"head-0...head-1": {"status": "ahead"}})
        _, inspected = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--check", "CI",
        )
        self.assertEqual(inspected["state"], "waiting")
        self.assertIn("an ancestor of the expected commit", inspected["reason"])
        self.assertEqual(inspected["observation"]["headLag"]["relation"], "ancestor")
        # A commit GitHub does not know yet is given the same grace.
        self.write_scenario(pull=pull("head-0", []))
        state = self.directory / "wait.json"
        output = self.lagging_head_wait(state=state, seconds=0.3)
        self.assertEqual(output["state"], "timed-out")
        self.assertEqual(output["observation"]["headLag"]["relation"], "missing")

    def test_a_resumed_wait_keeps_the_grace_its_first_lagging_observation_started(self) -> None:
        self.write_scenario(pull=pull("head-0", []), compare={"head-0...head-1": {"status": "ahead"}})
        state = self.directory / "wait.json"
        first = self.lagging_head_wait(state=state, seconds=0.3)
        self.assertEqual(first["state"], "timed-out")
        since = first["observation"]["headLag"]["since"]
        second = self.lagging_head_wait(state=state, seconds=0.3)
        self.assertEqual(second["state"], "timed-out")
        self.assertEqual(second["observation"]["headLag"]["since"], since)
        # Once the grace has passed, a head that never moved invalidates the wait.
        checkpoint = json.loads(state.read_text())
        checkpoint["expectedHead"]["since"] = "2026-08-12T08:00:00Z"
        state.write_text(json.dumps(checkpoint))
        self.counter.with_name("counter.log").unlink()
        expired = self.lagging_head_wait(state=state)
        self.assertEqual(expired["state"], "invalidated")
        self.assertIn("expected head head-1, observed head-0", expired["reason"])
        self.assertIn("check that the push reached", expired["reason"])
        self.assertEqual(expired["metrics"]["observations"], 1)
        # GitHub is not asked again once the grace has passed.
        self.assertNotIn("/compare/", self.counter.with_name("counter.log").read_text())

    def test_a_head_that_moves_off_the_expected_one_invalidates_at_once(self) -> None:
        # Seen by this wait, then replaced: even an ancestor is not a lag.
        self.write_scenario(pull=pull("head-1", [check("CI", "IN_PROGRESS", None)]))
        state = self.directory / "wait.json"
        self.assertEqual(self.lagging_head_wait(state=state, seconds=0.3)["state"], "timed-out")
        self.write_scenario(pull=pull("head-0", []), compare={"head-0...head-1": {"status": "ahead"}})
        output = self.lagging_head_wait(state=state)
        self.assertEqual(output["state"], "invalidated")
        self.assertEqual(output["reason"], "expected head head-1, observed head-0, after this wait had seen the expected head")
        # The checkpoint keeps that the expected head was seen, so a rerun gives no grace either.
        again = self.lagging_head_wait(state=state)
        self.assertEqual(again["state"], "invalidated")
        self.assertEqual(again["observation"]["headLag"], {"relation": "replaced"})
        self.assertNotIn("/compare/", self.counter.with_name("counter.log").read_text())

    def test_a_head_read_before_a_failed_census_counts_as_seen(self) -> None:
        # The census for head-1 is incomplete, then GitHub reports head-0.
        incomplete = {"runPages": [{"total_count": 2, "workflow_runs": []}], "jobPages": {}}
        self.write_scenario(
            pullsByRequest=[pull("head-1", [])] * 2 + [pull("head-0", [])],
            census=[incomplete], compare={"head-0...head-1": {"status": "ahead"}},
        )
        _, output = self.census_wait()
        self.assertEqual(output["state"], "invalidated")
        self.assertIn("after this wait had seen the expected head", output["reason"])

    def test_the_expected_head_stays_seen_when_every_census_after_it_failed(self) -> None:
        incomplete = {"runPages": [{"total_count": 2, "workflow_runs": []}], "jobPages": {}}
        self.write_scenario(pull=pull("head-1", []), census=[incomplete])
        state = self.directory / "wait.json"
        self.assertEqual(self.lagging_head_wait("--all-workflows", state=state, seconds=0.3)["state"], "timed-out")
        self.assertEqual(json.loads(state.read_text()).get("expectedHead", {}).get("seen"), True)
        self.write_scenario(pull=pull("head-0", []), census=[incomplete], compare={"head-0...head-1": {"status": "ahead"}})
        output = self.lagging_head_wait("--all-workflows", state=state)
        self.assertEqual(output["state"], "invalidated")
        self.assertIn("after this wait had seen the expected head", output["reason"])

    def test_the_checks_of_another_head_are_not_read(self) -> None:
        # Through the REST fallback, no check runs or statuses are read for a lagging head.
        self.write_scenario(
            graphqlRateLimited=True, restPull={"head": {"sha": "head-0"}, "merged": False, "merged_at": None, "merge_commit_sha": None},
            compare={"head-0...head-1": {"status": "ahead"}},
        )
        _, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", "--check", "CI",
        )
        self.assertEqual(output["state"], "waiting", output["reason"])
        log = self.counter.with_name("counter.log").read_text()
        self.assertNotIn("/check-runs", log)
        self.assertNotIn("/statuses", log)
        # Nor are more than 100 contexts on a lagging head an error.
        crowded = pull("head-0", [])
        crowded["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["pageInfo"] = {"hasNextPage": True}
        self.write_scenario(pull=crowded, compare={"head-0...head-1": {"status": "ahead"}})
        _, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", "--check", "CI",
        )
        self.assertEqual(output["state"], "waiting", output["reason"])

    def test_a_retry_after_a_lagging_head_still_looks_again_when_its_grace_ends(self) -> None:
        self.write_scenario(pull=pull("head-0", []), compare={"head-0...head-1": {"status": "ahead"}})
        state = self.directory / "wait.json"
        self.lagging_head_wait(state=state, seconds=0.3)
        checkpoint = json.loads(state.read_text())
        almost = (datetime.now(timezone.utc) - timedelta(seconds=299)).isoformat().replace("+00:00", "Z")
        soon = (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat().replace("+00:00", "Z")
        checkpoint.setdefault("expectedHead", {})["since"] = almost
        checkpoint["observation"]["headLag"].update(since=almost, until=soon)
        state.write_text(json.dumps(checkpoint))
        self.counter.unlink()
        self.write_scenario(
            pull=pull("head-0", []), compare={"head-0...head-1": {"status": "ahead"}}, transientFailures=1,
        )
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=5.5)).isoformat()
        started = time.monotonic()
        _, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
            "--check", "CI", "--deadline", deadline, "--interval", "600", "--state", str(state),
        )
        self.assertEqual(output["state"], "invalidated", output["reason"])
        self.assertEqual(output["metrics"]["retries"], 1)
        self.assertLess(time.monotonic() - started, 4)

    def grace_nearly_over(self, state: Path, seconds_left: float) -> None:
        """A checkpoint of a lagging wait whose grace ends SECONDS_LEFT from now."""
        self.write_scenario(pull=pull("head-0", []), compare={"head-0...head-1": {"status": "ahead"}})
        self.lagging_head_wait(state=state, seconds=0.3)
        checkpoint = json.loads(state.read_text())
        since = datetime.now(timezone.utc) - timedelta(seconds=300 - seconds_left)
        checkpoint["expectedHead"]["since"] = since.isoformat().replace("+00:00", "Z")
        checkpoint["observation"]["headLag"].update(
            since=checkpoint["expectedHead"]["since"],
            until=(since + timedelta(seconds=300)).isoformat().replace("+00:00", "Z"),
        )
        state.write_text(json.dumps(checkpoint))
        self.counter.unlink()

    def slow_wait(self, state: Path, seconds: float) -> tuple[dict, float]:
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()
        started = time.monotonic()
        result = subprocess.run(
            [sys.executable, str(DELIVERY), "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
             "--head", "head-1", "--check", "CI", "--deadline", deadline, "--interval", "600",
             "--state", str(state), "--json"],
            text=True, capture_output=True, cwd=self.directory, env=self.environment, timeout=seconds + 5,
        )
        return json.loads(result.stdout), time.monotonic() - started

    def test_a_head_read_before_the_grace_ended_is_read_again_before_it_expires_the_wait(self) -> None:
        # The comparison finishes after the grace ends; the head GitHub then reports decides.
        state = self.directory / "wait.json"
        self.grace_nearly_over(state, 0.5)
        arrived = pull("head-1", [check("CI", "COMPLETED", "SUCCESS")])
        self.write_scenario(
            pullsByRequest=[pull("head-0", [])] * 2 + [arrived],
            compare={"head-0...head-1": {"status": "ahead"}}, compareSeconds=1,
        )
        output, elapsed = self.slow_wait(state, 6)
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertLess(elapsed, 4)

    def test_a_comparison_that_fails_at_the_end_of_the_grace_is_retried_promptly(self) -> None:
        state = self.directory / "wait.json"
        self.grace_nearly_over(state, 0.5)
        arrived = pull("head-1", [check("CI", "COMPLETED", "SUCCESS")])
        self.write_scenario(
            pullsByRequest=[pull("head-0", [])] * 2 + [arrived],
            compare={"head-0...head-1": {"status": "ahead"}}, compareUnavailableOnce=True, compareSeconds=1,
        )
        output, elapsed = self.slow_wait(state, 10)
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertEqual(output["metrics"]["retries"], 1)
        # FOLLOW_UP_RETRY seconds later, not at the deadline.
        self.assertLess(elapsed, 8.5)

    def test_the_expected_head_stays_seen_after_an_operational_error(self) -> None:
        crowded = pull("head-1", [])
        crowded["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["pageInfo"] = {"hasNextPage": True}
        # Pages past the helper's limit are an error, not a retry.
        endless = {("" if n == 0 else f"c{n}"): {"contexts": {"nodes": [], "totalCount": 0, "pageInfo": {"hasNextPage": True, "endCursor": f"c{n + 1}"}}}
                   for n in range(60)}
        self.write_scenario(pull=crowded, commitPages=endless)
        state = self.directory / "wait.json"
        self.assertEqual(self.lagging_head_wait(state=state, seconds=0.3)["state"], "operational-error")
        self.write_scenario(pull=pull("head-0", []), compare={"head-0...head-1": {"status": "ahead"}})
        output = self.lagging_head_wait(state=state)
        self.assertEqual(output["state"], "invalidated")
        self.assertIn("after this wait had seen the expected head", output["reason"])

    def test_a_checkpoint_digest_of_no_head_is_no_baseline(self) -> None:
        self.write_scenario(pull=pull("head-1", [check("CI", "IN_PROGRESS", None)]))
        state = self.directory / "wait.json"
        self.lagging_head_wait(state=state, seconds=0.3)
        checkpoint = json.loads(state.read_text())
        checkpoint.pop("expectedHead", None)
        checkpoint["observation"] = {"head": None, "checks": []}
        checkpoint["digest"] = "0" * 64
        state.write_text(json.dumps(checkpoint))
        self.assertEqual(self.lagging_head_wait(state=state, seconds=0.3)["state"], "timed-out")

    def test_a_checkpoint_digest_of_another_head_is_no_baseline(self) -> None:
        # An earlier helper saved the stale head's digest when it invalidated the wait.
        self.write_scenario(pull=pull("head-0", []), compare={"head-0...head-1": {"status": "ahead"}})
        for selector in (("--check", "CI"), ("--all-workflows",)):
            with self.subTest(selector=selector):
                state = self.directory / f"{selector[0]}.json"
                self.write_scenario(pull=pull("head-0", []), compare={"head-0...head-1": {"status": "ahead"}})
                self.lagging_head_wait(*selector, state=state, seconds=0.3)
                checkpoint = json.loads(state.read_text())
                checkpoint["observation"].pop("headLag")
                checkpoint["digest"] = "0" * 64
                for lagging in (True, False):
                    state.write_text(json.dumps(checkpoint))
                    arrived = [pull("head-1", [check("CI", "IN_PROGRESS", None)])]
                    self.write_scenario(
                        pullsByRequest=([pull("head-0", [])] * 2 if lagging else []) + arrived,
                        census=[census(workflow_run(101, matrix_jobs(1, "in_progress", None), status="in_progress", conclusion=None))],
                        compare={"head-0...head-1": {"status": "ahead"}},
                    )
                    self.counter.unlink(missing_ok=True)
                    output = self.lagging_head_wait(*selector, state=state, seconds=0.5)
                    self.assertEqual(output["state"], "timed-out", output["reason"])

    def test_a_lagging_head_is_looked_at_again_when_its_grace_ends(self) -> None:
        self.write_scenario(pull=pull("head-0", []), compare={"head-0...head-1": {"status": "ahead"}})
        state = self.directory / "wait.json"
        self.lagging_head_wait(state=state, seconds=0.3)
        checkpoint = json.loads(state.read_text())
        almost = datetime.now(timezone.utc) - timedelta(seconds=299)
        checkpoint["expectedHead"]["since"] = almost.isoformat().replace("+00:00", "Z")
        state.write_text(json.dumps(checkpoint))
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=5.5)).isoformat()
        started = time.monotonic()
        _, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
            "--check", "CI", "--deadline", deadline, "--interval", "600", "--state", str(state),
        )
        self.assertEqual(output["state"], "invalidated", output["reason"])
        self.assertEqual(output["metrics"]["observations"], 2)
        # It looked again when the grace ended, not at the deadline or after the interval.
        self.assertLess(time.monotonic() - started, 4)

    def test_deadline_performs_a_final_authoritative_observation(self) -> None:
        self.write_scenario()
        past = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
        _, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--check", "CI",
            "--deadline", past, "--interval", "0.01",
        )
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["metrics"]["observations"], 1)

    def test_graphql_rate_limit_falls_back_to_rest(self) -> None:
        self.write_scenario(
            graphqlRateLimited=True,
            restChecks={"check_runs":[{"name":"CI","status":"completed","conclusion":"success"}]},
            restStatuses=[],
        )
        _, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--check", "CI", "--deadline", self.deadline(), "--interval", "0.01",
        )
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["metrics"]["rateLimitFallbacks"], 1)

    def test_rest_fallback_accepts_completed_check_with_stale_status(self) -> None:
        completed_at = "2026-08-12T08:01:00Z"
        self.write_scenario(
            graphqlRateLimited=True,
            restChecks={"check_runs":[{
                "name":"CI", "status":"in_progress", "conclusion":"success",
                "started_at":"2026-08-12T08:00:00Z", "completed_at":completed_at,
            }]},
            restStatuses=[],
        )
        _, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--check", "CI", "--deadline", self.deadline(), "--interval", "0.01",
        )
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["metrics"]["observations"], 1)
        self.assertEqual(output["observation"]["checks"][0]["status"], "IN_PROGRESS")
        self.assertEqual(output["observation"]["checks"][0]["completedAt"], completed_at)

    def test_checkpoint_reconciliation_reports_missed_change(self) -> None:
        self.write_scenario(pull=pull("head-1", []))
        state = self.directory / "wait.json"
        state.write_text(json.dumps({
            "schemaVersion":1, "kind":"checks-terminal",
            "identity":{"repo":"owner/repo","pr":7,"head":"head-1","runId":None,"tag":None,"checks":["CI"],"assets":[]},
            "observation":{"head":"head-1","checks":[]}, "digest":"old", "updatedAt":"earlier",
        }))
        _, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--check", "CI", "--deadline", self.deadline(), "--interval", "0.01", "--state", str(state),
        )
        self.assertEqual(output["state"], "changed")

    def named_check_wait(self, *checks: str, state: Path | None = None, seconds: float = 0.3) -> dict:
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()
        return self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", *(part for name in checks for part in ("--check", name)),
            "--deadline", deadline, "--interval", "0.05",
            *(("--state", str(state)) if state else ()),
        )[1]

    def test_named_check_wait_ignores_checks_it_was_not_asked_about(self) -> None:
        pending = check("CI", "IN_PROGRESS", None)
        others = [check(f"other {conclusion}", "COMPLETED", conclusion) for conclusion in ("SKIPPED", "NEUTRAL", "FAILURE")]
        with self.subTest("one wait"):
            self.write_scenario(pullsByRequest=[pull("head-1", [pending]), pull("head-1", [pending, *others])])
            output = self.named_check_wait("CI", seconds=2)
            self.assertEqual(output["state"], "timed-out")
            self.assertEqual(len(output["observation"]["checks"]), 4)
        with self.subTest("resumed checkpoint"):
            state = self.directory / "wait.json"
            self.write_scenario(pull=pull("head-1", [pending]))
            self.assertEqual(self.named_check_wait("CI", state=state)["state"], "timed-out")
            self.write_scenario(pull=pull("head-1", [pending, *others]))
            self.assertEqual(self.named_check_wait("CI", state=state)["state"], "timed-out")

    def test_named_checks_are_judged_alone_and_pass_when_skipped_or_neutral(self) -> None:
        self.write_scenario(pull=pull("head-1", [
            check("CI", "COMPLETED", "SKIPPED"),
            check("Lint", "COMPLETED", "NEUTRAL"),
            check("optional", "COMPLETED", "FAILURE"),
        ]))
        output = self.named_check_wait("CI", "Lint", seconds=3)
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["metrics"]["observations"], 1)

    def test_named_check_failure_wakes_the_wait_while_another_named_check_runs(self) -> None:
        deploy = check("Deploy", "IN_PROGRESS", None)
        self.write_scenario(pullsByRequest=[
            pull("head-1", [check("CI", "IN_PROGRESS", None), deploy]),
            pull("head-1", [check("CI", "COMPLETED", "FAILURE"), deploy]),
        ])
        output = self.named_check_wait("CI", "Deploy", seconds=3)
        self.assertEqual(output["state"], "changed")
        self.assertIn("non-success terminal result: CI", output["reason"])
        self.assertEqual(output["metrics"]["observations"], 2)

    def test_named_check_that_ends_skipped_or_neutral_does_not_wake_the_wait(self) -> None:
        deploy = check("Deploy", "IN_PROGRESS", None)
        state = self.directory / "wait.json"
        self.write_scenario(pull=pull("head-1", [check("CI", "IN_PROGRESS", None), check("Lint", "IN_PROGRESS", None), deploy]))
        self.assertEqual(self.named_check_wait("CI", "Lint", "Deploy", state=state)["state"], "timed-out")
        self.write_scenario(pull=pull("head-1", [check("CI", "COMPLETED", "SKIPPED"), check("Lint", "COMPLETED", "NEUTRAL"), deploy]))
        self.assertEqual(self.named_check_wait("CI", "Lint", "Deploy", state=state)["state"], "timed-out")

    def test_named_check_that_already_failed_ends_the_wait_while_others_run(self) -> None:
        self.write_scenario(pull=pull("head-1", [
            check("CI", "COMPLETED", "FAILURE"), check("Deploy", "IN_PROGRESS", None),
        ]))
        _, inspected = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--check", "CI", "--check", "Deploy",
        )
        self.assertEqual(inspected["state"], "changed")
        self.assertIn("CI", inspected["reason"])
        output = self.named_check_wait("CI", "Deploy", seconds=3)
        self.assertEqual(output["state"], "changed")
        self.assertEqual(output["metrics"]["observations"], 1)

    def test_every_source_of_a_check_name_must_pass(self) -> None:
        # One workflow on both push and pull_request runs each job twice per head.
        for name, runs, expected in (
            ("push failed, pull_request passed", [("push", 1, "automated-review-app", "FAILURE"), ("pull_request", 1, "automated-review-app", "SUCCESS")], "changed"),
            ("push failed, pull_request running", [("push", 1, "automated-review-app", "FAILURE"), ("pull_request", 1, "automated-review-app", None)], "changed"),
            ("both passed", [("push", 1, "automated-review-app", "SUCCESS"), ("pull_request", 1, "automated-review-app", "SUCCESS")], "satisfied"),
            ("two workflows with one job name", [("pull_request", 1, "automated-review-app", "FAILURE"), ("pull_request", 2, "automated-review-app", "SUCCESS")], "changed"),
            ("two apps with one check name", [(None, 1, "vercel", "FAILURE"), (None, 1, "netlify", "SUCCESS")], "changed"),
        ):
            with self.subTest(name):
                shutil.rmtree(self.directory / ".agent", ignore_errors=True)
                self.write_scenario(pull=pull("head-1", [
                    check("test", "COMPLETED" if conclusion else "IN_PROGRESS", conclusion, f"2026-08-12T08:00:0{index}Z",
                          app=app, event=event, suite_id=10 + index, workflow=workflow)
                    for index, (event, workflow, app, conclusion) in enumerate(runs)
                ]))
                self.assertEqual(self.named_check_wait("test", seconds=3)["state"], expected)

    def test_a_newer_check_suite_from_the_same_source_replaces_the_older(self) -> None:
        # A run cancelled by a newer one, or a re-check after an edit, stays on the head.
        # A newer suite's job can start before an older suite's job does.
        for name, older, newer, newer_started, expected in (
            ("failure then success", "FAILURE", "SUCCESS", "2026-09-08T07:43:45Z", "satisfied"),
            ("cancelled then success", "CANCELLED", "SUCCESS", "2026-09-08T07:43:45Z", "satisfied"),
            ("success then failure", "SUCCESS", "FAILURE", "2026-09-08T07:43:45Z", "changed"),
            ("newer suite started first and failed", "SUCCESS", "FAILURE", "2026-09-08T07:43:05Z", "changed"),
        ):
            with self.subTest(name):
                shutil.rmtree(self.directory / ".agent", ignore_errors=True)
                self.write_scenario(pull=pull("head-1", [
                    check("conventional-title", "COMPLETED", newer, newer_started, event="pull_request", suite_id=12),
                    check("conventional-title", "COMPLETED", older, "2026-09-08T07:43:25Z", event="pull_request", suite_id=11),
                ]))
                self.assertEqual(self.named_check_wait("conventional-title", seconds=3)["state"], expected)

    def test_jobs_with_one_name_in_one_suite_all_count(self) -> None:
        self.write_scenario(pull=pull("head-1", [
            check("test", "COMPLETED", "SUCCESS", "2026-08-12T08:00:05Z", event="pull_request", suite_id=11),
            check("test", "COMPLETED", "FAILURE", "2026-08-12T08:00:00Z", event="pull_request", suite_id=11),
        ]))
        self.assertEqual(self.named_check_wait("test", seconds=3)["state"], "changed")

    def test_rest_fallback_finds_the_source_of_each_check_run(self) -> None:
        older = {"name": "test", "status": "completed", "conclusion": "failure", "started_at": "2026-08-12T08:00:05Z", "id": 1, "app": {"slug": "github-actions"}, "check_suite": {"id": 11}}
        newer = {"name": "test", "status": "completed", "conclusion": "success", "started_at": "2026-08-12T08:00:00Z", "id": 2, "app": {"slug": "github-actions"}, "check_suite": {"id": 12}}
        for events, expected in ((("pull_request", "pull_request"), "satisfied"), (("push", "pull_request"), "changed")):
            with self.subTest(events=events):
                self.counter.unlink(missing_ok=True)
                self.counter.with_name("counter.census").unlink(missing_ok=True)
                shutil.rmtree(self.directory / ".agent", ignore_errors=True)
                self.write_scenario(
                    graphqlRateLimited=True,
                    restChecks={"check_runs": [newer, older]},
                    restWorkflowRuns={"total_count": 2, "workflow_runs": [
                        {"id": 100 + index, "check_suite_id": suite, "workflow_id": 1, "event": event}
                        for index, (suite, event) in enumerate(zip((11, 12), events))
                    ]},
                )
                output = self.named_check_wait("test", seconds=3)
                self.assertEqual(output["state"], expected)
                self.assertEqual(output["metrics"]["rateLimitFallbacks"], 1)

    def test_rest_fallback_waits_until_every_actions_run_is_listed(self) -> None:
        run = {"name": "test", "status": "completed", "conclusion": "success", "started_at": "2026-08-12T08:00:00Z", "id": 1, "app": {"slug": "github-actions"}, "check_suite": {"id": 11}}
        self.write_scenario(graphqlRateLimited=True, restChecks={"check_runs": [run]})
        output = self.named_check_wait("test")
        self.assertEqual(output["state"], "timed-out")
        self.assertGreater(output["metrics"]["retries"], 0)

    def test_named_check_that_failed_to_start_or_went_stale_ends_the_wait(self) -> None:
        # Both are conclusions in GitHub's GraphQL CheckConclusionState.
        for conclusion in ("STARTUP_FAILURE", "STALE"):
            with self.subTest(conclusion=conclusion):
                self.write_scenario(pull=pull("head-1", [check("CI", "COMPLETED", conclusion)]))
                _, output = self.run_json(
                    DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
                    "--pr", "7", "--head", "head-1", "--check", "CI",
                )
                self.assertEqual(output["state"], "changed")

    def test_rest_fallback_judges_a_commit_status_by_its_latest_state(self) -> None:
        # GitHub lists statuses newest first; one context can change twice in a second.
        for history, expected in (
            ([("failure", "08:00"), ("success", "08:05")], "satisfied"),
            ([("success", "08:00"), ("failure", "08:05")], "changed"),
            ([("pending", "08:00"), ("success", "08:00")], "satisfied"),
        ):
            with self.subTest(expected=expected):
                self.counter.unlink(missing_ok=True)
                shutil.rmtree(self.directory / ".agent", ignore_errors=True)
                self.write_scenario(
                    graphqlRateLimited=True,
                    restStatuses=[
                        {"context": "Vercel", "state": state, "created_at": f"2026-08-12T{time}:00Z"}
                        for state, time in reversed(history)
                    ],
                )
                output = self.named_check_wait("Vercel", seconds=3)
                self.assertEqual(output["state"], expected)
                self.assertEqual(len(output["observation"]["checks"]), 1)

    def test_checkpoint_from_the_earlier_helper_resumes_without_a_change(self) -> None:
        # The earlier key listed every terminal check that did not succeed.
        pending = check("CI", "IN_PROGRESS", None)
        skipped = check("optional", "COMPLETED", "SKIPPED")
        self.write_scenario(pull=pull("head-1", [pending, skipped]))
        state = self.directory / "wait.json"
        self.assertEqual(self.named_check_wait("CI", state=state)["state"], "timed-out")
        checkpoint = json.loads(state.read_text())
        earlier = {"head": "head-1", "nonSuccess": ["optional"], "terminal": False}
        checkpoint["digest"] = hashlib.sha256(
            json.dumps(earlier, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        state.write_text(json.dumps(checkpoint))
        self.assertEqual(self.named_check_wait("CI", state=state)["state"], "timed-out")
        self.write_scenario(pull=pull("head-1", [check("CI", "COMPLETED", "FAILURE"), skipped]))
        state.write_text(json.dumps(checkpoint))
        self.assertEqual(self.named_check_wait("CI", state=state)["state"], "changed")
        # A wait for other checks on the same state file leaves it untouched.
        self.write_scenario(pull=pull("head-1", [pending, skipped]))
        state.write_text(json.dumps(checkpoint))
        self.assertEqual(self.named_check_wait("optional", state=state)["state"], "invalidated")
        self.assertEqual(json.loads(state.read_text())["digest"], checkpoint["digest"])
        self.assertEqual(self.named_check_wait("CI", state=state)["state"], "timed-out")

    def merge_wait(self, command: str = "wait", seconds: float = 3) -> dict:
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()
        timing = ("--deadline", deadline, "--interval", "0.05") if command == "wait" else ()
        return self.run_json(
            DELIVERY, command, "pr-merged", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", *timing,
        )[1]

    def test_pr_merged_reports_a_merge(self) -> None:
        self.write_scenario(pull=pull("head-1", [], merged=True))
        output = self.merge_wait()
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["observation"]["mergeCommit"], "merge-sha")

    def test_pr_merged_keeps_waiting_on_an_open_pull_request(self) -> None:
        self.write_scenario(pull=pull("head-1", []))
        output = self.merge_wait(seconds=0.3)
        self.assertEqual(output["state"], "timed-out")
        self.assertEqual(output["reason"], "deadline reached")

    def test_pr_merged_ends_when_the_pull_request_closes_without_merging(self) -> None:
        self.write_scenario(pull=pull("head-1", [], state="CLOSED"))
        for command in ("wait", "inspect"):
            with self.subTest(command=command):
                output = self.merge_wait(command)
                self.assertEqual(output["state"], "changed")
                self.assertIn("closed without merging", output["reason"])
                self.assertEqual(output["metrics"]["observations"], 1)
        self.write_scenario(pull=pull("head-2", [], state="CLOSED"), compare={"head-2...head-1": {"status": "behind"}})
        self.assertEqual(self.merge_wait()["state"], "invalidated")

    def test_pr_merged_rest_fallback_tells_closed_from_merged(self) -> None:
        # REST gives an unmerged pull request its test merge commit.
        for rest, state, merge_commit, expected in (
            ({"state": "closed", "merged": False, "merged_at": None, "merge_commit_sha": "test-merge-sha"}, "CLOSED", None, "changed"),
            ({"state": "closed", "merged": True, "merged_at": "2026-08-12T08:00:00Z", "merge_commit_sha": "merge-sha"}, "MERGED", "merge-sha", "satisfied"),
        ):
            with self.subTest(expected=expected):
                self.counter.unlink(missing_ok=True)
                shutil.rmtree(self.directory / ".agent", ignore_errors=True)
                self.write_scenario(graphqlRateLimited=True, restPull={"head": {"sha": "head-1"}, **rest})
                output = self.merge_wait()
                self.assertEqual(output["state"], expected)
                self.assertEqual(output["observation"]["state"], state)
                self.assertEqual(output["observation"]["mergeCommit"], merge_commit)
                self.assertEqual(output["metrics"]["rateLimitFallbacks"], 1)

    def write_digestless_checkpoint(self, *arguments: str) -> None:
        """Leave the checkpoint a run writes when GitHub never answered."""
        self.write_scenario(transientFailures=10**6)
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=0.3)).isoformat()
        _, first = self.run_json(*arguments, "--deadline", deadline)
        self.assertEqual(first["state"], "timed-out")
        self.assertGreater(first["metrics"]["retries"], 0)
        self.assertIsNone(json.loads(Path(arguments[-1]).read_text())["digest"])

    def test_digestless_checkpoint_does_not_turn_a_satisfied_review_into_changed(self) -> None:
        state = self.directory / "review.json"
        arguments = (
            REVIEW, "wait", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
            "--policy", str(self.policy), "--interval", "0.01", "--state", str(state),
        )
        self.write_digestless_checkpoint(*arguments)
        self.write_scenario()
        _, output = self.run_json(*arguments, "--deadline", self.deadline())
        self.assertEqual(output["state"], "satisfied")

    def test_digestless_checkpoint_does_not_turn_a_pending_wait_into_changed(self) -> None:
        state = self.directory / "wait.json"
        arguments = (
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--check", "CI", "--interval", "0.01", "--state", str(state),
        )
        self.write_digestless_checkpoint(*arguments)
        self.write_scenario(pull=pull("head-1", []))
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=0.3)).isoformat()
        _, output = self.run_json(*arguments, "--deadline", deadline)
        self.assertEqual(output["state"], "timed-out")

    def test_wake_at_waits_for_each_deadline_despite_an_earlier_wake(self) -> None:
        state = self.directory / "wake.json"
        past = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
        for arguments in ((), ("--state", str(state))):
            with self.subTest(arguments=arguments):
                _, first = self.run_json(
                    DELIVERY, "wait", "wake-at", "--deadline", past, "--interval", "0.05", *arguments,
                )
                self.assertEqual(first["state"], "satisfied")
                later = datetime.now(timezone.utc) + timedelta(seconds=0.3)
                _, output = self.run_json(
                    DELIVERY, "wait", "wake-at", "--deadline", later.isoformat(),
                    "--interval", "0.05", *arguments,
                )
                self.assertEqual(output["state"], "satisfied")
                self.assertGreaterEqual(datetime.now(timezone.utc), later)
        self.assertFalse(state.exists())
        self.assertFalse((self.directory / ".agent" / "waits").exists())

    def test_checkpoint_identity_change_invalidates(self) -> None:
        self.write_scenario(pull=pull("head-1", []))
        state = self.directory / "wait.json"
        state.write_text(json.dumps({
            "schemaVersion":1, "kind":"checks-terminal",
            "identity":{"repo":"other/repo","pr":7,"head":"head-1","runId":None,"tag":None,"checks":["CI"],"assets":[]},
            "observation":{"head":"head-1","checks":[]}, "digest":"old", "updatedAt":"earlier",
        }))
        _, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--check", "CI", "--deadline", self.deadline(), "--interval", "0.01", "--state", str(state),
        )
        self.assertEqual(output["state"], "invalidated")

    def test_dead_checkpoint_lock_is_reclaimed(self) -> None:
        self.write_scenario()
        state = self.directory / "wait.json"
        Path(f"{state}.lock").write_text("99999999:stale\n")
        _, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--check", "CI", "--deadline", self.deadline(),
            "--interval", "0.01", "--state", str(state),
        )
        self.assertEqual(output["state"], "satisfied")
        self.assertFalse(Path(f"{state}.lock").exists())

    def test_review_convergence_uses_policy_and_thread_state(self) -> None:
        self.write_scenario()
        _, output = self.run_json(
            REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", "--policy", str(self.policy),
        )
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["observation"]["unresolvedThreads"], 0)

    def test_review_wait_retries_racing_census_then_reports_changed_head(self) -> None:
        self.write_scenario(reviewHeadsByRequest=["head-1", "head-2", "head-2", "head-2"])
        result, output = self.run_json(
            REVIEW, "wait", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
            "--policy", str(self.policy), "--deadline", self.deadline(), "--interval", "0.01",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "invalidated")
        self.assertEqual(output["metrics"]["retries"], 1)
        self.assertEqual(output["metrics"]["observations"], 1)
        self.assertEqual(output["observation"]["head"], "head-2")

    def review_wait(self, state: Path, seconds: float = 3) -> dict:
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()
        return self.run_json(
            REVIEW, "wait", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", "--policy", str(self.policy),
            "--deadline", deadline, "--interval", "0.05", "--state", str(state),
        )[1]

    def test_a_review_wait_armed_right_after_a_push_waits_for_github_to_move_the_head(self) -> None:
        # Seen in practice: GitHub still reported the head before the push.
        for relation, status in (("ancestor", "ahead"), ("diverged", "diverged")):
            with self.subTest(relation=relation):
                self.counter.unlink(missing_ok=True)
                # Each observation reads the census twice; a lagging one also compares the heads.
                self.write_scenario(
                    reviewHeadsByRequest=["head-0"] * 6 + ["head-1"],
                    compare={"head-0...head-1": {"status": status}},
                )
                output = self.review_wait(self.directory / f"{relation}.json")
                self.assertEqual(output["state"], "satisfied", output["reason"])
                self.assertEqual(output["observation"]["head"], "head-1")
                self.assertGreaterEqual(output["metrics"]["observations"], 3)

    def test_a_review_wait_reports_a_lagging_head_without_judging_its_reviews(self) -> None:
        self.write_scenario(reviewHeadsByRequest=["head-0"], compare={"head-0...head-1": {"status": "ahead"}})
        _, inspected = self.run_json(
            REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", "--policy", str(self.policy),
        )
        self.assertEqual(inspected["state"], "waiting")
        self.assertIn("an ancestor of the expected commit", inspected["reason"])
        self.assertEqual(inspected["observation"]["headLag"]["relation"], "ancestor")
        # An inspection keeps the whole census its callers read, such as the threads.
        self.assertEqual(inspected["observation"]["threads"], [])
        output = self.review_wait(self.directory / "review.json", seconds=0.3)
        self.assertEqual(output["state"], "timed-out")
        self.assertEqual(output["observation"]["headLag"]["relation"], "ancestor")
        self.assertNotIn("automations", output["observation"])

    def test_a_review_wait_confirms_another_head_by_its_head_alone(self) -> None:
        # GitHub answers two review censuses, one for each observation (the second at the deadline),
        # and refuses any more: each observation confirms the lagging head by its head alone.
        self.write_scenario(
            reviewHeadsByRequest=["head-0"], compare={"head-0...head-1": {"status": "ahead"}}, reviewQueriesAllowed=2,
        )
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=0.3)).isoformat()
        output = self.run_json(
            REVIEW, "wait", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", "--policy", str(self.policy),
            "--deadline", deadline, "--interval", "5", "--state", str(self.directory / "review.json"),
        )[1]
        self.assertEqual(output["state"], "timed-out", output["reason"])
        self.assertEqual(output["observation"]["headLag"]["relation"], "ancestor")

    def test_a_review_wait_counts_the_expected_head_its_confirmation_saw(self) -> None:
        # The census sees head-0, its confirmation head-1, and then GitHub shows a force-push replacing head-1.
        self.write_scenario(
            reviewHeadsByRequest=["head-0", "head-1", "head-2"],
            compare={"head-0...head-1": {"status": "ahead"}, "head-2...head-1": {"status": "diverged"}},
        )
        output = self.review_wait(self.directory / "review.json")
        self.assertEqual(output["state"], "invalidated", output["reason"])
        self.assertIn("after this wait had seen the expected head", output["reason"])

    def test_a_review_wait_classifies_another_head_when_github_refuses_its_census(self) -> None:
        self.write_scenario(
            reviewHeadsByRequest=["head-0"], compare={"head-0...head-1": {"status": "ahead"}}, reviewQueriesAllowed=0,
        )
        output = self.review_wait(self.directory / "review.json", seconds=0.3)
        self.assertEqual(output["state"], "timed-out", output["reason"])
        self.assertEqual(output["observation"]["headLag"]["relation"], "ancestor")
        # The expected head's census is still required.
        self.write_scenario(reviewQueriesAllowed=0)
        self.counter.with_name("counter.review-queries").unlink(missing_ok=True)
        output = self.review_wait(self.directory / "expected.json", seconds=0.3)
        self.assertEqual(output["state"], "operational-error")

    def test_a_review_wait_classifies_another_head_when_its_census_times_out(self) -> None:
        self.write_scenario(reviewHeadsByRequest=["head-2"], compare={"head-2...head-1": {"status": "behind"}}, reviewCensusTimesOut=True)
        output = self.review_wait(self.directory / "review.json")
        self.assertEqual(output["state"], "invalidated", output["reason"])
        self.assertIn("a later commit than the expected one", output["reason"])

    def test_a_review_inspection_keeps_its_census_when_github_cannot_compare_the_heads(self) -> None:
        self.write_scenario(reviewHeadsByRequest=["head-0"], compareUnavailableOnce=True)
        result, inspected = self.run_json(
            REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", "--policy", str(self.policy),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(inspected["state"], "invalidated")
        self.assertIn("GitHub could not compare them", inspected["reason"])
        self.assertEqual(inspected["observation"]["threads"], [])
        self.assertEqual(inspected["observation"]["headLag"]["relation"], "unverified")

    def test_a_review_wait_with_a_rejected_deadline_leaves_its_checkpoint_alone(self) -> None:
        state = self.directory / "review.json"
        self.write_scenario(reviewHeadsByRequest=["head-0"], compare={"head-0...head-1": {"status": "ahead"}})
        self.review_wait(state, seconds=0.3)
        checkpoint = json.loads(state.read_text())
        checkpoint.pop("expectedHead", None)
        checkpoint["digest"] = "digest-of-head-0"
        state.write_text(json.dumps(checkpoint))
        result, output = self.run_json(
            REVIEW, "wait", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", "--policy", str(self.policy),
            "--deadline", "mistyped", "--state", str(state),
        )
        self.assertEqual((result.returncode, output["state"]), (2, "operational-error"))
        self.assertEqual(json.loads(state.read_text()), checkpoint)

    def test_a_review_wait_invalidates_a_later_push_at_once(self) -> None:
        self.write_scenario(reviewHeadsByRequest=["head-2"], compare={"head-2...head-1": {"status": "behind"}})
        output = self.review_wait(self.directory / "review.json")
        self.assertEqual(output["state"], "invalidated")
        self.assertIn("a later commit than the expected one", output["reason"])
        self.assertEqual(output["metrics"]["observations"], 1)

    def test_a_review_wait_keeps_the_expected_head_seen_and_the_grace_in_its_checkpoint(self) -> None:
        state = self.directory / "review.json"
        self.write_scenario(reviewHeadsByRequest=["head-0"], compare={"head-0...head-1": {"status": "ahead"}})
        first = self.review_wait(state, seconds=0.3)
        self.assertEqual(first["state"], "timed-out")
        since = first["observation"]["headLag"]["since"]
        self.assertEqual(self.review_wait(state, seconds=0.3)["observation"]["headLag"]["since"], since)
        # Once the grace has passed, a head that never moved invalidates the wait.
        checkpoint = json.loads(state.read_text())
        checkpoint["expectedHead"]["since"] = "2026-08-12T08:00:00Z"
        state.write_text(json.dumps(checkpoint))
        expired = self.review_wait(state)
        self.assertEqual(expired["state"], "invalidated")
        self.assertIn("check that the push reached", expired["reason"])
        # A wait that saw the expected head gives a head that moves off it no grace, on a rerun too.
        state.unlink()
        self.counter.unlink(missing_ok=True)
        self.write_scenario(reviewHeadsByRequest=["head-1"] * 2 + ["head-0"], compare={"head-0...head-1": {"status": "ahead"}})
        scenario = json.loads(self.scenario.read_text())
        scenario["review"]["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"] = [
            check("Automated review", "IN_PROGRESS", None)
        ]
        self.scenario.write_text(json.dumps(scenario))
        changed = self.review_wait(state)
        self.assertEqual(changed["state"], "invalidated", changed["reason"])
        self.assertIn("after this wait had seen the expected head", changed["reason"])
        self.assertEqual(json.loads(state.read_text())["expectedHead"]["seen"], True)
        self.assertEqual(self.review_wait(state)["observation"]["headLag"], {"relation": "replaced"})

    def test_a_review_checkpoint_digest_of_another_head_is_no_baseline(self) -> None:
        # An earlier helper saved the later push's digest when it invalidated at once.
        state = self.directory / "review.json"
        self.write_scenario(reviewHeadsByRequest=["head-0"], compare={"head-0...head-1": {"status": "ahead"}})
        self.review_wait(state, seconds=0.3)
        checkpoint = json.loads(state.read_text())
        checkpoint.pop("expectedHead", None)
        checkpoint["digest"] = "digest-of-head-0"
        state.write_text(json.dumps(checkpoint))
        self.counter.unlink(missing_ok=True)
        self.write_scenario()
        self.assertEqual(self.review_wait(state)["state"], "satisfied")

    def test_review_policy_accepts_the_existing_single_context_shape(self) -> None:
        self.write_scenario()
        self.policy.write_text(json.dumps({"automations":[{
            "id":"automated-review", "actors":["review-bot[bot]"],
            "check_context":"Automated review",
            "terminal_review_states":["APPROVED", "COMMENTED"],
        }]}))
        _, output = self.run_json(
            REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--policy", str(self.policy),
        )
        self.assertEqual(output["state"], "satisfied")

    def test_review_wait_requires_judgment_for_unresolved_finding(self) -> None:
        self.write_scenario()
        scenario = json.loads(self.scenario.read_text())
        scenario["review"]["reviewThreads"]["nodes"] = [{
            "id":"thread-1", "isResolved":False,
            "comments":{"nodes":[{"id":"node-1","databaseId":10,"body":"finding","createdAt":"now","author":{"login":"review-bot[bot]"},"authorAssociation":"NONE","replyTo":None}],"pageInfo":{"hasNextPage":False}},
        }]
        self.scenario.write_text(json.dumps(scenario))
        _, output = self.run_json(
            REVIEW, "wait", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", "--policy", str(self.policy),
            "--deadline", (datetime.now(timezone.utc) + timedelta(seconds=.08)).isoformat(), "--interval", "0.02",
        )
        self.assertEqual(output["state"], "judgment-required")
        self.assertEqual(output["observation"]["findingSurfaceCount"], 1)

    def test_terminal_neutral_check_cannot_hide_review_or_comment_bodies(self) -> None:
        self.policy.write_text(json.dumps({"automations":[{
            "id":"automated-review", "actors":["review-bot[bot]"],
            "check_contexts":["Automated review"], "check_app_slugs":["review-app"],
            "terminal_check_conclusions":["success", "neutral"],
            "terminal_review_states":["COMMENTED"],
            "nonterminal_review_markers":[],
        }]}))
        self.write_scenario()
        scenario = json.loads(self.scenario.read_text())
        scenario["review"]["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"] = [
            check("Automated review", "COMPLETED", "NEUTRAL", app="review-app")
        ]
        scenario["review"]["reviews"]["nodes"] = [{
            "id":"review-node-1", "databaseId":31,
            "author":{"login":"review-bot[bot]"}, "authorAssociation":"NONE",
            "state":"COMMENTED", "body":"Critical: unsafe state transition.",
            "submittedAt":"2026-08-12T08:02:00Z", "commit":{"oid":"head-1"},
        }]
        scenario["review"]["comments"]["nodes"] = [{
            "id":"comment-node-1", "databaseId":32,
            "author":{"login":"review-bot[bot]"}, "authorAssociation":"NONE",
            "body":"Review summary with one critical issue.",
            "createdAt":"2026-08-12T08:02:01Z",
        }]
        self.scenario.write_text(json.dumps(scenario))

        _, output = self.run_json(
            REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--policy", str(self.policy),
        )

        self.assertEqual(output["state"], "judgment-required")
        surfaces = output["observation"]["findingSurfaces"]
        self.assertEqual(output["observation"]["findingSurfaceCount"], 2)
        self.assertEqual(
            {surface["kind"] for surface in surfaces},
            {"review", "top-level-comment"},
        )
        review_surface = next(surface for surface in surfaces if surface["kind"] == "review")
        self.assertIn("Critical", review_surface["review"]["body"])

    def test_unknown_review_policy_inspects_feedback_without_claiming_readiness(self) -> None:
        for content in (None, "[]", "{", '{"automations":false}'):
            with self.subTest(content=content):
                self.write_scenario()
                scenario = json.loads(self.scenario.read_text())
                scenario["review"]["comments"]["nodes"] = [{
                    "id":"human-comment", "body":"Please handle rollback.",
                    "author":{"login":"maintainer"},
                }]
                scenario["review"]["reviews"]["nodes"] = [{
                    "id":"unknown-review", "body":"Falsy values disappear.",
                    "author":{"login":"unconfigured-bot[bot]"},
                    "state":"COMMENTED", "commit":{"oid":"head-1"},
                }]
                scenario["review"]["reviewThreads"]["nodes"] = [{
                    "id":"thread", "isResolved":False,
                    "comments":{"nodes":[],"pageInfo":{"hasNextPage":False}},
                }]
                self.scenario.write_text(json.dumps(scenario))
                if content is None:
                    self.policy.unlink(missing_ok=True)
                else:
                    self.policy.write_text(content)
                result, output = self.run_json(
                    REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7",
                    "--head", "head-1", "--policy", str(self.policy),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output["state"], "waiting")
                self.assertEqual(output["metrics"]["apiRequests"], 2)
                observation = output["observation"]
                self.assertFalse(observation["policyAvailable"])
                self.assertTrue(observation["policyError"])
                self.assertEqual(observation["checks"][0]["name"], "Automated review")
                self.assertIsNone(observation["unansweredAutomationThreads"])
                self.assertEqual(observation["unresolvedThreads"], 1)
                self.assertIsNone(observation["threads"][0]["automation"])
                self.assertIsNone(observation["threads"][0]["maintainerReply"])
                self.assertEqual(observation["findingSurfaceCount"], 3)
                self.assertEqual(observation["unclassifiedTopLevelComments"][0]["body"], "Please handle rollback.")

    def test_missing_policy_never_turns_empty_feedback_into_success(self) -> None:
        self.write_scenario(compare={"head-1...old-head": {"status": "behind"}})
        self.policy.unlink()
        _, output = self.run_json(
            REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--policy", str(self.policy),
        )
        self.assertEqual(output["state"], "waiting")
        self.assertEqual(output["observation"]["findingSurfaceCount"], 0)
        _, output = self.run_json(
            REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7",
            "--head", "old-head", "--policy", str(self.policy),
        )
        self.assertEqual(output["state"], "invalidated")

    def test_wait_requires_valid_policy_before_creating_checkpoint(self) -> None:
        self.write_scenario()
        self.policy.unlink()
        state = self.directory / "review.json"
        result, output = self.run_json(
            REVIEW, "wait", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--policy", str(self.policy),
            "--deadline", self.deadline(), "--state", str(state),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output["state"], "operational-error")
        self.assertEqual(output["metrics"]["apiRequests"], 0)
        self.assertFalse(state.exists())

    def test_current_review_feedback_does_not_depend_on_automation_membership(self) -> None:
        for author, body, state, head, expected in (
            ("maintainer", "Rollback fails.", "COMMENTED", "head-1", "judgment-required"),
            ("other-bot[bot]", "Rollback fails.", "COMMENTED", "head-1", "judgment-required"),
            ("maintainer", "", "CHANGES_REQUESTED", "head-1", "judgment-required"),
            ("maintainer", "Previous review.", "COMMENTED", "old-head", "satisfied"),
        ):
            with self.subTest(author=author, body=body, head=head):
                self.write_scenario()
                scenario = json.loads(self.scenario.read_text())
                scenario["review"]["reviews"]["nodes"] = [{
                    "id":"review-1", "author":{"login":author}, "body":body,
                    "state":state, "commit":{"oid":head},
                }]
                self.scenario.write_text(json.dumps(scenario))
                _, output = self.run_json(
                    REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7",
                    "--head", "head-1", "--policy", str(self.policy),
                )
                self.assertEqual(output["state"], expected)
                if expected == "judgment-required":
                    self.assertEqual(output["observation"]["findingSurfaces"][0]["review"]["body"], body)

    def test_human_top_level_feedback_is_retained_with_valid_automation_policy(self) -> None:
        self.write_scenario()
        scenario = json.loads(self.scenario.read_text())
        scenario["review"]["comments"]["nodes"] = [{
            "id":"human-comment", "body":"The migration drops existing data.",
            "author":{"login":"maintainer"},
        }]
        self.scenario.write_text(json.dumps(scenario))
        _, output = self.run_json(
            REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--policy", str(self.policy),
        )
        self.assertEqual(output["state"], "judgment-required")
        self.assertEqual(output["observation"]["findingSurfaces"][0]["id"], "human-comment")
        self.assertEqual(output["observation"]["topLevelAutomationComments"], [])
        self.assertEqual(len(output["observation"]["unclassifiedTopLevelComments"]), 1)

    def test_edited_human_review_wakes_wait_without_storing_body(self) -> None:
        self.write_scenario()
        scenario = json.loads(self.scenario.read_text())
        scenario["review"]["reviews"]["nodes"] = [{
            "id":"human-review", "body":"First finding.", "state":"COMMENTED",
            "author":{"login":"maintainer"}, "commit":{"oid":"head-1"},
        }]
        self.scenario.write_text(json.dumps(scenario))
        state = self.directory / "review.json"
        arguments = (
            "wait", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
            "--policy", str(self.policy), "--deadline", self.deadline(),
            "--interval", "0.01", "--state", str(state),
        )
        _, first = self.run_json(REVIEW, *arguments)
        self.assertEqual(first["state"], "judgment-required")
        scenario["review"]["reviews"]["nodes"][0]["body"] = "New finding with private details."
        self.scenario.write_text(json.dumps(scenario))
        _, second = self.run_json(REVIEW, *arguments)
        self.assertEqual(second["state"], "changed")
        self.assertNotIn("private details", state.read_text())
        self.assertNotIn("private details", json.dumps(second))
        self.assertIn("bodyDigest", state.read_text())

    def test_pr_without_check_rollup_is_pending_not_an_exception(self) -> None:
        self.write_scenario()
        scenario = json.loads(self.scenario.read_text())
        scenario["review"]["commits"]["nodes"][0]["commit"]["statusCheckRollup"] = None
        self.scenario.write_text(json.dumps(scenario))
        result, output = self.run_json(
            REVIEW, "inspect", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--policy", str(self.policy),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "waiting")
        self.assertFalse(output["observation"]["automations"][0]["terminal"])

    def test_review_wait_reports_new_finding_before_convergence(self) -> None:
        self.write_scenario()
        state = self.directory / "review.json"
        identity = {
            "repo":"owner/repo", "pr":7, "head":"head-1",
            "policyDigest": hashlib.sha256(
                json.dumps(json.loads(self.policy.read_text()), sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest(),
        }
        state.write_text(json.dumps({
            "schemaVersion":1, "kind":"review", "identity":identity,
            "observation":{"head":"head-1"}, "digest":"prior", "updatedAt":"earlier",
        }))
        _, output = self.run_json(
            REVIEW, "wait", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--policy", str(self.policy),
            "--deadline", self.deadline(), "--interval", "0.01", "--state", str(state),
        )
        self.assertEqual(output["state"], "changed")

    def test_wait_checkpoint_does_not_store_comment_bodies(self) -> None:
        self.write_scenario()
        scenario = json.loads(self.scenario.read_text())
        scenario["review"]["reviewThreads"]["nodes"] = [{
            "id":"thread-1", "isResolved":False,
            "comments":{"nodes":[{"id":"node-1","databaseId":10,"body":"sensitive finding detail","createdAt":"now","author":{"login":"review-bot[bot]"},"authorAssociation":"NONE","replyTo":None}],"pageInfo":{"hasNextPage":False}},
        }]
        self.scenario.write_text(json.dumps(scenario))
        state = self.directory / "review.json"
        self.run_json(
            REVIEW, "wait", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
            "--policy", str(self.policy), "--deadline",
            (datetime.now(timezone.utc) + timedelta(seconds=.05)).isoformat(),
            "--interval", "0.01", "--state", str(state),
        )
        checkpoint = state.read_text()
        self.assertNotIn("sensitive finding detail", checkpoint)
        self.assertIn("bodyDigest", checkpoint)

    def test_unbound_legacy_reply_marker_is_not_a_valid_receipt(self) -> None:
        marker = "<!-- known-good-route-operation:op-1 -->"
        self.write_scenario(comments=[{"id":777,"body":f"already done {marker}"}])
        _, output = self.run_json(
            REVIEW, "reply", "--repo", "owner/repo", "--pr", "7", "--comment-id", "10",
            "--head", "head-1", "--body", "Fixed with regression coverage.", "--operation-id", "op-1",
        )
        self.assertEqual(output["state"], "operational-error")
        self.assertIn("does not match", output["reason"])

    def test_resolve_operation_is_explicit(self) -> None:
        self.write_scenario()
        _, output = self.run_json(
            REVIEW, "resolve", "--repo", "owner/repo", "--pr", "7", "--head", "head-1", "--thread-id", "thread-1",
        )
        self.assertEqual(output["state"], "satisfied")
        self.assertTrue(output["observation"]["resolved"])

    def short_deadline(self) -> str:
        return (datetime.now(timezone.utc) + timedelta(seconds=0.3)).isoformat()

    def reset_census(self) -> None:
        """Start a subtest with a fresh fake census and no saved checkpoint."""
        self.counter.with_name("counter.census").unlink(missing_ok=True)
        shutil.rmtree(self.directory / ".agent", ignore_errors=True)

    def census_wait(self, *extra: str, deadline: str | None = None) -> tuple[subprocess.CompletedProcess[str], dict]:
        return self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--all-workflows", *extra,
            "--deadline", deadline or self.deadline(), "--interval", "0.01",
        )

    def rest_requests(self) -> list[dict]:
        log = self.counter.with_name("counter.log")
        return [entry for entry in map(json.loads, log.read_text().splitlines()) if entry["args"][1] != "graphql"]

    def test_an_unchanged_census_is_revalidated_without_spending_the_rest_budget(self) -> None:
        # Two pages of runs, so the next page GitHub links to is revalidated too.
        runs = census(workflow_run(101, matrix_jobs(2)), workflow_run(102, matrix_jobs(1, start=5, run_id=102), workflow_id=8))
        first, second = runs["runPages"][0]["workflow_runs"]
        runs["runPages"] = [{"total_count": 2, "workflow_runs": [first]}, {"total_count": 2, "workflow_runs": [second]}]
        self.write_scenario(census=[runs])
        result, output = self.census_wait()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["metrics"]["observations"], 2)
        requests = self.rest_requests()
        # Two pages of runs and the jobs of two runs, once each observation.
        self.assertEqual(len(requests), 8)
        self.assertEqual([entry["etag"] is not None for entry in requests], [False] * 4 + [True] * 4)
        self.assertEqual(output["metrics"]["notModified"], 4)

    def test_a_changed_resource_is_read_again_in_full(self) -> None:
        self.write_scenario(census=[
            census(workflow_run(101, matrix_jobs(1, status="in_progress", conclusion=None), status="in_progress", conclusion=None)),
            census(workflow_run(101, matrix_jobs(1))),
        ])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "satisfied")
        # The changed census answered in full; only the third observation was unchanged.
        self.assertEqual(output["metrics"]["observations"], 3)
        self.assertEqual(output["metrics"]["notModified"], 2)

    MERGE = "ecaaad4ed6e5f3f849cd7a828e4755b5b8fe5256"

    def commit_wait(self, *extra: str, head: str | None = None, command: str = "wait") -> tuple[subprocess.CompletedProcess[str], dict]:
        timing = ("--deadline", self.deadline(), "--interval", "0.01") if command == "wait" else ()
        return self.run_json(
            DELIVERY, command, "checks-terminal", "--repo", "owner/repo", "--head", head or self.MERGE, *extra, *timing,
        )

    def merge_commit(self, checks: list[dict] | None = None) -> dict:
        return {"__typename": "Commit", "oid": self.MERGE,
                "statusCheckRollup": {"contexts": {"nodes": checks or [], "pageInfo": {"hasNextPage": False}}}}

    def merge_run(self, run_id: int, event: str, conclusion: str = "success", name: str = "CI", **values: Any) -> dict:
        return workflow_run(run_id, [workflow_job(run_id * 10, "job", conclusion=conclusion, run_id=run_id)],
                            conclusion=conclusion, head=self.MERGE, name=name, event=event, branch="main",
                            workflow_id=run_id, **values)

    def test_a_merge_commit_census_needs_no_pull_request(self) -> None:
        self.write_scenario(commit=self.merge_commit(), census=[census(self.merge_run(101, "push"))])
        result, output = self.commit_wait("--all-workflows")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "satisfied")
        self.assertIsNone(output["identity"]["pr"])
        self.assertEqual([run["id"] for run in output["observation"]["runs"]], [101])

    def test_runs_github_records_on_the_default_branch_tip_do_not_decide_a_commit(self) -> None:
        # Seen on a merge commit: the previous deployment's gate, dispatched after the merge,
        # failed holding a superseded deployment, and another PR's build chained a workflow_run.
        own = [self.merge_run(101, "push"), self.merge_run(102, "deployment_status", name="Smoke")]
        held = self.merge_run(103, "repository_dispatch", "failure", "Deployment Gate")
        chained = self.merge_run(104, "workflow_run", "failure", "Image build for pull request 12")
        later = self.merge_run(105, "repository_dispatch", "skipped", "Deployment Gate")
        # Unbound runs arriving between two observations do not stop them confirming the census.
        self.write_scenario(commit=self.merge_commit(), census=[census(*own, held), census(*own, held, chained, later)])
        result, output = self.commit_wait("--all-workflows")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertEqual(output["metrics"]["observations"], 2)
        self.assertEqual([run["id"] for run in output["observation"]["runs"]], [101, 102])
        self.assertEqual([(run["id"], run["event"]) for run in output["observation"]["unboundRuns"]],
                         [(103, "repository_dispatch"), (104, "workflow_run"), (105, "repository_dispatch")])
        self.assertIn("3 runs of events GitHub records on the default branch's latest commit were not counted", output["reason"])
        # An unbound run's jobs are never read.
        jobs = [entry["args"] for entry in self.rest_requests() if "/jobs" in entry["args"][-1]]
        self.assertTrue(jobs)
        self.assertFalse([args for args in jobs if any(f"/runs/{run_id}/" in arg for arg in args for run_id in (103, 104, 105))])

    def test_a_failed_run_the_commit_started_still_fails_its_census(self) -> None:
        self.write_scenario(commit=self.merge_commit(), census=[census(
            self.merge_run(101, "push", "failure"), self.merge_run(102, "pull_request_target"),
        )])
        _, output = self.commit_wait("--all-workflows")
        self.assertEqual(output["state"], "changed")
        self.assertIn("CI: failure", output["reason"])
        self.reset_census()
        # pull_request_target runs are recorded on the pull request's head and count.
        self.write_scenario(commit=self.merge_commit(), census=[census(
            self.merge_run(101, "push"), self.merge_run(102, "pull_request_target", "failure", "Label"),
        )])
        _, output = self.commit_wait("--all-workflows")
        self.assertEqual(output["state"], "changed")
        self.assertEqual(output["observation"]["unboundRuns"], [])

    def test_a_pull_request_census_does_not_count_unbound_runs_either(self) -> None:
        self.write_scenario(census=[census(
            workflow_run(101, matrix_jobs(1)),
            workflow_run(102, [workflow_job(1020, "gate", conclusion="failure", run_id=102)], conclusion="failure",
                         event="repository_dispatch", workflow_id=9),
        )])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertEqual([run["id"] for run in output["observation"]["unboundRuns"]], [102])

    def test_named_checks_on_a_commit_read_its_own_rollup(self) -> None:
        status = {"__typename": "StatusContext", "context": "deploy/production", "state": "SUCCESS",
                  "targetUrl": "https://example.invalid", "createdAt": "2026-08-12T08:00:00Z"}
        self.write_scenario(commit=self.merge_commit([status, check("CI", "COMPLETED", "SUCCESS", event="push")]))
        result, output = self.commit_wait("--check", "deploy/production", "--check", "CI")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "satisfied", output["reason"])
        status["state"] = "PENDING"
        self.write_scenario(commit=self.merge_commit([status]))
        _, output = self.commit_wait("--check", "deploy/production", command="inspect")
        self.assertEqual(output["state"], "waiting")

    def test_a_commit_falls_back_to_rest_when_graphql_is_rate_limited(self) -> None:
        self.write_scenario(
            graphqlRateLimited=True, restCommit={"sha": self.MERGE},
            restStatuses=[{"context": "deploy", "state": "success", "created_at": "2026-08-12T08:00:00Z"}],
        )
        _, output = self.commit_wait("--check", "deploy", command="inspect")
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertEqual(output["metrics"]["rateLimitFallbacks"], 1)
        self.write_scenario(graphqlRateLimited=True)
        result, output = self.commit_wait("--check", "deploy", command="inspect")
        self.assertEqual(result.returncode, 2)
        self.assertIn(f"commit {self.MERGE} was not found in owner/repo", output["reason"])

    def test_a_commit_wait_names_what_it_needs(self) -> None:
        self.write_scenario()
        result, output = self.commit_wait("--all-workflows", head="ecaaad4")
        self.assertEqual(result.returncode, 2)
        self.assertIn("needs its full SHA", output["reason"])
        result, output = self.commit_wait("--all-workflows")
        self.assertEqual(result.returncode, 2)
        self.assertIn(f"commit {self.MERGE} was not found in owner/repo", output["reason"])
        result, output = self.run_json(DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo", "--all-workflows")
        self.assertEqual(result.returncode, 2)
        self.assertIn("without --pr a commit such as a merge commit", output["reason"])
        result, output = self.run_json(DELIVERY, "inspect", "pr-merged", "--repo", "owner/repo", "--head", "head-1")
        self.assertEqual(output["reason"], "pr-merged requires --pr and --head")
        result, output = self.run_json(DELIVERY, "inspect", "workflow-terminal", "--repo", "owner/repo", "--head", "head-1")
        self.assertEqual(output["reason"], "workflow-terminal requires --run-id")

    def deploy_status(self, context: str = "deploy", state: str = "SUCCESS") -> dict:
        return {"__typename": "StatusContext", "id": f"status-{context}", "context": context, "state": state,
                "targetUrl": "https://example.invalid", "createdAt": "2026-08-12T08:00:00Z"}

    def test_checks_from_unbound_runs_neither_decide_nor_unsettle_a_commit_census(self) -> None:
        # Each observation sees one more failed check, named like the requested status,
        # from a repository dispatch; the commit's own status decides.
        dispatched = [check("deploy", "COMPLETED", "FAILURE", app="github-actions", event="repository_dispatch",
                            suite_id=600 + n, workflow=7, started_at=f"2026-08-12T08:0{n}:00Z") for n in range(3)]
        self.write_scenario(commitsByRequest=[self.merge_commit([self.deploy_status(), *dispatched[:n]]) for n in (1, 2, 3)],
                            census=[census(self.merge_run(101, "push"))])
        _, output = self.commit_wait("--all-workflows", "--check", "deploy")
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertEqual(output["metrics"]["observations"], 2)
        self.assertEqual([(c["name"], c["source"]) for c in output["observation"]["checks"]], [("deploy", "status")])
        # Through REST too: the dispatch run's check run is left out by its run's event.
        self.reset_census()
        self.counter.unlink()  # GraphQL refuses the first call only.
        dispatch = workflow_run(103, [], head=self.MERGE, event="repository_dispatch", branch="main", workflow_id=7,
                                check_suite_id=603, conclusion="failure")
        self.write_scenario(
            graphqlRateLimited=True, restCommit={"sha": self.MERGE}, census=[census(dispatch)],
            restChecks={"check_runs": [{"name": "deploy", "status": "completed", "conclusion": "failure",
                                        "app": {"slug": "github-actions"}, "check_suite": {"id": 603}}]},
            restStatuses=[{"context": "deploy", "state": "success", "created_at": "2026-08-12T08:00:00Z"}],
        )
        _, output = self.commit_wait("--check", "deploy", command="inspect")
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertEqual(len(output["observation"]["checks"]), 1)

    def test_unnamed_checks_arriving_do_not_stop_the_census_confirming(self) -> None:
        previews = [self.deploy_status(f"preview-{n}", "PENDING") for n in range(3)]
        self.write_scenario(commitsByRequest=[self.merge_commit([self.deploy_status(), *previews[:n]]) for n in (1, 2, 3)],
                            census=[census(self.merge_run(101, "push"))])
        _, output = self.commit_wait("--all-workflows", "--check", "deploy")
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertEqual(output["metrics"]["observations"], 2)

    def test_a_rerun_waits_for_active_unbound_runs_on_the_commit(self) -> None:
        older = self.merge_run(101, "push")
        cancelled = workflow_run(102, [workflow_job(1021, "job", conclusion="cancelled", run_id=102)], conclusion="cancelled",
                                 head=self.MERGE, event="push", branch="main", workflow_id=101, updated_at="2026-08-12T08:00:02Z")
        dispatch = workflow_run(103, [], status="in_progress", conclusion=None, head=self.MERGE, event="repository_dispatch",
                                branch="main", workflow_id=103, name="Gate")
        self.write_scenario(commit=self.merge_commit(), census=[census(older, cancelled, dispatch)])
        _, output = self.commit_wait("--all-workflows", command="inspect")
        self.assertEqual(output["state"], "waiting")
        self.assertIn("can be rerun once the other 1 workflow runs", output["reason"])
        self.reset_census()
        dispatch["run"].update(status="completed", conclusion="failure")
        self.write_scenario(commit=self.merge_commit(), census=[census(older, cancelled, dispatch)])
        _, output = self.commit_wait("--all-workflows")
        self.assertEqual(output["state"], "recoverable", output["reason"])

    def test_commit_runs_of_different_pull_requests_are_not_duplicates(self) -> None:
        older = workflow_run(101, [workflow_job(1011, "job", run_id=101)], head=self.MERGE, event="push", branch="main",
                             workflow_id=9, pull_requests=[7])
        cancelled = workflow_run(102, [workflow_job(1021, "job", conclusion="cancelled", run_id=102)], conclusion="cancelled",
                                 head=self.MERGE, event="push", branch="main", workflow_id=9, pull_requests=[8],
                                 updated_at="2026-08-12T08:00:02Z")
        self.write_scenario(commit=self.merge_commit(), census=[census(older, cancelled)])
        _, output = self.commit_wait("--all-workflows")
        self.assertEqual(output["state"], "changed", output["reason"])
        self.reset_census()
        cancelled["run"]["pull_requests"] = [{"number": 8}, {"number": 7}]
        self.write_scenario(commit=self.merge_commit(), census=[census(older, cancelled)])
        _, output = self.commit_wait("--all-workflows")
        self.assertEqual(output["state"], "recoverable", output["reason"])

    def test_a_named_check_past_the_first_hundred_contexts_is_read(self) -> None:
        filler = [self.deploy_status(f"other-{n}") for n in range(100)]
        deploy = self.deploy_status()
        self.write_scenario(commitPages={
            "": {"contexts": {"nodes": filler, "totalCount": 101, "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}},
            "c1": {"contexts": {"nodes": [deploy], "totalCount": 101, "pageInfo": {"hasNextPage": False, "endCursor": None}}},
        })
        result, output = self.commit_wait("--check", "deploy", command="inspect")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "satisfied", output["reason"])
        # A pull request's rollup is read the same way.
        crowded = pull("head-1", filler)
        crowded["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["pageInfo"] = {"hasNextPage": True, "endCursor": "c1"}
        self.write_scenario(pull=crowded, commitPages={
            "": {"contexts": {"nodes": filler, "totalCount": 101, "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}},
            "c1": {"contexts": {"nodes": [deploy], "totalCount": 101, "pageInfo": {"hasNextPage": False}}},
        })
        _, output = self.run_json(DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
                                  "--head", "head-1", "--check", "deploy")
        self.assertEqual(output["state"], "satisfied", output["reason"])

    def test_an_incomplete_rollup_page_is_never_the_end_of_the_list(self) -> None:
        filler = [self.deploy_status(f"other-{n}") for n in range(100)]
        failed = check("deploy", "COMPLETED", "FAILURE", app="other-app")
        first = {"contexts": {"nodes": filler, "totalCount": 101, "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}}
        for second in (None, {"contexts": {"nodes": [], "totalCount": 100, "pageInfo": {"hasNextPage": False}}}):
            with self.subTest(second=second):
                self.write_scenario(commitPages={"": first, "c1": second})
                result, output = self.commit_wait("--check", "deploy", command="inspect")
                self.assertEqual(result.returncode, 2)
                self.assertIn("check rollup", output["reason"])
        self.write_scenario(commitPages={"": first, "c1": {"contexts": {"nodes": [failed], "totalCount": 101, "pageInfo": {"hasNextPage": False}}}})
        _, output = self.commit_wait("--check", "deploy", command="inspect")
        self.assertEqual(output["state"], "changed", output["reason"])

    def test_a_census_checkpoint_saved_before_unbound_runs_were_set_aside_resumes_without_a_change(self) -> None:
        sys.path.insert(0, str(DELIVERY.parent))
        try:
            from kgr_github import stable_digest
        finally:
            sys.path.pop(0)
        def run(run_id: int, event: str, conclusion: str, name: str) -> dict:
            return {"id": run_id, "name": name, "workflowId": run_id, "event": event, "checkSuiteId": 500 + run_id,
                    "headBranch": "feature", "headRepositoryId": 1, "pullRequests": [], "runStartedAt": "2026-08-12T08:00:00Z",
                    "updatedAt": "2026-08-12T08:05:00Z", "attempt": 1, "status": "completed", "conclusion": conclusion,
                    "url": f"https://example.invalid/runs/{run_id}",
                    "jobs": [{"id": run_id * 10, "name": "job", "status": "completed", "conclusion": conclusion,
                              "completedAt": "2026-08-12T08:05:00Z"}]}
        state = self.directory / "census.json"
        identity = {"repo": "owner/repo", "pr": 7, "head": "head-1", "runId": None, "tag": None, "checks": [], "assets": [],
                    "allWorkflows": True}
        # What the helper before this change saved: the dispatch run's failure in the census key.
        state.write_text(json.dumps({
            "schemaVersion": 1, "kind": "checks-terminal", "identity": identity,
            "observation": {"head": "head-1", "runs": [run(101, "pull_request", "success", "PR"),
                                                       run(102, "repository_dispatch", "failure", "Gate")]},
            "digest": stable_digest({"head": "head-1", "failures": ["Gate / job: failure", "Gate: failure"]}),
            "updatedAt": "2026-08-12T08:06:00Z",
        }))
        self.write_scenario(census=[census(
            workflow_run(101, [workflow_job(1010, "job", run_id=101)], workflow_id=101, check_suite_id=601),
            workflow_run(102, [workflow_job(1020, "job", conclusion="failure", run_id=102)], conclusion="failure",
                         event="repository_dispatch", workflow_id=102, check_suite_id=602, name="Gate"),
        )])
        _, output = self.census_wait("--state", str(state))
        self.assertEqual(output["state"], "satisfied", output["reason"])

    def test_an_empty_head_is_refused_rather_than_skipped(self) -> None:
        self.write_scenario()
        result, output = self.run_json(DELIVERY, "inspect", "workflow-terminal", "--repo", "owner/repo", "--run-id", "44", "--head", "")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--head is empty", output["reason"])

    def test_a_check_graphql_cannot_tie_to_its_unbound_run_is_left_out_by_its_suite(self) -> None:
        orphan = check("deploy", "COMPLETED", "FAILURE", app="github-actions", suite_id=603)
        dispatch = workflow_run(103, [], head=self.MERGE, event="repository_dispatch", branch="main", workflow_id=7,
                                check_suite_id=603, conclusion="failure")
        self.write_scenario(commit=self.merge_commit([self.deploy_status(), orphan]),
                            census=[census(self.merge_run(101, "push"), dispatch)])
        _, output = self.commit_wait("--all-workflows", "--check", "deploy")
        self.assertEqual(output["state"], "satisfied", output["reason"])

    def test_an_uppercase_full_sha_names_the_same_commit(self) -> None:
        self.write_scenario(commit=self.merge_commit(), census=[census(self.merge_run(101, "push"))])
        _, output = self.commit_wait("--all-workflows", head=self.MERGE.upper())
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertEqual(output["identity"]["head"], self.MERGE)

    def test_a_rollup_that_lists_fewer_or_repeated_contexts_is_retried(self) -> None:
        failed = {**check("deploy", "COMPLETED", "FAILURE", app="other-app"), "databaseId": 1}
        status = self.deploy_status()
        cases = {
            "short single page": {"": {"contexts": {"nodes": [status], "totalCount": 2, "pageInfo": {"hasNextPage": False}}}},
            "overlapping pages": {
                "": {"contexts": {"nodes": [failed, *[self.deploy_status(f"other-{n}") for n in range(99)]], "totalCount": 101,
                                  "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}},
                "c1": {"contexts": {"nodes": [failed, status], "totalCount": 101, "pageInfo": {"hasNextPage": False}}},
            },
        }
        for label, pages in cases.items():
            with self.subTest(label):
                self.write_scenario(commitPages=pages)
                result, output = self.commit_wait("--check", "deploy", command="inspect")
                self.assertEqual(result.returncode, 2, output["reason"])
                self.assertIn("check rollup", output["reason"])
        # Through REST, a check-run list shorter than its count is retried too.
        self.counter.unlink(missing_ok=True)
        self.write_scenario(graphqlRateLimited=True, restCommit={"sha": self.MERGE},
                            restChecks={"total_count": 2, "check_runs": [{"name": "deploy", "status": "completed", "conclusion": "success",
                                                                         "app": {"slug": "other-app"}, "check_suite": {"id": 1}}]})
        result, output = self.commit_wait("--check", "deploy", command="inspect")
        self.assertEqual(result.returncode, 2, output["reason"])
        self.assertIn("check run", output["reason"])

    def test_a_named_check_of_an_untied_actions_suite_is_attributed_from_the_run_listing(self) -> None:
        orphan = check("deploy", "COMPLETED", "SUCCESS", app="github-actions", suite_id=603)
        dispatch = workflow_run(103, [], head=self.MERGE, event="repository_dispatch", branch="main", workflow_id=7,
                                check_suite_id=603, conclusion="success")
        self.write_scenario(commit=self.merge_commit([orphan]), census=[census(dispatch)])
        _, output = self.commit_wait("--check", "deploy", command="inspect")
        # The dispatch run's success is not the commit's deployment signal.
        self.assertEqual(output["state"], "waiting", output["reason"])
        self.assertIn("have not appeared", output["reason"])
        self.reset_census()
        push = workflow_run(101, [], head=self.MERGE, event="push", branch="main", workflow_id=8, check_suite_id=603)
        self.write_scenario(commit=self.merge_commit([orphan]), census=[census(push)])
        _, output = self.commit_wait("--check", "deploy", command="inspect")
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertEqual(output["observation"]["checks"][0]["event"], "push")

    def test_an_app_named_like_an_event_keeps_its_check(self) -> None:
        watched = check("deploy", "COMPLETED", "FAILURE", app="watch")
        self.write_scenario(commit=self.merge_commit([self.deploy_status(), watched]), census=[census(self.merge_run(101, "push"))])
        _, output = self.commit_wait("--all-workflows", "--check", "deploy")
        self.assertEqual(output["state"], "changed", output["reason"])

    def test_a_named_check_checkpoint_saved_before_unbound_checks_were_left_out_resumes_without_a_change(self) -> None:
        sys.path.insert(0, str(DELIVERY.parent))
        try:
            from kgr_github import stable_digest
        finally:
            sys.path.pop(0)
        state = self.directory / "named.json"
        identity = {"repo": "owner/repo", "pr": 7, "head": "head-1", "runId": None, "tag": None, "checks": ["deploy"], "assets": []}
        pending = {"name": "deploy", "status": "COMPLETED", "conclusion": "PENDING", "observedAt": "2026-08-12T08:00:00Z", "source": "status"}
        dispatched = {"name": "deploy", "status": "COMPLETED", "conclusion": "FAILURE", "completedAt": "2026-08-12T08:00:00Z",
                      "observedAt": "2026-08-12T08:00:00Z", "suite": 603, "source": "github-actions/7/repository_dispatch"}
        # What the helper before this change saved: the dispatch run's failed check in the key.
        state.write_text(json.dumps({
            "schemaVersion": 1, "kind": "checks-terminal", "identity": identity,
            "observation": {"head": "head-1", "state": "OPEN", "merged": False, "mergedAt": None, "mergeCommit": None,
                            "checks": [dispatched, pending]},
            "digest": stable_digest({"head": "head-1", "nonSuccess": ["deploy"], "terminal": False}),
            "expectedHead": {"seen": True, "since": None, "relation": "missing"},
            "updatedAt": "2026-08-12T08:06:00Z",
        }))
        status = {**self.deploy_status(state="PENDING")}
        self.write_scenario(pull=pull("head-1", [status, check("deploy", "COMPLETED", "FAILURE", app="github-actions",
                                                               event="repository_dispatch", suite_id=603, workflow=7)]))
        _, output = self.run_json(DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
                                  "--check", "deploy", "--state", str(state), "--deadline", self.short_deadline(), "--interval", "0.05")
        self.assertEqual(output["state"], "timed-out", output["reason"])

    def test_a_census_with_named_checks_lists_the_runs_once_per_observation(self) -> None:
        self.write_scenario(graphqlRateLimited=True, restCommit={"sha": self.MERGE},
                            restChecks={"check_runs": [{"name": "CI", "status": "completed", "conclusion": "success",
                                                        "app": {"slug": "github-actions"}, "check_suite": {"id": 601}}]},
                            census=[census(workflow_run(101, [workflow_job(1010, "job", run_id=101)], head=self.MERGE,
                                                        event="push", branch="main", workflow_id=9, check_suite_id=601))])
        _, output = self.commit_wait("--all-workflows", "--check", "CI", command="inspect")
        self.assertEqual(output["metrics"]["observations"], 1)
        listings = [entry for entry in self.rest_requests() if "/actions/runs?" in entry["args"][-1]]
        self.assertEqual(len(listings), 1, listings)

    def test_an_unnamed_untied_actions_check_holds_neither_a_merge_nor_a_named_wait(self) -> None:
        # GraphQL did not tie this Actions check to a workflow run, and the run listing has no run for its suite.
        untied = check("lint", "COMPLETED", "FAILURE", app="github-actions", suite_id=603)
        merged = pull("head-1", [untied, self.deploy_status()], merged=True)
        self.write_scenario(pull=merged)
        _, output = self.run_json(DELIVERY, "inspect", "pr-merged", "--repo", "owner/repo", "--pr", "7", "--head", "head-1")
        self.assertEqual(output["state"], "satisfied", output["reason"])
        _, output = self.run_json(DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
                                  "--check", "deploy")
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertFalse([entry for entry in self.rest_requests() if "/actions/runs?" in entry["args"][-1]])
        # A named one is looked up, and waits while its suite has no listed run.
        _, output = self.run_json(DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
                                  "--check", "lint")
        self.assertIn("no workflow run is listed yet for check suite 603", output["reason"])

    def test_a_saved_untied_check_is_resolved_by_its_suite_before_the_wait_resumes(self) -> None:
        sys.path.insert(0, str(DELIVERY.parent))
        try:
            from kgr_github import stable_digest
        finally:
            sys.path.pop(0)
        state = self.directory / "untied.json"
        identity = {"repo": "owner/repo", "pr": 7, "head": "head-1", "runId": None, "tag": None, "checks": ["deploy"], "assets": []}
        pending = {"name": "deploy", "status": "COMPLETED", "conclusion": "PENDING", "observedAt": "2026-08-12T08:00:00Z", "source": "status"}
        untied = {"name": "deploy", "status": "COMPLETED", "conclusion": "FAILURE", "completedAt": "2026-08-12T08:00:00Z",
                  "observedAt": "2026-08-12T08:00:00Z", "suite": 603, "source": "github-actions"}
        state.write_text(json.dumps({
            "schemaVersion": 1, "kind": "checks-terminal", "identity": identity,
            "observation": {"head": "head-1", "state": "OPEN", "merged": False, "mergedAt": None, "mergeCommit": None,
                            "checks": [untied, pending]},
            "digest": stable_digest({"head": "head-1", "nonSuccess": ["deploy"], "terminal": False}),
            "expectedHead": {"seen": True, "since": None, "relation": "missing"},
            "updatedAt": "2026-08-12T08:06:00Z",
        }))
        dispatch = workflow_run(103, [], event="repository_dispatch", workflow_id=7, check_suite_id=603, conclusion="failure")
        self.write_scenario(pull=pull("head-1", [self.deploy_status(state="PENDING"),
                                                 check("deploy", "COMPLETED", "FAILURE", app="github-actions", suite_id=603)]),
                            census=[census(dispatch)])
        _, output = self.run_json(DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7", "--head", "head-1",
                                  "--check", "deploy", "--state", str(state), "--deadline", self.short_deadline(), "--interval", "0.05")
        self.assertEqual(output["state"], "timed-out", output["reason"])

    def test_pages_that_repeat_a_context_without_a_database_id_are_retried(self) -> None:
        deploy = self.deploy_status()
        repeated = {**check("build", "COMPLETED", "SUCCESS", app="other-app"), "databaseId": None}
        self.write_scenario(commitPages={
            "": {"contexts": {"nodes": [repeated, deploy, *[self.deploy_status(f"other-{n}") for n in range(98)]], "totalCount": 101,
                              "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}},
            "c1": {"contexts": {"nodes": [repeated], "totalCount": 101, "pageInfo": {"hasNextPage": False}}},
        })
        result, output = self.commit_wait("--check", "deploy", command="inspect")
        self.assertEqual(result.returncode, 2, output["reason"])
        self.assertIn("twice or without an id", output["reason"])

    def test_help_names_each_kind_and_the_flags_it_needs(self) -> None:
        for args in ((), ("wait",), ("inspect",)):
            result = subprocess.run([sys.executable, str(DELIVERY), *args, "--help"], text=True, capture_output=True, timeout=6)
            with self.subTest(args=args):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("without --pr, on the commit itself", result.stdout)
                self.assertIn("workflow-terminal  --run-id ID; --head SHA also checks the run's commit", result.stdout)

    def test_a_workflow_run_is_awaited_by_its_id_alone(self) -> None:
        self.write_scenario()
        result, output = self.run_json(
            DELIVERY, "wait", "workflow-terminal", "--repo", "owner/repo", "--run-id", "44",
            "--deadline", self.deadline(), "--interval", "0.01",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "satisfied")
        _, output = self.run_json(DELIVERY, "inspect", "workflow-terminal", "--repo", "owner/repo", "--run-id", "44", "--head", "other")
        self.assertEqual(output["state"], "invalidated")

    def rest_budget_wait(self, remaining: int, reset_in: float, seconds: float = 1.0, **scenario: object) -> dict:
        reset = int(datetime.now(timezone.utc).timestamp() + reset_in)
        running = {"id": 44, "head_sha": "head-1", "status": "in_progress", "conclusion": None, "html_url": "https://example.invalid/run"}
        self.write_scenario(**{"workflow": running, "coreRemaining": remaining, "coreReset": reset, **scenario})
        self.counter.unlink(missing_ok=True)
        _, output = self.run_json(
            DELIVERY, "wait", "workflow-terminal", "--repo", "owner/repo", "--run-id", "44", "--head", "head-1",
            "--deadline", (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat(), "--interval", "0.05",
            "--state", str(self.directory / f"budget-{remaining}.json"),
        )
        return output

    def test_a_wait_stops_spending_the_rest_budget_below_the_reserve(self) -> None:
        self.assertGreater(self.rest_budget_wait(4_900, reset_in=30)["metrics"]["observations"], 5)
        # Below the reserve kept for other work, the next observation would come
        # after the reset, past the deadline, so the wait ends without it.
        output = self.rest_budget_wait(900, reset_in=3600)
        self.assertEqual(output["state"], "timed-out")
        self.assertIn("REST budget held", output["reason"])
        self.assertEqual(output["metrics"]["observations"], 1)

    def test_a_census_reads_no_further_page_below_the_reserve(self) -> None:
        reset = int(datetime.now(timezone.utc).timestamp() + 3600)
        runs = census(workflow_run(101, matrix_jobs(1)), workflow_run(102, matrix_jobs(1, start=5, run_id=102), workflow_id=8))
        first, second = runs["runPages"][0]["workflow_runs"]
        runs["runPages"] = [{"total_count": 2, "workflow_runs": [first]}, {"total_count": 2, "workflow_runs": [second]}]
        self.write_scenario(census=[runs], coreRemaining=999, coreReset=reset)
        _, output = self.census_wait()
        self.assertEqual(output["state"], "timed-out")
        self.assertEqual(len(self.rest_requests()), 1)  # The first page told it 999 were left.

    def test_a_wait_spends_at_most_its_allowance_in_a_budget_window(self) -> None:
        sys.path.insert(0, str(DELIVERY.parent))
        from kgr_github import Gh, Metrics

        gh = Gh(Metrics(0.0))
        self.assertEqual(gh.pace(30, now=0), 30)  # Nothing known about the budget yet.
        now, remaining, spent = 0.0, 1_500, 0
        while now < 3_600:
            for _ in range(4):  # Four counted GETs an observation.
                remaining -= 1
                spent += 1
                gh.spent += 1
                gh.note_rate({"x-ratelimit-remaining": str(remaining), "x-ratelimit-reset": "3600"})
            now += gh.pace(30, now=now)
        # A quarter of the 500 above the reserve of 1,000, instead of spending
        # faster as the reset nears.
        self.assertLessEqual(spent, 125)
        self.assertGreater(spent, 100)
        self.assertEqual(gh.pace(30, now=3_601), 30)  # The budget has reset.

    def test_a_wait_honours_retry_after(self) -> None:
        sys.path.insert(0, str(DELIVERY.parent))
        from kgr_github import Gh, Metrics

        gh = Gh(Metrics(0.0))
        gh.note_rate({"retry-after": "120"})
        self.assertGreater(gh.pace(30), 110)

    def test_a_rate_limited_rest_read_retries_after_the_reset(self) -> None:
        reset = int((datetime.now(timezone.utc) + timedelta(hours=1)).timestamp())
        self.write_scenario(restRateLimited=True, coreReset=reset)
        _, output = self.run_json(
            DELIVERY, "wait", "workflow-terminal", "--repo", "owner/repo", "--run-id", "44", "--head", "head-1",
            "--deadline", (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat(), "--interval", "0.05",
        )
        self.assertEqual(output["state"], "timed-out")
        self.assertEqual(len(self.rest_requests()), 1)  # The reset falls after the deadline.

    def test_a_rate_limited_wait_recovers_once_the_budget_resets(self) -> None:
        reset = int(datetime.now(timezone.utc).timestamp()) + 2
        self.write_scenario(restRateLimited=True, coreReset=reset)
        _, output = self.run_json(
            DELIVERY, "wait", "workflow-terminal", "--repo", "owner/repo", "--run-id", "44", "--head", "head-1",
            "--deadline", (datetime.now(timezone.utc) + timedelta(seconds=5)).isoformat(), "--interval", "0.05",
        )
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(len(self.rest_requests()), 2)

    def test_a_retry_after_past_the_deadline_ends_the_wait_without_another_read(self) -> None:
        self.write_scenario(restSecondaryLimited=True)
        _, output = self.run_json(
            DELIVERY, "wait", "workflow-terminal", "--repo", "owner/repo", "--run-id", "44", "--head", "head-1",
            "--deadline", (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat(), "--interval", "30",
        )
        self.assertEqual(output["state"], "timed-out")
        self.assertIn("held the next observation until", output["reason"])
        self.assertEqual(len(self.rest_requests()), 1)

    def queued_gh(self, responses: list[dict]) -> "Any":
        """A Gh whose `gh` answers RESPONSES in order, as `gh api --include` prints them."""
        sys.path.insert(0, str(DELIVERY.parent))
        from kgr_github import Gh, Metrics

        queue = self.directory / "queue.json"
        queue.write_text(json.dumps(responses))
        script = self.directory / "queued" / "gh"
        script.parent.mkdir(exist_ok=True)
        script.write_text(QUEUED_GH)
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
        patch = unittest.mock.patch.dict(os.environ, {
            "PATH": f"{script.parent}{os.pathsep}{os.environ['PATH']}", "QUEUED_GH": str(queue)})
        patch.start()
        self.addCleanup(patch.stop)
        return Gh(Metrics(time.monotonic()), reserve=1_000)

    def test_a_304_refreshes_the_budget_and_the_page_links(self) -> None:
        reset = str(int(time.time()) + 3600)
        rate = lambda left: {"X-Ratelimit-Remaining": str(left), "X-Ratelimit-Reset": reset}
        gh = self.queued_gh([
            {"status": 200, "headers": {"ETag": "one", "Link": '<https://api.github.com/x?page=2>; rel="next"', **rate(1_500)}, "body": [1]},
            {"status": 200, "headers": {"ETag": "two", **rate(1_499)}, "body": [2]},
            # The list shrank to one page, and other work spent the budget meanwhile.
            {"status": 304, "headers": {"Link": '<https://api.github.com/x?page=1>; rel="first"', **rate(999)}},
            {"status": 304, "headers": {}},
        ])
        self.assertEqual(gh.rest_pages("x"), [[1], [2]])
        self.assertEqual(gh.rest_pages("x"), [[1]])
        self.assertEqual(gh.metrics.not_modified, 1)
        self.assertEqual(gh.spent, 2)  # A 304 is not spent.
        self.assertIsNotNone(gh.not_before())
        with self.assertRaises(Exception) as raised:
            gh.rest_pages("x")  # Below the reserve, no read goes out.
        self.assertIn("under the 1000", str(raised.exception))
        self.assertEqual(len(json.loads((self.directory / "queue.json").read_text())), 1)

    def test_a_secondary_limit_without_a_retry_time_backs_off_a_minute(self) -> None:
        gh = self.queued_gh([{"status": 429, "headers": {}, "body": {"message": "Too Many Requests"}}])
        with self.assertRaises(Exception):
            gh.rest("x")
        self.assertGreater(gh.not_before() - time.time(), 55)
        self.assertGreater(gh.pace(30), 55)

    def test_a_resumed_wait_honours_the_hold_an_earlier_run_learned(self) -> None:
        state = str(self.directory / "held.json")
        command = [DELIVERY, "wait", "workflow-terminal", "--repo", "owner/repo", "--run-id", "44", "--head", "head-1",
                   "--interval", "0.05", "--state", state, "--deadline"]
        self.write_scenario(restSecondaryLimited=True)
        _, first = self.run_json(*command, (datetime.now(timezone.utc) + timedelta(seconds=0.5)).isoformat())
        self.assertIn("held the next observation until", first["reason"])
        self.write_scenario()  # GitHub would answer now, but asked for 25 seconds.
        _, second = self.run_json(*command, (datetime.now(timezone.utc) + timedelta(seconds=0.5)).isoformat())
        self.assertEqual(second["state"], "timed-out")
        self.assertIn("held the next observation until", second["reason"])
        self.assertEqual(len(self.rest_requests()), 1)

    def test_a_smaller_budget_keeps_a_proportionate_reserve(self) -> None:
        sys.path.insert(0, str(DELIVERY.parent))
        from kgr_github import Gh, Metrics

        gh = Gh(Metrics(0.0), reserve=1_000)
        reset = str(int(time.time()) + 3600)
        # A GitHub Actions token's 1,000 an hour: a fifth of it is kept, so a wait can still read.
        gh.note_rate({"x-ratelimit-limit": "1000", "x-ratelimit-remaining": "999", "x-ratelimit-reset": reset})
        self.assertEqual(gh.kept(), 200)
        self.assertFalse(gh.below_reserve())
        gh.note_rate({"x-ratelimit-limit": "5000", "x-ratelimit-remaining": "999", "x-ratelimit-reset": reset})
        self.assertTrue(gh.below_reserve())

    def test_a_paced_wait_stops_promptly_when_asked(self) -> None:
        reset = int(datetime.now(timezone.utc).timestamp() + 3600)
        running = {"id": 44, "head_sha": "head-1", "status": "in_progress", "conclusion": None, "html_url": "https://example.invalid/run"}
        # 1,100 left: the allowance paces the next observation minutes away, inside the deadline.
        self.write_scenario(workflow=running, coreRemaining=1_100, coreReset=reset)
        process = subprocess.Popen(
            [sys.executable, str(DELIVERY), "wait", "workflow-terminal", "--repo", "owner/repo", "--run-id", "44",
             "--head", "head-1", "--deadline", (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat(),
             "--interval", "0.05", "--json"],
            cwd=self.directory, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        log = self.counter.with_name("counter.log")
        for _ in range(100):
            if log.exists():
                break
            time.sleep(0.05)
        time.sleep(0.3)
        process.terminate()
        stdout, _ = process.communicate(timeout=3)
        self.assertEqual(json.loads(stdout)["state"], "cancelled")

    def test_checks_terminal_without_a_selector_names_all_workflows(self) -> None:
        self.write_scenario()
        result, output = self.run_json(
            DELIVERY, "wait", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--deadline", self.deadline(), "--interval", "0.01",
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(output["state"], "operational-error")
        self.assertIn("--all-workflows", output["reason"])
        self.assertIn("--check", output["reason"])
        self.assertEqual(output["metrics"]["apiRequests"], 0)

    def test_all_workflows_is_not_satisfied_by_the_jobs_visible_so_far(self) -> None:
        # GocciaScript#1287: 4 checks were visible while 35 more were pending.
        partial = census(workflow_run(101, matrix_jobs(4), status="in_progress", conclusion=None))
        self.write_scenario(census=[partial])
        _, inspected = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--all-workflows",
        )
        self.assertEqual(inspected["state"], "waiting")
        # The census sequence, not a wall-clock deadline, bounds the wait: a
        # short deadline can pass before the first observation completes.
        self.reset_census()
        complete = census(workflow_run(101, matrix_jobs(39)))
        self.write_scenario(census=[partial, partial, complete])
        _, waited = self.census_wait()
        self.assertEqual(waited["state"], "satisfied")
        self.assertEqual(len(waited["observation"]["runs"][0]["jobs"]), 39)
        # Two identical partial observations, then two complete ones: a stable
        # partial census never satisfies the wait.
        self.assertEqual(waited["metrics"]["observations"], 4)

    def test_all_workflows_waits_for_jobs_that_spawn_later(self) -> None:
        self.write_scenario(census=[
            census(workflow_run(101, matrix_jobs(4), status="in_progress", conclusion=None)),
            census(workflow_run(101, matrix_jobs(4) + matrix_jobs(35, "queued", None, start=4), status="in_progress", conclusion=None)),
            census(workflow_run(101, matrix_jobs(39))),
        ])
        result, output = self.census_wait()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(len(output["observation"]["runs"][0]["jobs"]), 39)
        # Two identical all-success observations follow the two pending ones.
        self.assertEqual(output["metrics"]["observations"], 4)

    def test_all_workflows_requires_a_stable_census_before_success(self) -> None:
        # A run triggered after the first run completes must not be missed.
        first = workflow_run(101, matrix_jobs(4))
        later = workflow_run(202, matrix_jobs(35, run_id=202), name="Follow-up")
        self.write_scenario(census=[
            census(first),
            census(first, workflow_run(202, [], status="queued", conclusion=None, name="Follow-up")),
            census(first, later),
        ])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual([run["id"] for run in output["observation"]["runs"]], [101, 202])
        self.assertEqual(sum(len(run["jobs"]) for run in output["observation"]["runs"]), 39)
        self.assertEqual(output["metrics"]["observations"], 4)

    def test_all_workflows_stable_success_is_satisfied(self) -> None:
        self.write_scenario(census=[census(
            workflow_run(101, matrix_jobs(3) + [
                workflow_job(2000, "optional", conclusion="skipped"),
                workflow_job(2001, "advisory", conclusion="neutral"),
            ]),
            workflow_run(202, matrix_jobs(2, run_id=202), name="Lint"),
        )])
        result, output = self.census_wait()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["metrics"]["observations"], 2)
        self.assertEqual(len(output["observation"]["runs"]), 2)

    def test_all_workflows_counts_only_the_newest_run_of_a_workflow_and_event(self) -> None:
        # A second event for the same head cancelled run 101; run 102 replaced it.
        for conclusion in ("cancelled", "failure"):
            with self.subTest(conclusion=conclusion):
                self.reset_census()
                self.write_scenario(census=[census(
                    workflow_run(101, [workflow_job(1000, "build", conclusion=conclusion)], conclusion=conclusion, workflow_id=9),
                    workflow_run(102, [workflow_job(1001, "build", run_id=102)], workflow_id=9),
                )])
                result, output = self.census_wait()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output["state"], "satisfied")
                self.assertIn("1 workflow runs", output["reason"])
                superseded = [run["id"] for run in output["observation"]["runs"] if run.get("superseded")]
                self.assertEqual(superseded, [101])

    def test_all_workflows_newest_run_decides_even_when_an_older_one_passed(self) -> None:
        self.write_scenario(census=[census(
            workflow_run(101, [workflow_job(1000, "build")], workflow_id=9),
            workflow_run(102, [workflow_job(1001, "build", conclusion="failure", run_id=102)], conclusion="failure", workflow_id=9),
        )])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "changed")
        self.assertIn("failure", output["reason"])

    def test_all_workflows_keeps_runs_of_other_events_and_workflows(self) -> None:
        # The same workflow on another event, and another workflow, are their own sources.
        for other in (
            workflow_run(102, [workflow_job(1001, "build", conclusion="failure", run_id=102)], conclusion="failure", workflow_id=9, event="push"),
            workflow_run(102, [workflow_job(1001, "lint", conclusion="failure", run_id=102)], conclusion="failure", workflow_id=10, name="Lint"),
        ):
            with self.subTest(event=other["run"]["event"], workflow=other["run"]["workflow_id"]):
                self.reset_census()
                self.write_scenario(census=[census(
                    workflow_run(103, [workflow_job(1002, "build", run_id=103)], workflow_id=9),
                    other,
                )])
                _, output = self.census_wait()
                self.assertEqual(output["state"], "changed")

    def test_all_workflows_waits_for_the_newest_run_while_it_is_in_progress(self) -> None:
        self.write_scenario(census=[census(
            workflow_run(101, [workflow_job(1000, "build", conclusion="cancelled")], conclusion="cancelled", workflow_id=9),
            workflow_run(102, [workflow_job(1001, "build", "in_progress", None, run_id=102)], status="in_progress", conclusion=None, workflow_id=9),
        )])
        _, output = self.census_wait(deadline=self.short_deadline())
        self.assertNotIn(output["state"], ("satisfied", "changed"))

    def cancelled_duplicate(self, older: dict | None = None, **newer: object) -> list[dict]:
        """Run 101 and the newer run 102 of workflow 9, both for one pull_request event.

        Their concurrency group cancelled 102, the run that joined it first.
        """
        return [
            older or workflow_run(101, [workflow_job(1000, "build")], workflow_id=9, check_suite_id=501),
            workflow_run(
                102, newer.pop("jobs", [workflow_job(1001, "build", conclusion="cancelled", run_id=102)]),
                conclusion="cancelled", workflow_id=9, check_suite_id=502,
                updated_at=newer.pop("updated_at", "2026-08-12T08:00:02Z"), **newer,
            ),
        ]

    def test_all_workflows_names_a_newest_run_cancelled_beside_a_passed_older_run(self) -> None:
        self.write_scenario(census=[census(*self.cancelled_duplicate())])
        for command in ("wait", "inspect"):
            with self.subTest(command=command):
                self.reset_census()
                if command == "wait":
                    result, output = self.census_wait()
                else:
                    result, output = self.run_json(
                        DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
                        "--pr", "7", "--head", "head-1", "--all-workflows",
                    )
                self.assertEqual(result.returncode, 0, result.stderr)
                # Like success, only wait can confirm the census is stable.
                self.assertEqual(output["state"], "recoverable" if command == "wait" else "waiting")
                self.assertIn("gh run rerun 102 --repo owner/repo", output["reason"])
                runs = {run["id"]: run for run in output["observation"]["runs"]}
                self.assertTrue(runs[101].get("superseded"))
                self.assertEqual(runs[102]["cancelledDuplicate"], {
                    "olderRunId": 101,
                    "olderRun": "passed",
                    "rerun": "gh run rerun 102 --repo owner/repo",
                })

    def test_all_workflows_does_not_name_a_cancelled_run_that_is_older(self) -> None:
        # The usual cancel-in-progress order: the newer run cancelled the older one.
        for conclusion, expected in (("success", "satisfied"), ("failure", "changed")):
            with self.subTest(newer=conclusion):
                self.reset_census()
                self.write_scenario(census=[census(
                    workflow_run(101, [workflow_job(1000, "build", conclusion="cancelled")], conclusion="cancelled", workflow_id=9),
                    workflow_run(102, [workflow_job(1001, "build", conclusion=conclusion, run_id=102)], conclusion=conclusion, workflow_id=9),
                )])
                _, output = self.census_wait()
                self.assertEqual(output["state"], expected)
                self.assertFalse(any(run.get("cancelledDuplicate") for run in output["observation"]["runs"]))

    def test_all_workflows_cancelled_newest_run_without_a_passed_older_run_is_a_failure(self) -> None:
        for name, older in (
            ("older run failed", workflow_run(101, [workflow_job(1000, "build", conclusion="failure")], conclusion="failure", workflow_id=9)),
            # A job that may fail without failing its run.
            ("older run passed with a failed job", workflow_run(101, [workflow_job(1000, "build", conclusion="failure")], workflow_id=9)),
            ("older run is another event", workflow_run(101, [workflow_job(1000, "build")], workflow_id=9, event="push")),
            ("older run is another workflow", workflow_run(101, [workflow_job(1000, "build")], workflow_id=10, name="Lint")),
        ):
            with self.subTest(name):
                self.reset_census()
                self.write_scenario(census=[census(*self.cancelled_duplicate(older))])
                _, output = self.census_wait()
                self.assertEqual(output["state"], "changed")
                self.assertIn("cancelled", output["reason"])

    def test_all_workflows_waits_for_the_older_run_beside_a_cancelled_newest_run(self) -> None:
        running = workflow_run(101, [workflow_job(1000, "build", "in_progress", None)], status="in_progress", conclusion=None, workflow_id=9)
        for conclusion, expected in (("success", "recoverable"), ("failure", "changed")):
            with self.subTest(older=conclusion):
                self.reset_census()
                finished = workflow_run(101, [workflow_job(1000, "build", conclusion=conclusion)], conclusion=conclusion, workflow_id=9)
                self.write_scenario(census=[
                    census(*self.cancelled_duplicate(running)),
                    census(*self.cancelled_duplicate(running)),
                    census(*self.cancelled_duplicate(finished)),
                ])
                _, output = self.census_wait()
                self.assertEqual(output["state"], expected)
                # A failure decides at once; a rerun waits for a second identical census.
                self.assertEqual(output["metrics"]["observations"], 4 if expected == "recoverable" else 3)
        self.reset_census()
        self.write_scenario(census=[census(*self.cancelled_duplicate(running))])
        _, output = self.census_wait(deadline=self.short_deadline())
        self.assertEqual(output["state"], "timed-out")
        _, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--all-workflows",
        )
        self.assertEqual(output["state"], "waiting")
        self.assertIn("waiting for the older run of the same workflow and event (101)", output["reason"])

    def test_a_cancelled_duplicate_cancelled_again_after_its_rerun_is_a_failure(self) -> None:
        # A rerun can be cancelled for its own reason, such as a job timeout;
        # naming it recoverable again would loop on reruns.
        self.write_scenario(census=[census(*self.cancelled_duplicate(attempt=2))])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "changed")
        self.assertIn("cancelled", output["reason"])
        self.assertFalse(any(run.get("cancelledDuplicate") for run in output["observation"]["runs"]))

    def test_a_cancelled_run_that_did_not_race_the_older_run_is_a_failure(self) -> None:
        for name, newer in (
            # Cancelled by hand after the older run had finished.
            ("cancelled after the older run finished", {"updated_at": "2026-08-12T09:00:00Z"}),
            # Another pull request whose branch points at the same commit.
            ("another branch", {"branch": "other"}),
            # A fork's pull request whose branch has the same name.
            ("another repository", {"head_repository": 2}),
            # The branch's pull request against another base.
            ("another pull request", {"pull_requests": [8]}),
            # A job failed before the rest were cancelled.
            ("a job failed", {"jobs": [
                workflow_job(1001, "build", conclusion="failure", run_id=102),
                workflow_job(1002, "test", conclusion="cancelled", run_id=102),
            ]}),
        ):
            with self.subTest(name):
                self.reset_census()
                self.write_scenario(census=[census(*self.cancelled_duplicate(**newer))])
                _, output = self.census_wait()
                self.assertEqual(output["state"], "changed")
                self.assertFalse(any(run.get("cancelledDuplicate") for run in output["observation"]["runs"]))

    def test_an_older_run_that_started_after_the_cancellation_did_not_race(self) -> None:
        # Created first, but it waited in a queue until after the cancellation.
        older = workflow_run(101, [workflow_job(1000, "build")], workflow_id=9, check_suite_id=501, started_at="2026-08-12T08:01:00Z")
        self.write_scenario(census=[census(*self.cancelled_duplicate(older))])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "changed")

    def test_a_superseded_run_still_going_holds_the_rerun(self) -> None:
        # Its newer run passed, but the active older run could share a group.
        active = workflow_run(103, [], status="in_progress", conclusion=None, workflow_id=10, name="Lint")
        replaced = workflow_run(104, [workflow_job(1004, "lint", run_id=104)], workflow_id=10, name="Lint")
        self.write_scenario(census=[census(*self.cancelled_duplicate(), active, replaced)])
        _, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--all-workflows",
        )
        self.assertEqual(output["state"], "waiting")
        self.assertIn("can be rerun once", output["reason"])

    def test_a_cancelled_named_check_left_from_before_a_passed_rerun_is_stale(self) -> None:
        # The rollup is read before the runs and still shows the first attempt.
        older = self.cancelled_duplicate()[0]
        passed = workflow_run(102, [workflow_job(1003, "build", run_id=102)], workflow_id=9, check_suite_id=502, attempt=2)
        stale = check("build", "COMPLETED", "CANCELLED", app="github-actions", event="pull_request", suite_id=502, workflow=9)
        fresh = check("build", "COMPLETED", "SUCCESS", app="github-actions", event="pull_request", suite_id=502, workflow=9)
        self.write_scenario(
            pullsByRequest=[pull("head-1", [stale])] * 3 + [pull("head-1", [fresh])],
            census=[census(older, passed)],
        )
        _, output = self.census_wait("--check", "build")
        self.assertEqual(output["state"], "satisfied")

    def test_runs_named_for_this_pull_request_can_be_duplicates(self) -> None:
        older = workflow_run(101, [workflow_job(1000, "build")], workflow_id=9, check_suite_id=501, pull_requests=[7])
        self.write_scenario(census=[census(*self.cancelled_duplicate(older, pull_requests=[7]))])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "recoverable")
        # An older run named only for another pull request does not count.
        self.reset_census()
        other = workflow_run(101, [workflow_job(1000, "build")], workflow_id=9, check_suite_id=501, pull_requests=[8])
        self.write_scenario(census=[census(*self.cancelled_duplicate(other))])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "changed")

    def test_a_failed_named_check_from_a_cancelled_duplicate_still_counts(self) -> None:
        # The rollup shows a failure the job census has not caught up with.
        self.write_scenario(
            pull=pull("head-1", [check("build", "COMPLETED", "FAILURE", app="github-actions", event="pull_request", suite_id=502, workflow=9)]),
            census=[census(*self.cancelled_duplicate())],
        )
        _, output = self.census_wait("--check", "build")
        self.assertEqual(output["state"], "changed")

    def test_a_run_that_appears_before_the_census_is_stable_holds_the_rerun(self) -> None:
        # A follow-up run could share the rerun's concurrency group.
        follow_up = workflow_run(103, [], status="queued", conclusion=None, workflow_id=10, name="Follow-up")
        self.write_scenario(census=[
            census(*self.cancelled_duplicate()),
            census(*self.cancelled_duplicate(), follow_up),
        ])
        _, output = self.census_wait(deadline=self.short_deadline())
        self.assertNotEqual(output["state"], "recoverable")

    def test_runs_without_a_known_head_repository_are_not_duplicates(self) -> None:
        runs = self.cancelled_duplicate()
        for item in runs:
            item["run"].pop("head_repository")
        self.write_scenario(census=[census(*runs)])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "changed")

    def test_a_first_attempt_cancelled_named_check_is_changed(self) -> None:
        # No earlier attempt exists for the cancellation to be left from.
        running = workflow_run(103, [workflow_job(1002, "build-x", "in_progress", None, run_id=103)], status="in_progress", conclusion=None, workflow_id=10, name="Build", check_suite_id=503)
        self.write_scenario(
            pull=pull("head-1", [check("build-x", "COMPLETED", "CANCELLED", app="github-actions", event="pull_request", suite_id=503, workflow=10)]),
            census=[census(running)],
        )
        _, output = self.census_wait("--check", "build-x")
        self.assertEqual(output["state"], "changed")

    def test_a_cancelled_job_waits_while_its_possible_duplicate_run_completes(self) -> None:
        # The race cancels the jobs seconds before the run itself completes.
        running = workflow_run(101, [workflow_job(1000, "build", "in_progress", None)], status="in_progress", conclusion=None, workflow_id=9, check_suite_id=501)
        finishing = workflow_run(102, [workflow_job(1001, "build", conclusion="cancelled", run_id=102)], status="in_progress", conclusion=None, workflow_id=9, check_suite_id=502)
        passed = self.cancelled_duplicate()[0]
        self.write_scenario(census=[
            census(running, finishing),
            census(*self.cancelled_duplicate(running)),
            census(*self.cancelled_duplicate(passed)),
        ])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "recoverable")

    def test_a_cancelled_named_check_waits_while_its_possible_duplicate_run_completes(self) -> None:
        running = workflow_run(101, [workflow_job(1000, "build", "in_progress", None)], status="in_progress", conclusion=None, workflow_id=9, check_suite_id=501)
        finishing = workflow_run(102, [workflow_job(1001, "build", conclusion="cancelled", run_id=102)], status="in_progress", conclusion=None, workflow_id=9, check_suite_id=502)
        cancelled_check = check("build", "COMPLETED", "CANCELLED", app="github-actions", event="pull_request", suite_id=502, workflow=9)
        self.write_scenario(
            pull=pull("head-1", [cancelled_check]),
            census=[census(running, finishing), census(*self.cancelled_duplicate())],
        )
        _, output = self.census_wait("--check", "build")
        self.assertEqual(output["state"], "recoverable")

    def test_a_cancelled_named_check_of_a_superseded_run_does_not_wait(self) -> None:
        # Run 102 is superseded by 103, so it can never be a cancelled duplicate.
        first = workflow_run(101, [workflow_job(1000, "build")], workflow_id=9, check_suite_id=501)
        superseded = workflow_run(102, [workflow_job(1001, "lint", conclusion="cancelled", run_id=102)], status="in_progress", conclusion=None, workflow_id=9, check_suite_id=502)
        newest = workflow_run(103, [workflow_job(1002, "build", run_id=103)], workflow_id=9, check_suite_id=503)
        self.write_scenario(
            pull=pull("head-1", [check("lint", "COMPLETED", "CANCELLED", app="github-actions", event="pull_request", suite_id=502, workflow=9)]),
            census=[census(first, superseded, newest)],
        )
        _, output = self.census_wait("--check", "lint")
        self.assertEqual(output["state"], "changed")

    def test_a_cancelled_named_check_a_passed_rerun_did_not_replace_is_changed(self) -> None:
        # The rerun's matrix no longer has the shard, so its cancellation is current.
        older = self.cancelled_duplicate()[0]
        passed = workflow_run(102, [workflow_job(1003, "build", run_id=102)], workflow_id=9, check_suite_id=502, attempt=2)
        self.write_scenario(
            pull=pull("head-1", [check("shard-9", "COMPLETED", "CANCELLED", app="github-actions", event="pull_request", suite_id=502, workflow=9)]),
            census=[census(older, passed)],
        )
        _, output = self.census_wait("--check", "shard-9")
        self.assertEqual(output["state"], "changed")

    def test_an_older_run_that_was_rerun_cannot_show_the_race(self) -> None:
        # Its creation and its latest update span two attempts.
        older = workflow_run(101, [workflow_job(1000, "build")], workflow_id=9, check_suite_id=501, attempt=2, updated_at="2026-08-12T09:30:00Z")
        self.write_scenario(census=[census(*self.cancelled_duplicate(older, updated_at="2026-08-12T09:00:00Z"))])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "changed")

    def test_a_current_named_check_failure_beside_a_cancelled_duplicate_is_changed(self) -> None:
        # A running workflow's check failed before its job census shows it.
        running = workflow_run(103, [workflow_job(1002, "lint", "in_progress", None, run_id=103)], status="in_progress", conclusion=None, workflow_id=10, name="Lint", check_suite_id=503)
        self.write_scenario(
            pull=pull("head-1", [check("lint", "COMPLETED", "FAILURE", app="github-actions", event="pull_request", suite_id=503, workflow=10)]),
            census=[census(*self.cancelled_duplicate(), running)],
        )
        _, output = self.census_wait("--check", "lint")
        self.assertEqual(output["state"], "changed")
        self.assertIn("check lint: failure", output["reason"])

    def test_a_cancelled_duplicate_is_recoverable_only_once_other_runs_have_finished(self) -> None:
        # Its rerun could join a concurrency group the running workflow shares.
        running = workflow_run(103, [workflow_job(1002, "lint", "in_progress", None, run_id=103)], status="in_progress", conclusion=None, workflow_id=10, name="Lint")
        finished = workflow_run(103, [workflow_job(1002, "lint", run_id=103)], workflow_id=10, name="Lint")
        self.write_scenario(census=[census(*self.cancelled_duplicate(), running)])
        _, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--all-workflows",
        )
        self.assertEqual(output["state"], "waiting")
        self.assertIn("can be rerun once the other 1 workflow runs", output["reason"])
        self.reset_census()
        self.write_scenario(census=[census(*self.cancelled_duplicate(), running), census(*self.cancelled_duplicate(), finished)])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "recoverable")

    def test_a_named_check_waits_for_a_rerun_that_has_no_check_runs_yet(self) -> None:
        # Until the new attempt creates its check runs, the rollup still shows
        # the first attempt's cancelled ones.
        older = self.cancelled_duplicate()[0]
        queued = workflow_run(102, [], status="queued", conclusion=None, workflow_id=9, check_suite_id=502, attempt=2)
        passed = workflow_run(102, [workflow_job(1003, "build", run_id=102)], workflow_id=9, check_suite_id=502, attempt=2)
        cancelled_check = check("build", "COMPLETED", "CANCELLED", app="github-actions", event="pull_request", suite_id=502, workflow=9)
        passed_check = check("build", "COMPLETED", "SUCCESS", app="github-actions", event="pull_request", suite_id=502, workflow=9)
        self.write_scenario(
            pullsByRequest=[pull("head-1", [cancelled_check]), pull("head-1", [cancelled_check]), pull("head-1", [passed_check])],
            census=[census(older, queued), census(older, queued), census(older, passed)],
        )
        _, output = self.census_wait("--check", "build")
        self.assertEqual(output["state"], "satisfied")

    def test_all_workflows_reports_another_failure_before_a_cancelled_duplicate(self) -> None:
        self.write_scenario(census=[census(
            *self.cancelled_duplicate(),
            workflow_run(103, [workflow_job(1002, "lint", conclusion="failure", run_id=103)], conclusion="failure", workflow_id=10, name="Lint"),
        )])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "changed")
        self.assertIn("lint: failure", output["reason"])
        self.assertNotIn("build", output["reason"])

    def test_a_named_check_from_a_cancelled_duplicate_run_is_recoverable(self) -> None:
        # The run's jobs are also its check runs, numbered by its check suite.
        self.write_scenario(
            pull=pull("head-1", [
                check("build", "COMPLETED", "SUCCESS", app="github-actions", event="pull_request", suite_id=501, workflow=9),
                check("build", "COMPLETED", "CANCELLED", app="github-actions", event="pull_request", suite_id=502, workflow=9),
            ]),
            census=[census(*self.cancelled_duplicate())],
        )
        _, output = self.census_wait("--check", "build")
        self.assertEqual(output["state"], "recoverable")

    def test_all_workflows_is_satisfied_once_the_cancelled_duplicate_is_rerun(self) -> None:
        # `gh run rerun` starts a new attempt of the same run.
        older = self.cancelled_duplicate()[0]
        self.write_scenario(census=[
            census(older, workflow_run(102, [workflow_job(1003, "build", "in_progress", None, run_id=102)], status="in_progress", conclusion=None, workflow_id=9, attempt=2)),
            census(older, workflow_run(102, [workflow_job(1003, "build", run_id=102)], workflow_id=9, attempt=2)),
        ])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "satisfied")
        self.assertFalse(any(run.get("cancelledDuplicate") for run in output["observation"]["runs"]))

    def test_all_workflows_inspect_cannot_confirm_stability(self) -> None:
        self.write_scenario(census=[census(workflow_run(101, matrix_jobs(2)))])
        _, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo",
            "--pr", "7", "--head", "head-1", "--all-workflows",
        )
        self.assertEqual(output["state"], "waiting")
        self.assertIn("stable", output["reason"])

    def test_rest_page_size_preserves_complete_workflow_census(self) -> None:
        runs = [
            workflow_run(101, matrix_jobs(3)),
            workflow_run(202, matrix_jobs(2, run_id=202), name="Follow-up"),
        ]
        state = census(*runs)
        state["runPages"] = [
            {"total_count": 2, "workflow_runs": [item["run"]]} for item in runs
        ]
        state["jobPages"] = {
            str(item["run"]["id"]): [
                {"total_count": len(item["jobs"]), "jobs": [job]} for job in item["jobs"]
            ]
            for item in runs
        }
        for size, arguments in (
            (100, []),
            (1, ["--rest-page-size", "1"]),
            (100, ["--rest-page-size", "100"]),
        ):
            with self.subTest(size=size, arguments=arguments):
                self.reset_census()
                self.write_scenario(census=[state], expectedRestPageSize=size)
                result, output = self.census_wait(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output["state"], "satisfied")
                self.assertEqual(output["metrics"]["observations"], 2)
                self.assertEqual([run["id"] for run in output["observation"]["runs"]], [101, 202])
                self.assertEqual(sum(len(run["jobs"]) for run in output["observation"]["runs"]), 5)

    def test_small_rest_pages_keep_later_failures_and_missing_pages_visible(self) -> None:
        jobs = matrix_jobs(2)
        jobs[-1]["conclusion"] = "failure"
        state = census(workflow_run(101, jobs))
        state["jobPages"]["101"] = [
            {"total_count": 2, "jobs": [job]} for job in jobs
        ]
        self.write_scenario(census=[state], expectedRestPageSize=1)
        _, output = self.census_wait("--rest-page-size", "1")
        self.assertEqual(output["state"], "changed")
        self.assertIn("test (1)", output["reason"])
        self.reset_census()
        state["jobPages"]["101"].pop()
        self.write_scenario(census=[state], expectedRestPageSize=1)
        _, output = self.census_wait("--rest-page-size", "1", deadline=self.short_deadline())
        self.assertEqual(output["state"], "timed-out")
        self.assertGreater(output["metrics"]["retries"], 0)

    def test_rest_page_size_applies_to_rate_limit_fallback(self) -> None:
        self.write_scenario(
            graphqlRateLimited=True,
            expectedRestPageSize=5,
            restChecks={"check_runs": [{"name": "CI", "status": "completed", "conclusion": "success"}]},
        )
        result, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--check", "CI", "--rest-page-size", "5",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["metrics"]["rateLimitFallbacks"], 1)

        # With --all-workflows the fallback runs inside the workflow census,
        # which must hand it the same page size.
        self.reset_census()
        self.counter.unlink(missing_ok=True)
        self.write_scenario(
            graphqlRateLimited=True,
            expectedRestPageSize=5,
            restChecks={"check_runs": [{"name": "CI", "status": "completed", "conclusion": "success"}]},
            census=[census(workflow_run(101, matrix_jobs(1)))],
        )
        result, output = self.run_json(
            DELIVERY, "inspect", "checks-terminal", "--repo", "owner/repo", "--pr", "7",
            "--head", "head-1", "--all-workflows", "--check", "CI", "--rest-page-size", "5",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output["metrics"]["rateLimitFallbacks"], 1)
        self.assertEqual([run["id"] for run in output["observation"]["runs"]], [101])

    def test_rest_page_size_rejects_invalid_values_before_transport(self) -> None:
        for command in ("inspect", "wait"):
            for value in ("0", "101", "-1", "five"):
                with self.subTest(command=command, value=value):
                    result = subprocess.run(
                        [sys.executable, str(DELIVERY), command, "checks-terminal",
                         "--rest-page-size", value],
                        text=True, capture_output=True, cwd=self.directory,
                        env=self.environment, timeout=6,
                    )
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("--rest-page-size", result.stderr)
                    self.assertFalse(self.counter.exists())

    def test_all_workflows_reports_a_later_failure(self) -> None:
        for conclusion in ("failure", "cancelled", "timed_out", "action_required"):
            with self.subTest(conclusion=conclusion):
                self.reset_census()
                self.write_scenario(census=[
                    census(workflow_run(101, matrix_jobs(4) + matrix_jobs(2, "in_progress", None, start=4), status="in_progress", conclusion=None)),
                    census(workflow_run(101, matrix_jobs(4) + [
                        workflow_job(1004, "test (4)", conclusion=conclusion),
                        workflow_job(1005, "test (5)", "in_progress", None),
                    ], status="in_progress", conclusion=None)),
                ])
                result, output = self.census_wait()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output["state"], "changed")
                self.assertIn("test (4)", output["reason"])
                self.assertIn(conclusion, output["reason"])
                self.assertEqual(output["metrics"]["observations"], 2)

    def test_all_workflows_reports_a_failed_run_without_failed_jobs(self) -> None:
        self.write_scenario(census=[census(workflow_run(101, [], conclusion="startup_failure"))])
        _, output = self.census_wait()
        self.assertEqual(output["state"], "changed")
        self.assertIn("startup_failure", output["reason"])

    def test_all_workflows_keeps_waiting_while_any_run_is_not_terminal(self) -> None:
        for status in ("queued", "in_progress", "waiting", "pending", "requested"):
            with self.subTest(status=status):
                self.reset_census()
                self.write_scenario(census=[census(
                    workflow_run(101, matrix_jobs(3)),
                    workflow_run(202, [], status=status, conclusion=None, name="Deploy"),
                )])
                _, output = self.census_wait(deadline=self.short_deadline())
                self.assertEqual(output["state"], "timed-out")

    def test_all_workflows_waits_when_no_run_has_appeared(self) -> None:
        self.write_scenario(census=[census()])
        _, output = self.census_wait(deadline=self.short_deadline())
        self.assertEqual(output["state"], "timed-out")
        self.assertEqual(output["observation"]["runs"], [])

    def test_all_workflows_invalidates_a_changed_head(self) -> None:
        self.write_scenario(
            pull=pull("head-2", []), census=[census(workflow_run(101, matrix_jobs(2)))],
            compare={"head-2...head-1": {"status": "behind"}},
        )
        _, output = self.census_wait()
        self.assertEqual(output["state"], "invalidated")
        self.assertEqual(output["observation"]["head"], "head-2")
        self.assertIn("a later commit than the expected one", output["reason"])

    def test_all_workflows_waits_for_github_to_move_the_head_after_a_push(self) -> None:
        self.write_scenario(
            pullsByRequest=[pull("head-0", [])] * 4 + [pull("head-1", [])],
            census=[census(workflow_run(101, matrix_jobs(2)))],
            compare={"head-0...head-1": {"status": "ahead"}},
        )
        _, output = self.census_wait()
        self.assertEqual(output["state"], "satisfied", output["reason"])
        self.assertEqual(output["observation"]["head"], "head-1")

    def test_all_workflows_refuses_a_pull_request_without_a_head(self) -> None:
        self.write_scenario(pull={"headRefOid": None}, census=[census(workflow_run(101, matrix_jobs(2)))])
        result, output = self.census_wait()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(output["state"], "operational-error")
        self.assertIn("head", output["reason"])

    def test_all_workflows_refuses_malformed_run_or_job_pages(self) -> None:
        good = census(workflow_run(101, matrix_jobs(2)))
        missing_run_total = dict(good, runPages=[{"workflow_runs": good["runPages"][0]["workflow_runs"]}])
        missing_runs = dict(good, runPages=[{"total_count": 1}])
        missing_job_total = dict(good, jobPages={"101": [{"jobs": matrix_jobs(2)}]})
        other_head = census(workflow_run(101, matrix_jobs(2), head="head-2"))
        for name, state in (
            ("missing run total", missing_run_total),
            ("missing runs", missing_runs),
            ("missing job total", missing_job_total),
            ("run on another head", other_head),
        ):
            with self.subTest(name):
                self.reset_census()
                self.write_scenario(census=[state])
                result, output = self.census_wait()
                self.assertEqual(result.returncode, 2, name)
                self.assertEqual(output["state"], "operational-error", name)

    def test_all_workflows_never_treats_an_incomplete_census_as_complete(self) -> None:
        good = census(workflow_run(101, matrix_jobs(2)))
        short_runs = dict(good, runPages=[{"total_count": 2, "workflow_runs": good["runPages"][0]["workflow_runs"]}])
        short_jobs = dict(good, jobPages={"101": [{"total_count": 39, "jobs": matrix_jobs(2)}]})
        racing = dict(good, runPages=[
            {"total_count": 1, "workflow_runs": good["runPages"][0]["workflow_runs"]},
            {"total_count": 2, "workflow_runs": []},
        ])
        for name, state in (("runs", short_runs), ("jobs", short_jobs), ("racing pages", racing)):
            with self.subTest(name):
                self.reset_census()
                self.write_scenario(census=[state])
                _, output = self.census_wait(deadline=self.short_deadline())
                self.assertEqual(output["state"], "timed-out", name)
                self.assertGreater(output["metrics"]["retries"], 0, name)

    def test_all_workflows_also_gates_named_third_party_checks(self) -> None:
        workflows = census(workflow_run(101, matrix_jobs(2)))
        self.write_scenario(
            pull=pull("head-1", [check("Vercel", "IN_PROGRESS", None)]),
            census=[workflows],
        )
        _, output = self.census_wait("--check", "Vercel", deadline=self.short_deadline())
        self.assertEqual(output["state"], "timed-out")
        self.reset_census()
        self.write_scenario(
            pull=pull("head-1", [check("Vercel", "COMPLETED", "SUCCESS")]),
            census=[workflows],
        )
        _, output = self.census_wait("--check", "Vercel")
        self.assertEqual(output["state"], "satisfied")
        self.assertEqual(output["observation"]["checks"][0]["name"], "Vercel")

    def test_all_workflows_reports_a_failed_named_check_at_once_and_once(self) -> None:
        self.write_scenario(
            pull=pull("head-1", [
                check("Preview", "IN_PROGRESS", None),
                check("Review", "COMPLETED", "FAILURE", "2026-08-12T08:00:00Z"),
                check("Review", "COMPLETED", "FAILURE", "2026-08-12T08:00:02Z"),
            ]),
            census=[census(workflow_run(101, matrix_jobs(2)))],
        )
        _, output = self.census_wait("--check", "Preview", "--check", "Review")
        self.assertEqual(output["state"], "changed")
        self.assertEqual(output["metrics"]["observations"], 1)
        self.assertEqual(output["reason"].count("check Review: failure"), 1)
        self.assertNotIn("Preview", output["reason"])


if __name__ == "__main__":
    unittest.main()
