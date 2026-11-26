#!/usr/bin/env python3
"""Wait for a meaningful GitHub delivery transition without model polling."""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import quote

sys.dont_write_bytecode = True  # Keep installed skill trees free of __pycache__.

# Isolated mode (python3 -I) leaves the script's directory off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from kgr_github import (  # noqa: E402
    CORE_RESERVE,
    ExpectedHead,
    Gh,
    Metrics,
    RateLimited,
    StateLock,
    TransientError,
    WaitError,
    classify_head,
    default_state_path,
    emit,
    load_state,
    parse_time,
    positive_interval,
    result_envelope,
    stable_digest,
    wait_for_transition,
    write_state,
)


ROLLUP_PAGE = """statusCheckRollup{contexts(first:100%s){nodes{
        __typename ... on CheckRun{id name status conclusion detailsUrl startedAt completedAt databaseId
          checkSuite{databaseId app{slug} workflowRun{event workflow{databaseId}}}}
        ... on StatusContext{id context state targetUrl createdAt}
      } totalCount pageInfo{hasNextPage endCursor}}}"""
ROLLUP = ROLLUP_PAGE % ""


PR_QUERY = """
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      headRefOid state merged mergedAt mergeCommit{oid}
      commits(last:1){nodes{commit{%s}}}
    }
  }
}
""" % ROLLUP


COMMIT_QUERY = """
query($owner:String!,$name:String!,$oid:GitObjectID!){
  repository(owner:$owner,name:$name){object(oid:$oid){__typename ... on Commit{oid %s}}}
}
""" % ROLLUP


# Every page of a commit's rollup, read when its first page is not the last.
COMMIT_ROLLUP_QUERY = """
query($owner:String!,$name:String!,$oid:GitObjectID!,$after:String){
  repository(owner:$owner,name:$name){object(oid:$oid){__typename ... on Commit{oid %s}}}
}
""" % (ROLLUP_PAGE % ",after:$after")
ROLLUP_PAGE_LIMIT = 50


COMMIT_HEAD_QUERY = """
query($owner:String!,$name:String!,$oid:GitObjectID!){
  repository(owner:$owner,name:$name){object(oid:$oid){__typename ... on Commit{oid}}}
}
"""


# Events whose workflow runs GitHub records on the default branch's latest
# commit, whatever started them: a repository dispatch from a deployment of
# another commit, a workflow_run chained to another branch's run, a schedule,
# or activity on an issue or a comment. A run of one says nothing about the
# commit it is recorded on. pull_request_target, though documented with the
# default branch's commit, is recorded on the pull request's head, so it counts.
UNBOUND_EVENTS = {
    "branch_protection_rule", "check_run", "check_suite", "delete", "discussion",
    "discussion_comment", "fork", "gollum", "image_version", "issue_comment", "issues",
    "label", "milestone", "page_build", "public", "repository_dispatch", "schedule",
    "status", "watch", "workflow_run",
}
FULL_SHA = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


TAG_QUERY = """
query($owner:String!,$name:String!,$qualified:String!,$tag:String!){
  repository(owner:$owner,name:$name){
    ref(qualifiedName:$qualified){target{oid ... on Tag{target{oid}}}}
    release(tagName:$tag){isDraft isPrerelease url releaseAssets(first:100){nodes{name} pageInfo{hasNextPage}}}
  }
}
"""


TERMINAL_CHECK_CONCLUSIONS = {
    "SUCCESS",
    "FAILURE",
    "ERROR",
    "CANCELLED",
    "SKIPPED",
    "NEUTRAL",
    "TIMED_OUT",
    "ACTION_REQUIRED",
    "STARTUP_FAILURE",
    "STALE",
}
PASSING_CHECK_CONCLUSIONS = {"SUCCESS", "NEUTRAL", "SKIPPED"}


def repo_parts(repo: str) -> tuple[str, str]:
    pieces = repo.split("/", 1)
    if len(pieces) != 2 or not all(pieces):
        raise WaitError("--repo must be OWNER/REPO")
    return pieces[0], pieces[1]


def pr_snapshot(
    gh: Gh, repo: str, number: int, rest_page_size: int = 100, expected: ExpectedHead | None = None,
    listing: dict[str, Any] | None = None, names: frozenset[str] | set[str] = frozenset(),
) -> dict[str, Any]:
    """The pull request's head, state and checks.

    With EXPECTED, the head is recorded as soon as GitHub reports it, and the
    checks of any other head are neither read nor judged.
    """
    def other_head(head: Any, state: Any, merged: bool, merged_at: Any, merge_commit: Any) -> dict[str, Any] | None:
        if expected is None:
            return None
        expected.note(head)
        if head == expected.expected:
            return None
        return {"head": head, "state": state, "merged": merged, "mergedAt": merged_at, "mergeCommit": merge_commit, "checks": []}

    owner, name = repo_parts(repo)
    try:
        data = gh.graphql(PR_QUERY, {"owner": owner, "name": name, "number": number})
        pull = data.get("repository", {}).get("pullRequest")
        if not isinstance(pull, dict):
            raise WaitError(f"pull request {repo}#{number} was not found")
        early = other_head(
            pull.get("headRefOid"), pull.get("state"), bool(pull.get("merged")),
            pull.get("mergedAt"), (pull.get("mergeCommit") or {}).get("oid"),
        )
        if early:
            return early
        checks = rollup_checks(
            gh, repo, pull.get("headRefOid"),
            pull.get("commits", {}).get("nodes", [{}])[0].get("commit", {}).get("statusCheckRollup"),
        )
        checks = attribute_actions_checks(gh, repo, pull.get("headRefOid"), checks, names, rest_page_size, listing)
        return {"head": pull.get("headRefOid"), "state": pull.get("state"), "merged": bool(pull.get("merged")), "mergedAt": pull.get("mergedAt"), "mergeCommit": (pull.get("mergeCommit") or {}).get("oid"), "checks": checks}
    except RateLimited:
        gh.metrics.rate_limit_fallbacks += 1
        pull = gh.rest(f"repos/{repo}/pulls/{number}")
        merged = bool(pull.get("merged"))
        early = other_head(
            (pull.get("head") or {}).get("sha"),
            "MERGED" if merged else str(pull.get("state") or "").upper() or None,
            merged, pull.get("merged_at"), pull.get("merge_commit_sha") if merged else None,
        )
        if early:
            return early
        checks = rest_checks(gh, repo, pull["head"]["sha"], rest_page_size, listing)
        # REST reports a merged pull request as closed and gives an unmerged one
        # its test merge commit; GraphQL reports MERGED and no merge commit.
        merged = bool(pull.get("merged"))
        state = "MERGED" if merged else str(pull.get("state") or "").upper() or None
        return {"head": pull["head"]["sha"], "state": state, "merged": merged, "mergedAt": pull.get("merged_at"), "mergeCommit": pull.get("merge_commit_sha") if merged else None, "checks": checks}


def rollup_checks(gh: Gh, repo: str, oid: Any, rollup: Any) -> list[dict[str, Any]]:
    """The checks and statuses of a commit's GraphQL status check rollup, sorted by name.

    ROLLUP is the first page. When more follow, every page is read again from
    the commit, so all of them come from one connection. A check run of a
    workflow run in UNBOUND_EVENTS is left out: it says nothing about the commit.
    """
    contexts = (rollup or {}).get("contexts") or {}
    nodes = list(contexts.get("nodes") or [])
    paged = bool(contexts.get("pageInfo", {}).get("hasNextPage"))
    if not paged and type(contexts.get("totalCount")) is int \
            and len(nodes) != contexts["totalCount"]:
        raise TransientError(f"commit {oid}'s check rollup listed {len(nodes)} of {contexts['totalCount']} contexts")
    if contexts.get("pageInfo", {}).get("hasNextPage"):
        if not isinstance(oid, str) or not oid:
            raise WaitError("a check rollup with more than 100 contexts has no commit to read it from")
        owner, name = repo_parts(repo)
        nodes, after, cursors, total = [], None, set(), None
        for _ in range(ROLLUP_PAGE_LIMIT):
            data = gh.graphql(COMMIT_ROLLUP_QUERY, {"owner": owner, "name": name, "oid": oid, "after": after})
            commit = (data.get("repository") or {}).get("object")
            page = ((commit or {}).get("statusCheckRollup") or {}).get("contexts")
            # A page that is missing or changes its count is a read to retry, never the end of the list.
            if (not isinstance(commit, dict) or commit.get("__typename") != "Commit" or commit.get("oid") != oid
                    or not isinstance(page, dict) or not isinstance(page.get("nodes"), list)
                    or type(page.get("totalCount")) is not int):
                raise TransientError(f"commit {oid}'s check rollup page after {after!r} is incomplete")
            if total is not None and page["totalCount"] != total:
                raise TransientError(f"commit {oid}'s check rollup count changed while it was read")
            total = page["totalCount"]
            nodes += page["nodes"]
            info = page.get("pageInfo") or {}
            if not info.get("hasNextPage"):
                break
            after = info.get("endCursor")
            if not after or after in cursors:
                raise TransientError(f"commit {oid}'s check rollup has another page but no new cursor")
            cursors.add(after)
        else:
            raise WaitError(f"commit {oid} has more than {ROLLUP_PAGE_LIMIT * 100} check contexts")
        if len(nodes) != total:
            raise TransientError(f"commit {oid}'s check rollup listed {len(nodes)} of {total} contexts")
    # Pages that overlap could make up the total while hiding a context, so
    # across pages every context must carry its own global id.
    if paged:
        ids = [node.get("id") for node in nodes]
        if not all(isinstance(node_id, str) and node_id for node_id in ids) or len(set(ids)) != len(ids):
            raise TransientError(f"commit {oid}'s check rollup lists a context twice or without an id")
    checks = []
    for node in nodes:
        if node.get("__typename") == "CheckRun":
            suite = node.get("checkSuite") or {}
            workflow_run = suite.get("workflowRun") or {}
            if workflow_run.get("event") in UNBOUND_EVENTS:
                continue
            source = check_source(
                (suite.get("app") or {}).get("slug"),
                (workflow_run.get("workflow") or {}).get("databaseId"),
                workflow_run.get("event"),
            )
            checks.append({"name": node.get("name"), "status": node.get("status"), "conclusion": node.get("conclusion"), "completedAt": node.get("completedAt"), "observedAt": node.get("startedAt") or node.get("completedAt"), "suite": suite.get("databaseId"), "source": source, "event": workflow_run.get("event")})
        else:
            checks.append({"name": node.get("context"), "status": "COMPLETED", "conclusion": node.get("state"), "observedAt": node.get("createdAt"), "source": "status"})
    return sorted(checks, key=lambda item: str(item["name"]))


def head_runs(gh: Gh, repo: str, sha: str, rest_page_size: int, listing: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Every workflow run for the exact commit, read once per observation when LISTING is shared."""
    if listing is not None and sha in listing:
        return listing[sha]
    runs = rest_census(
        gh.rest_pages(f"repos/{repo}/actions/runs?head_sha={quote(sha, safe='')}&per_page={rest_page_size}"),
        "workflow_runs",
        "workflow run",
    )
    if listing is not None:
        listing[sha] = runs
    return runs


def attribute_actions_checks(
    gh: Gh, repo: str, sha: Any, checks: list[dict[str, Any]], names: frozenset[str] | set[str],
    rest_page_size: int, listing: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    """Give a named GitHub Actions check GraphQL did not tie to its workflow run that run's workflow and event.

    The commit's run listing names each suite's run, so an unbound run's check
    is left out here too. Only checks in NAMES decide, so only they are looked
    up: another app's or workflow's check never holds a wait.
    """
    unknown = [
        check for check in checks
        if check.get("name") in names and check.get("source") == "github-actions" and check.get("suite") is not None
    ]
    if not unknown or not isinstance(sha, str):
        return checks
    workflows = {run.get("check_suite_id"): run for run in head_runs(gh, repo, sha, rest_page_size, listing)}
    kept = []
    for check in checks:
        if check in unknown:
            run = workflows.get(check["suite"])
            if run is None:
                raise TransientError(f"no workflow run is listed yet for check suite {check['suite']}")
            if run.get("event") in UNBOUND_EVENTS:
                continue
            check = {**check, "source": check_source("github-actions", run.get("workflow_id"), run.get("event")), "event": run.get("event")}
        kept.append(check)
    return kept


def rest_checks(gh: Gh, repo: str, sha: str, rest_page_size: int, listing: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """The checks and statuses of a commit through REST, as rollup_checks reads them, unbound runs' checks left out."""
    runs = rest_census(
        gh.rest_pages(f"repos/{repo}/commits/{sha}/check-runs?per_page={rest_page_size}"), "check_runs", "check run",
    )
    status_pages = gh.rest_pages(f"repos/{repo}/commits/{sha}/statuses?per_page={rest_page_size}")
    # A check run names only its suite; the workflow run of that suite
    # names the workflow and event, as GraphQL does in one query.
    workflows = {
        item.get("check_suite_id"): item for item in head_runs(gh, repo, sha, rest_page_size, listing)
    } if runs else {}
    for run in runs:
        suite = (run.get("check_suite") or {}).get("id")
        if (run.get("app") or {}).get("slug") == "github-actions" and suite not in workflows:
            raise TransientError(f"no workflow run is listed yet for check suite {suite}")
    # The statuses endpoint lists every state a context has had, newest
    # first; the GraphQL rollup has only the current one.
    statuses: dict[str, dict[str, Any]] = {}
    for page in status_pages:
        for item in page:
            statuses.setdefault(item.get("context"), item)
    checks = [
        {"name": run.get("name"), "status": str(run.get("status", "")).upper(), "conclusion": str(run.get("conclusion") or "").upper(), "completedAt": run.get("completed_at"), "observedAt": run.get("started_at") or run.get("completed_at"), "suite": (run.get("check_suite") or {}).get("id"), "source": check_source(
            (run.get("app") or {}).get("slug"),
            workflows.get((run.get("check_suite") or {}).get("id"), {}).get("workflow_id"),
            workflows.get((run.get("check_suite") or {}).get("id"), {}).get("event"),
        ), "event": workflows.get((run.get("check_suite") or {}).get("id"), {}).get("event")}
        for run in runs
        if workflows.get((run.get("check_suite") or {}).get("id"), {}).get("event") not in UNBOUND_EVENTS
    ] + [
        {"name": item.get("context"), "status": "COMPLETED", "conclusion": str(item.get("state", "")).upper(), "observedAt": item.get("created_at"), "source": "status"}
        for item in statuses.values()
    ]
    return sorted(checks, key=lambda item: str(item["name"]))


def commit_snapshot(
    gh: Gh, repo: str, sha: str, checks: bool, rest_page_size: int = 100, listing: dict[str, Any] | None = None,
    names: frozenset[str] | set[str] = frozenset(),
) -> dict[str, Any]:
    """A commit with no pull request, such as a merge commit on the default branch: its head and, with CHECKS, its checks."""
    owner, name = repo_parts(repo)
    try:
        data = gh.graphql(COMMIT_QUERY if checks else COMMIT_HEAD_QUERY, {"owner": owner, "name": name, "oid": sha})
        commit = (data.get("repository") or {}).get("object")
        if not isinstance(commit, dict) or commit.get("__typename") != "Commit":
            raise WaitError(f"commit {sha} was not found in {repo}")
        observation: dict[str, Any] = {"head": commit.get("oid")}
        if checks:
            observation["checks"] = attribute_actions_checks(
                gh, repo, commit.get("oid"),
                rollup_checks(gh, repo, commit.get("oid"), commit.get("statusCheckRollup")), names, rest_page_size, listing,
            )
        return observation
    except RateLimited:
        gh.metrics.rate_limit_fallbacks += 1
        try:
            commit = gh.rest(f"repos/{repo}/commits/{sha}")
        except WaitError as error:
            if not isinstance(error, (RateLimited, TransientError)) and (
                "404" in str(error) or "422" in str(error) or "not found" in str(error).lower()
            ):
                raise WaitError(f"commit {sha} was not found in {repo}") from error
            raise
        observation = {"head": commit.get("sha")}
        if checks:
            observation["checks"] = rest_checks(gh, repo, sha, rest_page_size, listing)
        return observation


def check_is_terminal(check: dict[str, Any]) -> bool:
    return (
        str(check.get("conclusion", "")).upper() in TERMINAL_CHECK_CONCLUSIONS
        and (
            str(check.get("status", "")).upper() == "COMPLETED"
            or check.get("completedAt") is not None
        )
    )


def check_source(app: Any, workflow: Any, event: Any) -> str:
    """What produced a check run: its app and, for Actions, workflow and event.

    GraphQL gives no app for one the token cannot see, so such apps share a source.
    """
    return "/".join(str(part) for part in (app, workflow, event) if part is not None)


def checks_by_name(observation: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    """The current contexts of each check name from each source.

    A source's newer check suite replaces its older one: a re-run, a run
    cancelled by a newer one, or a re-check after a pull request edit. GitHub
    numbers suites in creation order, while a job's start time can come after
    a newer run's. Sources differ by app, workflow and event, so one workflow
    triggered by both push and pull_request has two current runs. A commit
    status has no suite and counts by its latest state.
    """
    def order(check: dict[str, Any]) -> tuple[int, str]:
        suite = check.get("suite")
        return (suite, "") if suite else (0, str(check.get("observedAt") or ""))

    current: dict[tuple[str, Any], list[dict[str, Any]]] = {}
    for check in observation.get("checks", []):
        key = (str(check.get("name")), check.get("source"))
        kept = current.get(key)
        if not kept or order(check) > order(kept[0]):
            current[key] = [check]
        elif order(check) == order(kept[0]):
            kept.append(check)
    observed: dict[str, list[dict[str, Any]]] = {}
    for (name, _source), checks in current.items():
        observed.setdefault(name, []).extend(checks)
    return observed


def check_failed(check: dict[str, Any]) -> bool:
    return check_is_terminal(check) and str(check.get("conclusion", "")).upper() not in PASSING_CHECK_CONCLUSIONS


def failed_checks(expected: set[str], observed: dict[str, list[dict[str, Any]]]) -> list[str]:
    """Expected check names with at least one context that ended without passing."""
    return sorted(
        name for name in expected & set(observed)
        if any(check_failed(check) for check in observed[name])
    )


def classify_pr(
    kind: str,
    expected_head: str,
    expected_checks: set[str],
    observation: dict[str, Any],
) -> tuple[str, str]:
    head = classify_head(expected_head, observation)
    if head:
        return head
    if kind == "pr-merged":
        if observation.get("merged"):
            return "satisfied", "pull request merged"
        if observation.get("state") == "CLOSED":
            return "changed", "pull request was closed without merging"
        return "waiting", "pull request remains open"
    observed = checks_by_name(observation)
    failed = failed_checks(expected_checks, observed)
    if failed:
        # One failed check decides the result; the others need not finish.
        return "changed", f"a check reached a non-success terminal result: {', '.join(failed)}"
    missing = expected_checks - set(observed)
    if missing:
        return "waiting", f"expected checks have not appeared: {', '.join(sorted(missing))}"
    if not expected_checks or not all(
        check_is_terminal(check) for name in expected_checks for check in observed[name]
    ):
        return "waiting", "checks are not terminal"
    return "satisfied", "all expected checks are terminal-success"


HEAD_QUERY = """
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid}}
}
"""


# GitHub Actions run and job conclusions that pass, matching
# PASSING_CHECK_CONCLUSIONS. Every other terminal conclusion is a failure.
PASSING_WORKFLOW_CONCLUSIONS = {"success", "neutral", "skipped"}


def pr_head(gh: Gh, repo: str, number: int) -> Any:
    owner, name = repo_parts(repo)
    try:
        data = gh.graphql(HEAD_QUERY, {"owner": owner, "name": name, "number": number})
        pull = (data.get("repository") or {}).get("pullRequest")
        if not isinstance(pull, dict):
            raise WaitError(f"pull request {repo}#{number} was not found")
        return pull.get("headRefOid")
    except RateLimited:
        gh.metrics.rate_limit_fallbacks += 1
        return (gh.rest(f"repos/{repo}/pulls/{number}").get("head") or {}).get("sha")


def rest_census(pages: list[Any], field: str, label: str) -> list[dict[str, Any]]:
    """Join REST pages; never convert partial or racing data to absence."""
    items: list[dict[str, Any]] = []
    ids: set[int] = set()
    total = None
    for page in pages:
        if not isinstance(page, dict) or type(page.get("total_count")) is not int:
            raise WaitError(f"missing {label} total count")
        if not isinstance(page.get(field), list):
            raise WaitError(f"missing {label} list")
        if total is None:
            total = page["total_count"]
        elif page["total_count"] != total:
            raise TransientError(f"{label} count changed during pagination")
        for item in page[field]:
            if not isinstance(item, dict) or type(item.get("id")) is not int:
                raise WaitError(f"missing {label} identity")
            if item["id"] in ids:
                raise TransientError(f"duplicate {label} across pages")
            ids.add(item["id"])
            items.append(item)
    if total is None:
        raise WaitError(f"missing {label} pages")
    if len(items) != total:
        raise TransientError(f"incomplete {label} census: {len(items)} of {total}")
    return sorted(items, key=lambda item: item["id"])


def workflow_census(
    gh: Gh, repo: str, number: int | None, head: str, checks: bool, rest_page_size: int = 100,
    expected: ExpectedHead | None = None, names: frozenset[str] | set[str] = frozenset(),
) -> dict[str, Any]:
    """Every GitHub Actions run for the exact head, with its jobs.

    The head is the pull request's, or with no NUMBER the commit HEAD itself.
    A run of an event in UNBOUND_EVENTS is listed under `unboundRuns`
    without its jobs and decides nothing.
    """
    listing: dict[str, Any] = {}  # One run listing serves check attribution and the census.
    if number is None:
        snapshot = commit_snapshot(gh, repo, head, checks, rest_page_size, listing, names)
    else:
        snapshot = pr_snapshot(gh, repo, number, rest_page_size, expected, listing, names) if checks else {"head": pr_head(gh, repo, number)}
    observed = snapshot.get("head")
    if not isinstance(observed, str) or not observed:
        raise WaitError(f"pull request {repo}#{number} has no verified head" if number is not None else f"commit {head} has no verified head")
    if expected:
        expected.note(observed)
    observation: dict[str, Any] = {"head": observed}
    if checks:
        observation["checks"] = snapshot["checks"]
    if observed != head:
        return observation
    runs = head_runs(gh, repo, head, rest_page_size, listing)
    observation["runs"] = []
    observation["unboundRuns"] = []
    for run in runs:
        if run.get("head_sha") != head:
            raise WaitError(f"workflow run {run['id']} is for head {run.get('head_sha')}, not {head}")
        if run.get("event") in UNBOUND_EVENTS:
            observation["unboundRuns"].append({
                "id": run["id"],
                "name": run.get("name"),
                "event": run.get("event"),
                "checkSuiteId": run.get("check_suite_id"),
                "status": run.get("status"),
                "conclusion": run.get("conclusion"),
                "url": run.get("html_url"),
            })
            continue
        jobs = rest_census(
            gh.rest_pages(f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page={rest_page_size}"),
            "jobs",
            f"workflow run {run['id']} job",
        )
        for job in jobs:
            if job.get("run_id") != run["id"]:
                raise WaitError(f"job {job['id']} belongs to run {job.get('run_id')}, not {run['id']}")
        observation["runs"].append({
            "id": run["id"],
            "name": run.get("name"),
            "workflowId": run.get("workflow_id"),
            "event": run.get("event"),
            "checkSuiteId": run.get("check_suite_id"),
            "headBranch": run.get("head_branch"),
            "headRepositoryId": (run.get("head_repository") or {}).get("id"),
            "pullRequests": sorted(
                pull.get("number") for pull in run.get("pull_requests") or []
                if isinstance(pull, dict) and pull.get("number") is not None
            ),
            "runStartedAt": run.get("run_started_at"),
            "updatedAt": run.get("updated_at"),
            "attempt": run.get("run_attempt"),
            "status": run.get("status"),
            "conclusion": run.get("conclusion"),
            "url": run.get("html_url"),
            "jobs": [
                {
                    "id": job["id"],
                    "name": job.get("name"),
                    "status": job.get("status"),
                    "conclusion": job.get("conclusion"),
                    "completedAt": job.get("completed_at"),
                }
                for job in jobs
            ],
        })
    # A check run GraphQL could not tie to its workflow run still belongs to
    # that run's suite, which the census names.
    drop_unbound_checks(observation)
    mark_superseded_runs(observation["runs"])
    mark_cancelled_duplicates(observation["runs"], repo, number)
    return observation


def check_event(check: dict[str, Any]) -> Any:
    """The workflow event of a GitHub Actions check run, or None for a status or another app's check.

    A check saved before checks named their event names it only as the third
    part of an Actions source, `app/workflow/event`.
    """
    if "event" in check:
        return check["event"]
    parts = str(check.get("source") or "").split("/")
    return parts[2] if len(parts) == 3 and parts[0] == "github-actions" else None


def drop_unbound_checks(observation: dict[str, Any]) -> None:
    """Leave out the check runs of the unbound runs' suites, and those of an unbound workflow event."""
    suites = {run.get("checkSuiteId") for run in observation.get("unboundRuns", []) if run.get("checkSuiteId") is not None}
    if "checks" in observation:
        observation["checks"] = [
            check for check in observation["checks"]
            if (check.get("suite") is None or check.get("suite") not in suites) and check_event(check) not in UNBOUND_EVENTS
        ]


def rekey_unbound_checkpoint(
    path: Path | None, identity: dict[str, Any], transition_key: Any, suite_events: Any = None,
) -> None:
    """Re-read a checks-terminal checkpoint saved before unbound runs were set aside, so upgrading is not a change.

    Such a checkpoint counts unbound runs, in a census, and their check runs
    as deciding. The runs move to `unboundRuns`, their checks are dropped, and
    the digest is taken again from the same observation; the saved head and
    GitHub limits stay as they are. A saved Actions check GraphQL did not tie
    to its workflow run takes its event from SUITE_EVENTS, the head's current
    run listing by suite, read only when such a check is there. A checkpoint
    that has nothing unbound is left alone.
    """
    prior = load_state(path)
    observation = (prior or {}).get("observation")
    if (not observation or prior.get("kind") != "checks-terminal" or prior.get("identity") != identity
            or prior.get("digest") is None):
        return
    normalized = dict(observation)
    if "runs" in normalized and "unboundRuns" not in normalized:
        runs = normalized["runs"]
        unbound = [run for run in runs if run.get("event") in UNBOUND_EVENTS]
        normalized["runs"] = [run for run in runs if run not in unbound]
        normalized["unboundRuns"] = [
            {"id": run.get("id"), "name": run.get("name"), "event": run.get("event"), "checkSuiteId": run.get("checkSuiteId"),
             "status": run.get("status"), "conclusion": run.get("conclusion"), "url": run.get("url")}
            for run in unbound
        ]
    untied = [
        check for check in normalized.get("checks") or []
        if check.get("source") == "github-actions" and check.get("suite") is not None and check_event(check) is None
    ]
    if untied and suite_events is not None:
        try:
            events = suite_events()
        except WaitError:
            events = {}  # Unresolved, the check stays as it was saved.
        normalized["checks"] = [
            {**check, "event": events[check["suite"]]} if check in untied and check["suite"] in events else check
            for check in normalized["checks"]
        ]
    drop_unbound_checks(normalized)
    if normalized.get("runs") == observation.get("runs") and normalized.get("checks") == observation.get("checks"):
        return
    key = transition_key(normalized)
    if key is not None:
        write_state(path, {**prior, "observation": normalized, "digest": stable_digest(key)})


def mark_superseded_runs(runs: list[dict[str, Any]]) -> None:
    """Flag every run that a newer run of the same workflow and event replaced.

    A workflow that cancels its run when a second event arrives for the same
    head, or that is triggered again by hand, leaves the older run on the head.
    Only the newest run from one source decides, as for a named check and as
    GitHub decides mergeability: it numbers runs and check suites in creation
    order, whichever run was cancelled. A run whose workflow is unknown is its
    own source.
    """
    newest: dict[tuple[Any, Any], int] = {}
    for run in runs:
        if run.get("workflowId") is not None:
            source = (run["workflowId"], run.get("event"))
            newest[source] = max(newest.get(source, run["id"]), run["id"])
    for run in runs:
        source = (run.get("workflowId"), run.get("event"))
        if run.get("workflowId") is not None and newest[source] != run["id"]:
            run["superseded"] = True


def mark_cancelled_duplicates(runs: list[dict[str, Any]], repo: str, number: int | None) -> None:
    """Flag a newest run that was cancelled beside an older run of its source.

    One event can start two runs of a workflow for the same head, for example
    when a pull request and its native stack registration race. A
    `concurrency` group with `cancel-in-progress` then cancels whichever run
    joined it first, which can be the newer one. GitHub still counts the newest
    check suite, so its cancelled jobs block merging although the older run
    passed. Rerunning the cancelled run replaces its result.

    `olderRun` is `passed` once an older run of the source passed, with the
    command that reruns the cancelled one, and `pending` while an older run
    has not finished and none has passed. A cancelled newest run beside only
    failed older runs is an ordinary failure and is not flagged, and so is one
    cancelled again after a rerun: the race happens only when runs start, so
    another cancellation, such as a job timeout, needs its own diagnosis.

    Only a race counts: both runs come from the same branch, the older run had
    started before the newer one was cancelled and was still running then, and
    no job of the cancelled run failed in any other way. A run cancelled after
    the older one finished, or with a failed job, needs its own diagnosis.
    Where GitHub names the pull requests a run belongs to, both runs belong
    to this one: a branch can have pull requests against two bases. In a
    commit's census, with no NUMBER, two runs that both name pull requests
    must share one.
    """
    sources: dict[tuple[Any, Any], list[dict[str, Any]]] = {}
    for run in runs:
        if run.get("workflowId") is not None:
            sources.setdefault((run["workflowId"], run.get("event")), []).append(run)
    for source in sources.values():
        newest = max(source, key=lambda run: run["id"])
        if newest.get("status") != "completed" or newest.get("conclusion") != "cancelled":
            continue
        if (newest.get("attempt") or 1) > 1:
            continue
        if number is not None and newest.get("pullRequests") and number not in newest["pullRequests"]:
            continue
        if any(
            job.get("conclusion") not in PASSING_WORKFLOW_CONCLUSIONS | {"cancelled", None}
            for job in newest.get("jobs", [])
        ):
            continue
        older = [
            run for run in source
            if run is not newest and raced(run, newest)
            and (not run.get("pullRequests") or (
                number in run["pullRequests"] if number is not None
                # Without a pull request of its own, a commit's runs that both
                # name pull requests must share one: each can target another base.
                else not newest.get("pullRequests") or bool(set(run["pullRequests"]) & set(newest["pullRequests"]))
            ))
        ]
        # A job that may fail without failing its run, such as one with
        # continue-on-error, still has to pass.
        passed = [
            run["id"] for run in older
            if run.get("status") == "completed" and run.get("conclusion") in PASSING_WORKFLOW_CONCLUSIONS
            and all(job.get("conclusion") in PASSING_WORKFLOW_CONCLUSIONS for job in run.get("jobs", []))
        ]
        pending = [
            run["id"] for run in older
            if run.get("status") != "completed" or not run.get("conclusion")
        ]
        if passed:
            newest["cancelledDuplicate"] = {
                "olderRunId": max(passed),
                "olderRun": "passed",
                "rerun": f"gh run rerun {newest['id']} --repo {repo}",
            }
        elif pending:
            newest["cancelledDuplicate"] = {"olderRunId": max(pending), "olderRun": "pending"}


def raced(older: dict[str, Any], cancelled: dict[str, Any]) -> bool:
    """Whether the older run was running from the same branch when the newer one was cancelled.

    The branch counts with its repository, since forks can share a branch
    name. A rerun older run's start and latest update can span attempts, so
    its overlap cannot be shown and it does not count; neither does a run
    whose branch or times are missing.
    """
    if (
        older.get("headBranch") is None
        or older.get("headRepositoryId") is None
        or (older.get("headBranch"), older.get("headRepositoryId"))
        != (cancelled.get("headBranch"), cancelled.get("headRepositoryId"))
        or (older.get("attempt") or 1) > 1
    ):
        return False
    try:
        cancelled_at = parse_time(str(cancelled.get("updatedAt")))
        started = parse_time(str(older.get("runStartedAt")))
        finished = parse_time(str(older.get("updatedAt"))) if older.get("status") == "completed" else None
    except WaitError:
        return False
    return started <= cancelled_at and (finished is None or cancelled_at <= finished)


def cancelled_duplicates(observation: dict[str, Any], older_run: str) -> list[dict[str, Any]]:
    return [
        run for run in deciding_runs(observation)
        if (run.get("cancelledDuplicate") or {}).get("olderRun") == older_run
    ]


def census_digest(observation: dict[str, Any], checks: set[str]) -> str:
    """The digest two observations must share to confirm a stable census.

    It covers the runs and the named CHECKS. Unbound runs are left out: they
    keep arriving on a default-branch commit, for example one repository
    dispatch for each preview deployment, and decide nothing about it. So are
    checks nobody named, which decide nothing either.
    """
    kept = {key: value for key, value in observation.items() if key != "unboundRuns"}
    if "checks" in kept:
        kept["checks"] = [check for check in kept["checks"] if check.get("name") in checks]
    return stable_digest(kept)


def deciding_runs(observation: dict[str, Any]) -> list[dict[str, Any]]:
    return [run for run in observation.get("runs", []) if not run.get("superseded")]


def possible_duplicates(observation: dict[str, Any]) -> set[int]:
    """Runs still finishing that may yet be marked as cancelled duplicates.

    A cancelled run's jobs show `cancelled` seconds before the run completes;
    its own conclusion decides, so their cancellation waits for it.
    """
    runs = observation.get("runs", [])
    return {
        run["id"] for run in runs
        if run.get("status") != "completed" and (run.get("attempt") or 1) == 1
        and run.get("workflowId") is not None
        and any(
            other["id"] < run["id"]
            and (other.get("workflowId"), other.get("event"), other.get("headBranch"), other.get("headRepositoryId"))
            == (run.get("workflowId"), run.get("event"), run.get("headBranch"), run.get("headRepositoryId"))
            for other in runs
        )
    }


def workflow_failures(observation: dict[str, Any]) -> list[str]:
    failures = []
    finishing = possible_duplicates(observation)
    for run in deciding_runs(observation):
        if run.get("cancelledDuplicate"):
            # Decided by the older run of its source; see mark_cancelled_duplicates.
            continue
        conclusion = run.get("conclusion")
        if run.get("status") == "completed" and conclusion and conclusion not in PASSING_WORKFLOW_CONCLUSIONS:
            failures.append(f"{run.get('name')}: {conclusion}")
        for job in run.get("jobs", []):
            conclusion = job.get("conclusion")
            terminal = job.get("status") == "completed" or job.get("completedAt") is not None
            if run["id"] in finishing and conclusion == "cancelled":
                continue
            if terminal and conclusion and conclusion not in PASSING_WORKFLOW_CONCLUSIONS:
                failures.append(f"{run.get('name')} / {job.get('name')}: {conclusion}")
    return sorted(failures)


class WorkflowCensusGate:
    """Classify a workflow census; success needs two identical observations.

    A job added by a later matrix or `needs` stage keeps its run in progress,
    and a run triggered after another run finishes appears only later, so one
    all-success snapshot cannot establish the complete census.
    """

    def __init__(self, head: str, checks: set[str], confirm: bool) -> None:
        self.head = head
        self.checks = checks
        self.confirm = confirm
        self.previous: str | None = None

    def failures(self, observation: dict[str, Any]) -> list[str]:
        failures = workflow_failures(observation)
        # A cancelled named check from a cancelled duplicate run goes with
        # that run; any other conclusion still counts. A cancelled one from a
        # rerun that has not finished, or that passed on a
        # later attempt, is left from an earlier attempt: the check rollup is
        # read before the runs and can lag behind a rerun. The run's jobs
        # decide, and a stable census needs a second observation.
        duplicate_suites = {
            run.get("checkSuiteId") for run in deciding_runs(observation)
            if run.get("cancelledDuplicate") and run.get("checkSuiteId") is not None
        }
        # A rerun still going may not have created its check runs yet; a
        # passed one replaced only the checks its jobs name.
        reruns = {
            run.get("checkSuiteId"): run for run in deciding_runs(observation)
            if run.get("checkSuiteId") is not None and (run.get("attempt") or 1) > 1 and (
                run.get("status") != "completed"
                or run.get("conclusion") in PASSING_WORKFLOW_CONCLUSIONS
            )
        }

        # A possible duplicate still finishing decides once its run completes.
        finishing_suites = {
            run.get("checkSuiteId") for run in deciding_runs(observation)
            if run["id"] in possible_duplicates(observation) and run.get("checkSuiteId") is not None
        }

        def stale(name: str, check: dict[str, Any]) -> bool:
            if str(check.get("conclusion", "")).upper() != "CANCELLED":
                return False
            if check.get("suite") in duplicate_suites | finishing_suites:
                return True
            rerun = reruns.get(check.get("suite"))
            return rerun is not None and (
                rerun.get("status") != "completed"
                or name in {job.get("name") for job in rerun.get("jobs", [])}
            )

        observed = {
            name: [check for check in checks if not stale(name, check)]
            for name, checks in checks_by_name(observation).items()
        }
        failures += [
            f"check {name}: " + ", ".join(sorted({
                str(check.get("conclusion")).lower() for check in observed[name] if check_failed(check)
            }))
            for name in failed_checks(self.checks, observed)
        ]
        return failures

    def __call__(self, observation: dict[str, Any]) -> tuple[str, str]:
        head = classify_head(self.head, observation)
        if head:
            self.previous = None
            return head
        failures = self.failures(observation)
        if failures:
            self.previous = None
            return "changed", "a workflow run, job or check reached a non-success terminal result: " + "; ".join(failures)
        runs = deciding_runs(observation)
        # Superseded and unbound runs count too: a rerun could cancel any
        # active run that shares its concurrency group.
        others_running = [
            run for run in observation.get("runs", []) + observation.get("unboundRuns", [])
            if run.get("status") != "completed" or not run.get("conclusion")
        ]
        recoverable = cancelled_duplicates(observation, "passed")
        if recoverable and others_running:
            # A rerun can join a concurrency group another workflow shares and
            # cancel it, so it waits until every other run has finished.
            self.previous = None
            return "waiting", (
                f"{len(recoverable)} cancelled duplicate runs can be rerun once the other "
                f"{len(others_running)} workflow runs on the head have finished"
            )
        if recoverable:
            # Like success, a rerun needs a stable census: a run that starts
            # after this observation could share the rerun's group.
            reason = "; ".join(
                f"the newest run of {run.get('name')} ({run['id']}) was cancelled while an older run "
                f"of the same workflow and event ({run['cancelledDuplicate']['olderRunId']}) passed: "
                f"rerun it with {run['cancelledDuplicate']['rerun']}"
                for run in recoverable
            )
            if not self.confirm:
                self.previous = None
                return "waiting", f"{reason}, once wait confirms the census is stable"
            digest = census_digest(observation, self.checks)
            confirmed = digest == self.previous
            self.previous = digest
            if not confirmed:
                return "waiting", "a cancelled duplicate run can be rerun; confirming the census is stable"
            return "recoverable", reason
        runs = deciding_runs(observation)
        jobs = [job for run in runs for job in run.get("jobs", [])]
        pending_runs = [run for run in runs if run.get("status") != "completed" or not run.get("conclusion")]
        pending_jobs = [
            job for job in jobs
            if not job.get("conclusion") or (job.get("status") != "completed" and job.get("completedAt") is None)
        ]
        undecided = cancelled_duplicates(observation, "pending")
        reason = None
        if not runs:
            reason = "no workflow runs have appeared for the head"
        elif undecided:
            reason = "; ".join(
                f"the newest run of {run.get('name')} ({run['id']}) was cancelled; waiting for the older run "
                f"of the same workflow and event ({run['cancelledDuplicate']['olderRunId']}) to finish"
                for run in undecided
            )
        elif pending_runs or pending_jobs:
            reason = (
                f"{len(pending_runs)} of {len(runs)} workflow runs and "
                f"{len(pending_jobs)} of {len(jobs)} jobs are not terminal"
            )
        elif self.checks:
            state, check_reason = classify_pr("checks-terminal", self.head, self.checks, observation)
            if state != "satisfied":
                reason = check_reason
        if reason:
            self.previous = None
            return "waiting", reason
        summary = f"{len(runs)} workflow runs and {len(jobs)} jobs"
        if not self.confirm:
            return "waiting", f"all {summary} succeeded in this snapshot; only wait can confirm the census is stable"
        digest = census_digest(observation, self.checks)
        confirmed = digest == self.previous
        self.previous = digest
        if not confirmed:
            return "waiting", f"all {summary} succeeded; confirming the census is stable"
        unbound = observation.get("unboundRuns") or []
        uncounted = (
            f"; {len(unbound)} runs of events GitHub records on the default branch's latest commit "
            "were not counted (unboundRuns)" if unbound else ""
        )
        return "satisfied", f"all {summary} on the head succeeded across two identical observations{uncounted}"


def workflow_snapshot(gh: Gh, repo: str, run_id: int) -> dict[str, Any]:
    run = gh.rest(f"repos/{repo}/actions/runs/{run_id}")
    return {"runId": run.get("id"), "head": run.get("head_sha"), "status": run.get("status"), "conclusion": run.get("conclusion"), "url": run.get("html_url")}


def tag_snapshot(gh: Gh, repo: str, tag: str) -> dict[str, Any]:
    owner, name = repo_parts(repo)
    try:
        data = gh.graphql(TAG_QUERY, {"owner": owner, "name": name, "qualified": f"refs/tags/{tag}", "tag": tag})
        repository = data.get("repository") or {}
        ref = repository.get("ref") or {}
        target = ref.get("target") or {}
        oid = (target.get("target") or {}).get("oid") or target.get("oid")
        release = repository.get("release") or None
        assets = (release or {}).get("releaseAssets") or {}
        if assets.get("pageInfo", {}).get("hasNextPage"):
            raise WaitError("release has more than 100 assets; complete pagination is required")
        return {"tag": tag, "target": oid, "release": None if release is None else {"draft": release.get("isDraft"), "prerelease": release.get("isPrerelease"), "url": release.get("url"), "assets": sorted(node.get("name") for node in assets.get("nodes", []))}}
    except RateLimited:
        gh.metrics.rate_limit_fallbacks += 1
        try:
            ref = gh.rest(f"repos/{repo}/git/ref/tags/{quote(tag, safe='')}")
            oid = ref.get("object", {}).get("sha")
            if ref.get("object", {}).get("type") == "tag" and oid:
                annotated = gh.rest(f"repos/{repo}/git/tags/{oid}")
                oid = annotated.get("object", {}).get("sha")
        except WaitError as error:
            if "404" in str(error) or "not found" in str(error).lower():
                oid = None
            else:
                raise
        try:
            release = gh.rest(f"repos/{repo}/releases/tags/{quote(tag, safe='')}")
        except WaitError as error:
            if "404" in str(error) or "not found" in str(error).lower():
                release = None
            else:
                raise
        return {"tag": tag, "target": oid, "release": None if release is None else {"draft": release.get("draft"), "prerelease": release.get("prerelease"), "url": release.get("html_url"), "assets": sorted(asset.get("name") for asset in release.get("assets", []))}}


def legacy_checks_digests(observation: dict[str, Any]) -> set[str]:
    """Digests that helpers before 2026-10 saved for a checks-terminal observation.

    Their key listed every terminal check that did not succeed, named or not.
    Only a wait on the same head reuses a checkpoint, so this can go once the
    heads awaited before 2026-10 are merged or abandoned.
    """
    names = sorted(
        check.get("name") for check in observation.get("checks", [])
        if check_is_terminal(check) and str(check.get("conclusion", "")).upper() != "SUCCESS"
    )
    return {
        stable_digest({"head": observation.get("head"), "nonSuccess": names, "terminal": terminal})
        for terminal in (False, True)
    }


def rekey_legacy_checkpoint(path: Path | None, identity: dict[str, Any], transition_key: Any) -> None:
    """Re-digest a checkpoint saved under the old key, so upgrading is not a change."""
    prior = load_state(path)
    observation = (prior or {}).get("observation")
    # Another wait's checkpoint is invalidated, never rewritten.
    if not observation or prior.get("kind") != "checks-terminal" or prior.get("identity") != identity:
        return
    key = transition_key(observation)
    if key is None:
        return
    digest = stable_digest(key)
    if prior.get("digest") != digest and prior.get("digest") in legacy_checks_digests(observation):
        write_state(path, {**prior, "digest": digest})


KINDS_HELP = """kinds and the flags each needs besides --repo:
  checks-terminal    --head SHA, and --all-workflows, one --check NAME per
                     context, or both. With --pr N it waits on that pull
                     request's head; without --pr, on the commit itself, such
                     as a merge commit on the default branch (full SHA).
  pr-merged          --pr N and --head SHA
  workflow-terminal  --run-id ID; --head SHA also checks the run's commit
  tag-target         --tag NAME and --head SHA
  release-assets     --tag NAME, --head SHA and one --asset NAME per asset
  wake-at            (wait only) --deadline alone"""


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Wait for, or inspect, one GitHub delivery transition.",
        epilog=KINDS_HELP, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = result.add_subparsers(dest="command", required=True)
    for command in ("inspect", "wait"):
        sub = commands.add_parser(
            command, epilog=KINDS_HELP, formatter_class=argparse.RawDescriptionHelpFormatter,
            help="await a transition" if command == "wait" else "take one snapshot",
        )
        kinds = ["checks-terminal", "pr-merged", "workflow-terminal", "tag-target", "release-assets"]
        if command == "wait":
            kinds.append("wake-at")
        sub.add_argument("kind", choices=kinds)
        sub.add_argument("--repo", help="OWNER/REPO")
        sub.add_argument("--pr", type=int, help="pull request number (checks-terminal, pr-merged)")
        sub.add_argument("--head", help="expected commit SHA")
        sub.add_argument("--run-id", type=int, help="workflow run id (workflow-terminal)")
        sub.add_argument("--tag", help="tag name (tag-target, release-assets)")
        sub.add_argument("--asset", action="append", default=[], help="required release asset; repeat for each")
        sub.add_argument("--check", action="append", default=[], help="check or status context that must pass; repeat for each")
        sub.add_argument("--all-workflows", action="store_true", help=(
            "every GitHub Actions run and job on the head must pass, except runs GitHub records on the "
            "default branch's latest commit whatever started them (unboundRuns), such as repository_dispatch"
        ))
        sub.add_argument("--rest-page-size", type=int, choices=range(1, 101), default=100, metavar="1..100")
        sub.add_argument("--json", action="store_true")
        if command == "wait":
            sub.add_argument("--deadline", required=True, help="absolute ISO 8601 time with a timezone")
            sub.add_argument("--interval", type=float, default=30.0)
            sub.add_argument("--state", type=Path)
    return result


def main() -> int:
    args = parser().parse_args()
    metrics = Metrics(time.monotonic())
    if args.kind == "checks-terminal" and args.pr is None and args.head and FULL_SHA.fullmatch(args.head.lower()):
        # Git accepts a SHA in either case; GitHub lists runs by the lowercase one.
        args.head = args.head.lower()
    identity = {
        "repo": args.repo,
        "pr": args.pr,
        "head": args.head,
        "runId": args.run_id,
        "tag": args.tag,
        "checks": sorted(args.check),
        "assets": sorted(args.asset),
    }
    if args.all_workflows:
        # Added only when requested, so existing checkpoints keep their identity.
        identity["allWorkflows"] = True
    try:
        if args.head is not None and not args.head.strip():
            # An empty variable must not turn an optional check into no check.
            raise WaitError("--head is empty: pass the commit SHA, or leave --head out where it is optional")
        # wake-at observes nothing external, so it keeps no checkpoint.
        state_path = (
            None
            if args.command != "wait" or args.kind == "wake-at"
            else args.state or default_state_path(args.kind, identity)
        )
        if args.kind == "wake-at":
            args.interval = positive_interval(args.interval)
            deadline = parse_time(args.deadline)
            with StateLock(state_path):
                output = wait_for_transition(
                    kind=args.kind,
                    identity=identity,
                    observe=lambda: {"wakeAt": args.deadline},
                    classify=lambda _value: ("waiting", "wake time has not arrived"),
                    state_path=state_path,
                    deadline=deadline,
                    interval=args.interval,
                    metrics=metrics,
                    deadline_result=("satisfied", "wake time reached"),
                )
        else:
            if not args.repo:
                raise WaitError("--repo is required")
            # A wait keeps the reserve for other work; one inspection may use it.
            gh = Gh(metrics, reserve=CORE_RESERVE if args.command == "wait" else None)
            if args.all_workflows and args.kind != "checks-terminal":
                raise WaitError("--all-workflows applies only to checks-terminal")
            # Only a pull request's head can move; a commit's census has none to follow.
            pull_request = args.kind == "pr-merged" or (args.kind == "checks-terminal" and args.pr is not None)
            if args.kind == "pr-merged" and (not args.pr or not args.head):
                raise WaitError("pr-merged requires --pr and --head")
            if args.kind == "checks-terminal":
                if not args.head:
                    raise WaitError(
                        "checks-terminal requires --head: the pull request's head with --pr, "
                        "or without --pr a commit such as a merge commit on the default branch"
                    )
                if not args.check and not args.all_workflows:
                    raise WaitError(
                        "checks-terminal requires --all-workflows or at least one --check context"
                    )
                if not pull_request and not FULL_SHA.fullmatch(args.head):
                    raise WaitError(
                        "checks-terminal without --pr waits on a commit and needs its full SHA; "
                        f"{args.head!r} is not one"
                    )
            if args.kind == "checks-terminal" and not pull_request:
                if args.all_workflows:
                    observe = lambda: workflow_census(gh, args.repo, None, args.head, bool(args.check), args.rest_page_size, names=set(args.check))
                    gate = WorkflowCensusGate(args.head, set(args.check), args.command == "wait")
                    classify = gate
                else:
                    observe = lambda: commit_snapshot(gh, args.repo, args.head, True, args.rest_page_size, {}, set(args.check))
                    classify = lambda value: classify_pr(args.kind, args.head, set(args.check), value)
            elif pull_request:
                expected_head = ExpectedHead(gh, args.repo, args.head)
                if args.all_workflows:
                    observe = lambda: expected_head.annotate(
                        workflow_census(gh, args.repo, args.pr, args.head, bool(args.check), args.rest_page_size, expected_head, set(args.check))
                    )
                    gate = WorkflowCensusGate(args.head, set(args.check), args.command == "wait")
                    classify = gate
                else:
                    observe = lambda: expected_head.annotate(pr_snapshot(gh, args.repo, args.pr, args.rest_page_size, expected_head, {}, set(args.check)))
                    classify = lambda value: classify_pr(args.kind, args.head, set(args.check), value)
            elif args.kind == "workflow-terminal":
                if not args.run_id:
                    raise WaitError("workflow-terminal requires --run-id")
                observe = lambda: workflow_snapshot(gh, args.repo, args.run_id)
                def classify(value: dict[str, Any]) -> tuple[str, str]:
                    # A run never changes its commit, so --head only checks the run is the intended one.
                    if args.head and value.get("head") != args.head:
                        return "invalidated", f"expected head {args.head}, observed {value.get('head')}"
                    if value.get("status") != "completed":
                        return "waiting", "workflow is not terminal"
                    if value.get("conclusion") != "success":
                        return "changed", f"workflow concluded {value.get('conclusion')}"
                    return "satisfied", "workflow is terminal-success"
            else:
                if not args.tag:
                    raise WaitError("--tag is required")
                observe = lambda: tag_snapshot(gh, args.repo, args.tag)
                if args.kind == "tag-target":
                    if not args.head:
                        raise WaitError("--head is required")
                    classify = lambda value: (("waiting", "tag does not exist") if not value.get("target") else (("satisfied", "tag targets expected object") if value.get("target") == args.head else ("invalidated", f"tag targets {value.get('target')}")))
                else:
                    wanted = set(args.asset)
                    if not args.head:
                        raise WaitError("--head is required")
                    def classify(value: dict[str, Any]) -> tuple[str, str]:
                        if value.get("target") and value.get("target") != args.head:
                            return "invalidated", f"tag targets {value.get('target')}"
                        if not value.get("target"):
                            return "waiting", "tag does not exist"
                        if not value.get("release") or value["release"].get("draft"):
                            return "waiting", "release is not published"
                        if wanted.issubset(set(value["release"].get("assets", []))):
                            return "satisfied", "release assets are present"
                        return "waiting", "release assets are incomplete"

            if args.command == "inspect":
                observation = observe()
                metrics.observations += 1
                state, reason = classify(observation)
                output = result_envelope(args.kind, state, identity, observation, metrics, reason)
            else:
                def transition_key(value: dict[str, Any]) -> Any:
                    if pull_request and value.get("head") != args.head:
                        # Another head is judged by classify_head alone, and
                        # one GitHub has not moved yet must not make the
                        # expected head look like a change once it arrives.
                        return None
                    if args.all_workflows:
                        # The gate is stateful, so the key must not call it.
                        return {"head": value.get("head"), "failures": gate.failures(value)}
                    if args.kind == "checks-terminal":
                        terminal = classify(value)[0]
                        # Only the named checks can wake the wait, judged as classify_pr
                        # judges them.
                        return {
                            "head": value.get("head"),
                            "nonSuccess": failed_checks(set(args.check), checks_by_name(value)),
                            "terminal": terminal == "satisfied",
                        }
                    if args.kind == "pr-merged":
                        return {
                            "head": value.get("head"),
                            "merged": value.get("merged"),
                            "mergeCommit": value.get("mergeCommit") if value.get("merged") else None,
                        }
                    if args.kind == "workflow-terminal":
                        completed = value.get("status") == "completed"
                        return {
                            "head": value.get("head"),
                            "completed": completed,
                            "conclusion": value.get("conclusion") if completed else None,
                        }
                    return {"terminal": classify(value)[0] != "waiting"}
                deadline = parse_time(args.deadline)
                args.interval = positive_interval(args.interval)
                with StateLock(state_path):
                    if pull_request:
                        expected_head.resume(state_path, args.kind, identity)
                    if args.kind == "checks-terminal" and not args.all_workflows:
                        rekey_legacy_checkpoint(state_path, identity, transition_key)
                    if args.kind == "checks-terminal":
                        rekey_unbound_checkpoint(state_path, identity, transition_key, lambda: {
                            run.get("check_suite_id"): run.get("event")
                            for run in head_runs(gh, args.repo, args.head, args.rest_page_size)
                        })
                    output = wait_for_transition(kind=args.kind, identity=identity, observe=observe, classify=classify, state_path=state_path, deadline=deadline, interval=args.interval, metrics=metrics, transition_key=transition_key, pace=gh.pace, not_before=gh.not_before, limits=gh, wake_by=ExpectedHead.due if pull_request else None, keep={"expectedHead": expected_head} if pull_request else None)
        emit(output, args.json)
        return 0
    except WaitError as error:
        output = result_envelope(args.kind, "operational-error", identity, {}, metrics, str(error))
        emit(output, args.json)
        return 2


if __name__ == "__main__":
    sys.exit(main())
