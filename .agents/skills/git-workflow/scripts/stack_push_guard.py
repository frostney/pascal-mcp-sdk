#!/usr/bin/env python3
"""Bind native stack pushes to approved Git objects. Standard library only."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
import urllib.parse
import uuid

sys.dont_write_bytecode = True  # Keep installed skill trees free of __pycache__.


class GuardError(RuntimeError):
    pass


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def digest(value):
    return hashlib.sha256(encode(value)).hexdigest()


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise GuardError("duplicate JSON key")
        result[key] = value
    return result


def load_json(raw):
    return json.loads(raw, object_pairs_hook=pairs)


def write_once(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(encode(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def read_record(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise GuardError("admission is not a regular owned file")
    value = load_json(path.read_bytes())
    if (not isinstance(value, dict) or set(value) != {"schemaVersion", "request", "digest"}
            or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or value["digest"] != digest(value["request"])):
        raise GuardError("admission record is corrupt")
    return value["request"]


ADMISSION_FIELDS = ("directory", "remote", "url", "refs")
REF_FIELDS = ("ref", "source", "expected")
REWRITE_FIELDS = ("ref", "reason")


def quoted(keys):
    # ASCII escapes keep a key with a line separator from splitting the message.
    names = [json.dumps(key) for key in keys]
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def check_fields(value, what, required, optional=(), where=""):
    """Refuse an object whose keys differ from the documented ones, naming each key that differs.

    The message starts `invalid WHAT fields` and names the entry after it, so
    a match on that prefix still holds.
    """
    expected = quoted(required) + (", optionally " + quoted(optional) if optional else "")
    if not isinstance(value, dict):
        raise GuardError(f"invalid {what} fields{where}: expected a JSON object with the keys {expected}")
    missing = [key for key in required if key not in value]
    unexpected = [key for key in value if key not in required and key not in optional]
    if missing or unexpected:
        found = "; ".join(part for part in (
            "unexpected " + quoted(unexpected) if unexpected else "",
            "missing " + quoted(missing) if missing else "",
        ) if part)
        raise GuardError(f"invalid {what} fields{where}: {found}; the keys are {expected}")


def validate_admission(value):
    check_fields(value, "admission", ADMISSION_FIELDS, ("rewrite",))
    if not isinstance(value["directory"], str) or not Path(value["directory"]).is_absolute():
        raise GuardError("checkout must be an absolute path")
    if not isinstance(value["remote"], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", value["remote"]):
        raise GuardError("invalid remote name")
    if not isinstance(value["url"], str) or not value["url"] or any(ord(c) < 32 for c in value["url"]):
        raise GuardError("invalid remote URL")
    if not isinstance(value["refs"], list) or not value["refs"]:
        raise GuardError("admission needs explicit branch refs")
    refs, seen, lengths = [], set(), set()
    for index, row in enumerate(value["refs"]):
        check_fields(row, "admitted ref", REF_FIELDS, where=f" in refs[{index}]")
        ref = row["ref"]
        if (not isinstance(ref, str) or not ref.startswith("refs/heads/") or ref.endswith(("/", "."))
                or any(ord(c) <= 32 or ord(c) == 127 or c in "~^:?*[\\" for c in ref)
                or any(part.startswith(".") or part.endswith(".lock") for part in ref.split("/"))
                or any(part in ref for part in ("..", "@{", "//")) or ref in seen):
            raise GuardError("invalid or duplicate admitted branch ref")
        for name in ("source", "expected"):
            if not isinstance(row[name], str) or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", row[name]):
                raise GuardError("invalid Git object ID")
            lengths.add(len(row[name]))
        if set(row["source"]) == {"0"}:
            raise GuardError("branch deletion is outside this publication helper")
        seen.add(ref)
        refs.append({"ref": ref, "source": row["source"], "expected": row["expected"]})
    if len(lengths) != 1:
        raise GuardError("mixed Git object formats")
    result = {"directory": value["directory"], "remote": value["remote"], "url": value["url"], "refs": refs}
    if "rewrite" in value:
        if not isinstance(value["rewrite"], list) or not value["rewrite"]:
            raise GuardError("rewrite needs explicit entries")
        rewrite, listed = [], set()
        for index, row in enumerate(value["rewrite"]):
            check_fields(row, "rewrite", REWRITE_FIELDS, ("draftOnly",), where=f" in rewrite[{index}]")
            if "draftOnly" in row and row["draftOnly"] is not True:
                raise GuardError("rewrite draftOnly must be true when given")
            if not isinstance(row["ref"], str) or row["ref"] not in seen or row["ref"] in listed:
                raise GuardError("rewrite names a ref that is not admitted, or names it twice")
            if not isinstance(row["reason"], str) or not row["reason"].strip():
                raise GuardError("rewrite needs a reason for each ref")
            listed.add(row["ref"])
            rewrite.append({"ref": row["ref"], "reason": row["reason"], **({"draftOnly": True} if "draftOnly" in row else {})})
        result["rewrite"] = rewrite
    return result


def validate_updates(admission, remote, url, text):
    c = validate_admission(admission)
    if remote != c["remote"] or url != c["url"]:
        raise GuardError("remote identity changed")
    allowed = {r["ref"]: r for r in c["refs"]}
    seen, updates = set(), []
    for line in text.split("\n"):
        if not line:
            continue
        parts = line.split(" ")
        if len(parts) != 4:
            raise GuardError("invalid update record")
        local, source, ref, expected = parts
        row = allowed.get(ref)
        if row is None or local != ref or ref in seen:
            raise GuardError("unexpected or duplicated ref update")
        if source != row["source"] or expected != row["expected"]:
            raise GuardError("queued source or advertised remote head differs from admission")
        seen.add(ref)
        updates.append({"ref": ref, "source": source, "expected": expected})
    return updates


def admit_updates(admission, remote, url, text, api=None):
    """What the hook admits: only updates the record lists, and none that moves a
    pull request GitHub now protects."""
    updates = validate_updates(admission, remote, url, text)
    return updates, check_rewrites({**validate_admission(admission), "refs": updates}, api or github_api)


def git(directory, *args):
    result = subprocess.run(["git", *args], cwd=directory, stdin=subprocess.DEVNULL, capture_output=True)
    if result.returncode:
        raise GuardError("Git preflight failed: " + args[0])
    return result.stdout.decode("utf-8").strip()


def config_count(environment):
    raw = environment.get("GIT_CONFIG_COUNT", "0")
    if not re.fullmatch(r"0|[1-9][0-9]*", raw) or int(raw) > 1000:
        raise GuardError("invalid inherited Git config count")
    for number in range(int(raw)):
        if any(f"GIT_CONFIG_{key}_{number}" not in environment for key in ("KEY", "VALUE")):
            raise GuardError("incomplete inherited Git configuration")
    return int(raw)


def github_repository(url):
    """The API host and OWNER/REPO that an HTTPS, ssh:// or scp-style remote URL names."""
    match = (re.fullmatch(r"(?:https|ssh)://(?:[^@/]+@)?([A-Za-z0-9.-]+)(?::[0-9]+)?/([A-Za-z0-9_-]+/[A-Za-z0-9._-]+?)(?:\.git)?/?", url)
             or re.fullmatch(r"(?:[^@/:]+@)?([A-Za-z0-9.-]+):([A-Za-z0-9_-]+/[A-Za-z0-9._-]+?)(?:\.git)?/?", url))
    if not match:
        raise GuardError("remote URL names no GitHub repository, so the pull requests whose head would change cannot be checked")
    # GitHub's SSH-over-HTTPS endpoint serves the same repositories as github.com.
    return ("github.com" if match.group(1) == "ssh.github.com" else match.group(1)), match.group(2)


def gh_api(host, path, *fields):
    try:
        return subprocess.run(["gh", "api", "--hostname", host, path, *fields], stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=60)
    except FileNotFoundError:
        raise GuardError("gh is not installed; it checks the pull requests whose head would change") from None
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GuardError(f"GitHub lookup failed: {path}: {error}") from None


def last_line(result):
    lines = result.stderr.decode("utf-8", "replace").strip().splitlines()
    return lines[-1] if lines else f"gh exited {result.returncode}"


def rate_limited(result):
    """Whether GitHub refused a REST call for its budget: the hourly one or a secondary limit."""
    text = result.stderr.decode("utf-8", "replace").lower()
    return "rate limit" in text or "http 429" in text


def github_api(host, path):
    """A REST lookup; once GitHub refuses it for its budget, the same lookup through GraphQL,
    which has a budget of its own, answered in the shape REST would give."""
    result = gh_api(host, path)
    if result.returncode:
        if rate_limited(result):
            return graphql_lookup(host, path, last_line(result))
        raise GuardError(f"GitHub lookup failed: {path}: " + last_line(result))
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise GuardError(f"GitHub lookup returned invalid JSON: {path}") from None


REPOSITORY_QUERY = "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){nameWithOwner}}"
PULLS_QUERY = """query($owner:String!,$name:String!,$branch:String!,$after:String){repository(owner:$owner,name:$name){
pullRequests(states:OPEN,headRefName:$branch,first:100,after:$after){totalCount pageInfo{hasNextPage endCursor}
nodes{number isDraft headRefName headRefOid headRepository{nameWithOwner}}}}}"""
SUITES_QUERY = """query($owner:String!,$name:String!,$oid:GitObjectID!,$after:String){
repository(owner:$owner,name:$name){object(oid:$oid){... on Commit{checkSuites(first:100,after:$after){totalCount
pageInfo{hasNextPage endCursor} nodes{status conclusion app{slug} workflowRun{databaseId event
workflow{databaseId name}}}}}}}}"""
REST_PATH = re.compile(r"repos/([^/?]+)/([^/?]+)(?:/(pulls|actions/runs)\?(.*))?")
# The app whose check suites are GitHub Actions workflow runs.
ACTIONS_APP = "github-actions"
# Pages of pull requests on one head branch, and of check suites on one commit,
# read through GraphQL. Unlike REST's filtered lists, these include fork pull
# requests and other apps' check suites, so they may run longer than REST's.
GRAPHQL_PAGES = 30


def graphql(host, path, why, query, **variables):
    """GraphQL's data for QUERY, or a refusal that names both failures."""
    fields = ["-f", "query=" + query]
    for key, value in variables.items():
        if value is not None:
            fields += ["-f", f"{key}={value}"]
    result = gh_api(host, "graphql", *fields)
    try:
        body = json.loads(result.stdout)
    except ValueError:
        body = None
    errors = body.get("errors") if isinstance(body, dict) else None
    if result.returncode or errors or not isinstance(body, dict) or not isinstance(body.get("data"), dict):
        if errors and isinstance(errors, list) and isinstance(errors[0], dict):
            detail = str(errors[0].get("message") or errors[0].get("type"))
        else:
            detail = last_line(result) if result.returncode else "no data"
        raise GuardError(f"GitHub lookup failed: {path}: REST refused it ({why}), and GraphQL did too: {detail}")
    return body["data"]


def connection(found, name, what):
    """The NAME connection of a GraphQL object, with its nodes and a well-formed page cursor."""
    found = found.get(name) if isinstance(found, dict) else None
    info = found.get("pageInfo") if isinstance(found, dict) else None
    if (not isinstance(found, dict) or not isinstance(found.get("nodes"), list) or not isinstance(info, dict)
            or type(info.get("hasNextPage")) is not bool
            or (info["hasNextPage"] and (not isinstance(info.get("endCursor"), str) or not info["endCursor"]))):
        raise GuardError("GitHub lookup returned no " + what)
    if any(not isinstance(node, dict) for node in found["nodes"]):
        raise GuardError("GitHub lookup returned an incomplete " + what)
    return found["nodes"], info["endCursor"] if info["hasNextPage"] else None, found.get("totalCount")


def graphql_lookup(host, path, why):
    """Answer a REST lookup the guard makes through GraphQL instead."""
    match = REST_PATH.fullmatch(path)
    if not match:
        raise GuardError(f"GitHub lookup failed: {path}: {why}")
    owner, name, kind, query = match.groups()
    owner, name = urllib.parse.unquote(owner), urllib.parse.unquote(name)
    parameters = dict(urllib.parse.parse_qsl(query or ""))
    needs = {None: set(), "pulls": {"head", "per_page"}, "actions/runs": {"head_sha"}}[kind]
    if not needs <= set(parameters) or (kind == "pulls" and ":" not in parameters["head"]):
        raise GuardError(f"GitHub lookup failed: {path}: {why}")
    if kind is None:
        found = graphql(host, path, why, REPOSITORY_QUERY, owner=owner, name=name).get("repository")
        if not isinstance(found, dict) or not isinstance(found.get("nameWithOwner"), str):
            raise GuardError("GitHub lookup returned no repository for " + owner + "/" + name)
        return {"full_name": found["nameWithOwner"]}
    if kind == "pulls":
        return graphql_pulls(host, path, why, owner, name, parameters)
    return graphql_runs(host, path, why, owner, name, parameters["head_sha"])


def graphql_pulls(host, path, why, owner, name, parameters):
    """REST's open pull requests for head=OWNER:BRANCH. GraphQL filters by branch
    alone, so pull requests from other owners' forks are dropped here, before
    REST's one-page cutoff applies."""
    head_owner, branch = parameters["head"].split(":", 1)
    limit = int(parameters["per_page"])
    answer, after, total, numbers = [], None, None, set()
    for _ in range(GRAPHQL_PAGES):
        found = graphql(host, path, why, PULLS_QUERY, owner=owner, name=name, branch=branch, after=after)
        nodes, after, count = connection(found.get("repository"), "pullRequests",
                                         "pull request list for refs/heads/" + branch)
        # A pull request opened or reopened behind the cursor shows only in the count.
        if type(count) is not int or (total is not None and count != total):
            raise GuardError("the open pull requests for refs/heads/" + branch + " changed while they were read")
        total = count
        for node in nodes:
            if node.get("number") in numbers:
                raise GuardError("the open pull requests for refs/heads/" + branch + " changed while they were read")
            numbers.add(node.get("number"))
            source = (node.get("headRepository") or {}).get("nameWithOwner")
            if isinstance(source, str) and source.split("/")[0].lower() != head_owner.lower():
                continue
            answer.append({"number": node.get("number"), "draft": node.get("isDraft"),
                           "head": {"ref": node.get("headRefName"), "sha": node.get("headRefOid"),
                                    "repo": {"full_name": source} if isinstance(source, str) else None}})
        if after is None and len(numbers) != total:
            raise GuardError("the open pull requests for refs/heads/" + branch + " changed while they were read")
        if after is None or len(answer) >= limit:
            return answer[:limit]
    raise GuardError("more than one page of open pull requests for refs/heads/" + branch
                     + "; they cannot all be checked")


def graphql_runs(host, path, why, owner, name, sha):
    """The GitHub Actions runs on a commit, from its check suites, in the shape REST
    lists them. Other apps' check suites have no workflow run and can stay queued
    for good, so they are left out, as REST's list leaves them out; an Actions
    suite whose run is missing refuses. The whole list comes from GraphQL, marked
    so head_runs never mixes it with pages REST read before."""
    runs, after, total, seen = [], None, None, 0
    for _ in range(GRAPHQL_PAGES):
        found = graphql(host, path, why, SUITES_QUERY, owner=owner, name=name, oid=sha, after=after)
        found = found.get("repository")
        nodes, after, count = connection(found.get("object") if isinstance(found, dict) else None, "checkSuites",
                                         f"check suites for commit {sha}")
        # A cursor walks on over a list that changes; the count shows that it did.
        if type(count) is not int or (total is not None and count != total):
            raise GuardError(f"the check suites of commit {sha} changed while they were read")
        total, seen = count, seen + len(nodes)
        for suite in nodes:
            app = (suite.get("app") or {}).get("slug")
            if not isinstance(app, str):
                raise GuardError(f"GitHub lookup returned a check suite without its app for commit {sha}")
            if app != ACTIONS_APP:
                continue
            run = suite.get("workflowRun")
            workflow = run.get("workflow") if isinstance(run, dict) else None
            if not isinstance(workflow, dict) or type(workflow.get("databaseId")) is not int:
                raise GuardError(f"GitHub lookup returned a GitHub Actions check suite without its run for commit {sha}")
            status, conclusion = suite.get("status"), suite.get("conclusion")
            runs.append({"id": run.get("databaseId"), "name": workflow.get("name"), "event": run.get("event"),
                         "status": status.lower() if isinstance(status, str) else None,
                         "conclusion": conclusion.lower() if isinstance(conclusion, str) else None,
                         "workflow_id": workflow.get("databaseId")})
        if after is None:
            if seen != total:
                raise GuardError(f"the check suites of commit {sha} changed while they were read")
            return {"total_count": len(runs), "workflow_runs": runs, "graphql": True, "complete": True}
        if len(runs) > RUN_PAGES * 100:
            break
    # Cut short, like REST past its tenth page: head_runs keeps the list only when
    # a run in it is still going, and its count is then only a lower bound.
    return {"total_count": len(runs), "workflow_runs": runs, "graphql": True, "complete": False}


def check_rewrites(c, api=github_api):
    """Refuse to move the head of an open pull request the guard protects,
    unless `rewrite` lists its ref. A layer is frozen once CI on its exact head
    has passed and its review is terminal, or once it is ready for review. The
    guard cannot see when a review ends, so it protects every ready pull
    request and every draft whose CI passed. A draft with no runs, or whose runs
    failed, were cancelled or are still going, may move: its fix goes in place.
    A `rewrite` entry with `draftOnly` lets a draft whose CI passed move while
    its review has not finished, but the guard still looks it up and refuses
    it once any open pull request on that ref is ready for review.
    Returns what was observed, with the reason each may move, for the prepared record."""
    listed = {r["ref"] for r in c.get("rewrite", ()) if not r.get("draftOnly")}
    draft_only = {r["ref"] for r in c.get("rewrite", ()) if r.get("draftOnly")}
    moving = [r for r in c["refs"] if set(r["expected"]) != {"0"} and r["expected"] != r["source"]
              and r["ref"] not in listed]
    if not moving:
        return []
    host, named = github_repository(c["url"])
    # A transferred or renamed repository still answers at its old URL, but the
    # head filter needs its current owner, or it matches no pull request.
    found = api(host, f"repos/{named}")
    if not isinstance(found, dict) or not isinstance(found.get("full_name"), str) or "/" not in found["full_name"]:
        raise GuardError("GitHub lookup returned no repository for " + named)
    repository = found["full_name"]
    owner = repository.split("/")[0]
    observed = []
    for row in moving:
        branch = row["ref"].removeprefix("refs/heads/")
        head = urllib.parse.quote(owner + ":" + branch, safe="")
        pulls = api(host, f"repos/{repository}/pulls?state=open&per_page=100&head={head}")
        if not isinstance(pulls, list):
            raise GuardError("GitHub lookup returned no pull request list for " + row["ref"])
        if len(pulls) >= 100:
            raise GuardError("more than one page of open pull requests for " + row["ref"] + "; they cannot all be checked")
        for pull in pulls:
            try:
                number, draft, sha = pull["number"], pull["draft"], pull["head"]["sha"]
                ref, source = pull["head"]["ref"], (pull["head"]["repo"] or {}).get("full_name")
            except (TypeError, KeyError, AttributeError):
                raise GuardError("GitHub lookup returned an incomplete pull request for " + row["ref"]) from None
            if type(number) is not int or type(draft) is not bool:
                raise GuardError("GitHub lookup returned an incomplete pull request for " + row["ref"])
            if ref != branch or not isinstance(source, str) or source.lower() != repository.lower():
                continue
            if sha != row["expected"]:
                raise GuardError(f"pull request #{number} head is {sha}, not the admitted expected commit")
            total, runs, complete = head_runs(api, host, repository, sha, number)
            # A ready pull request is refused whatever its CI, so only a draft
            # needs a list complete enough to show which runs decide.
            state = (ci_state(total, runs, complete, number) if draft or complete else
                     {"workflowRuns": total, "ci": "unknown", "ciPassed": False, "runsGoing": [], "runsListed": False})
            overridden = row["ref"] in draft_only
            reason = (MOVABLE_REASONS[state["ci"]] if not state["ciPassed"]
                      else DRAFT_ONLY_REASON if overridden else None) if draft else None
            observed.append({"ref": row["ref"], "pullRequest": number, "draft": draft, **state,
                             "reason": reason})
    blocked = [o for o in observed if o["reason"] is None]
    if blocked:
        details = ", ".join(f"#{o['pullRequest']} ({o['ref'].removeprefix('refs/heads/')}: "
                            + ("ready for review" if not o["draft"] else "draft, CI passed on its head")
                            + (f", {'' if o['runsListed'] else 'at least '}{o['workflowRuns']} workflow runs on its head"
                               if o["workflowRuns"] else "") + ")"
                            for o in blocked)
        restarted = sum(1 for o in blocked if o["workflowRuns"])
        advice = []
        if any(not o["draft"] for o in blocked):
            advice.append("A pull request that is ready for review is frozen: place the fix as address-feedback's "
                          "stack step 7 says, on the top fix layer when that is not frozen and otherwise in a new top "
                          "layer. Keep plain rewrite entries for the guarded rewrites the stack reference allows, "
                          "such as the final rebase before merging the whole stack; a draftOnly rewrite entry never "
                          "moves a ready pull request")
        if any(o["draft"] for o in blocked):
            advice.append("A draft whose GitHub Actions CI passed is frozen once its review is terminal and its "
                          "head's checks pass: then place the fix as step 7 says, on the top fix layer when that is "
                          "not frozen and otherwise in a new top layer. While its review has not finished, or another "
                          "check on its head has not passed, it is not frozen, so the fix goes in place: re-check that "
                          "just before the push and list its ref under rewrite with draftOnly true and a reason that "
                          "names it")
        raise GuardError(f"refusing to move the head of {len(blocked)} open pull request(s): {details}. "
                         f"Pushing would restart CI on {restarted} of them. " + ". ".join(advice) + ".")
    return observed


# Why the guard lets a draft move, by the state of CI on its head.
MOVABLE_REASONS = {
    "none": "draft with no workflow runs on its head, so it is not frozen",
    "running": "draft whose CI on its head has not finished, so it is not frozen; the push supersedes those runs",
    "failed": "draft whose CI on its head failed or was cancelled, so it is not frozen; the push reruns it",
}
DRAFT_ONLY_REASON = ("draft whose GitHub Actions CI on its head passed, listed under rewrite with draftOnly as not "
                     "frozen for the admitted reason; the push restarts its CI")


# A run with one of these conclusions counts as passed; any other conclusion,
# such as failure, cancelled or timed_out, leaves the workflow unpassed.
PASSING = frozenset({"success", "neutral", "skipped"})
RUN_PAGES = 10
# The statuses GitHub gives a workflow run; every one but completed is still going.
RUN_STATUSES = frozenset({"completed", "queued", "in_progress", "waiting", "requested", "pending", "action_required"})
# Runs a push to the pull request's head supersedes.
PULL_REQUEST_EVENTS = frozenset({"pull_request", "pull_request_target"})


def head_runs(api, host, repository, sha, number):
    """Every workflow run on a head, read page by page. Refuses a list that
    changes while it is read. Past RUN_PAGES pages it keeps what it read only
    when that already shows a run still going, which settles that CI has not
    passed; the third value says whether the list is complete."""
    runs, ids, total = [], set(), None
    for page in range(1, RUN_PAGES + 1):
        found = api(host, f"repos/{repository}/actions/runs?per_page=100&page={page}&head_sha={sha}")
        if (not isinstance(found, dict) or type(found.get("total_count")) is not int
                or not isinstance(found.get("workflow_runs"), list)):
            raise GuardError(f"GitHub lookup returned no workflow runs for pull request #{number}")
        if found.get("graphql") is True:
            # REST ran out part way: the whole list comes from GraphQL instead,
            # never pages from both, which can disagree about the same run.
            runs, ids, total = [], set(), None
        if total is not None and found["total_count"] != total:
            raise GuardError(f"the workflow runs of pull request #{number} changed while they were read")
        total = found["total_count"]
        for run in found["workflow_runs"]:
            if (not isinstance(run, dict) or type(run.get("id")) is not int or run.get("status") not in RUN_STATUSES
                    or "workflow_id" not in run
                    or (run["status"] == "completed"
                        and (not isinstance(run.get("conclusion"), str) or not run["conclusion"]))):
                raise GuardError(f"GitHub lookup returned an incomplete workflow run for pull request #{number}")
            if run["id"] in ids:
                raise GuardError(f"the workflow runs of pull request #{number} changed while they were read")
            ids.add(run["id"])
        runs.extend(found["workflow_runs"])
        if found.get("graphql") is True and found.get("complete") is not True:
            break
        if len(runs) >= total:
            if len(runs) > total:
                raise GuardError(f"the workflow runs of pull request #{number} changed while they were read")
            return total, runs, True
        if not found["workflow_runs"]:
            raise GuardError(f"GitHub lookup listed fewer workflow runs than it counted for pull request #{number}")
    if any(run["status"] != "completed" for run in runs):
        return total, runs, False
    raise GuardError(f"more than {RUN_PAGES} pages of workflow runs for pull request #{number}; they cannot all be checked")


def ci_state(total, runs, complete, number):
    """The state of a head's CI, decided by the newest run of each workflow
    and event on it, as in delivery-wait: a newer run of a source replaces an
    older one, so neither an older success nor an older run still going
    decides. `none` without runs, `running` while a deciding run is queued or
    in progress, `passed` when every deciding run passed, and `failed`
    otherwise. A newest run that was cancelled has not passed, even beside an
    older passed run of its source: the head is then not green, as the pull
    request gate counts it, until the cancelled run is rerun. A list cut short
    cannot show which run of a source is newest, so it refuses. Also names the
    pull request runs still going, deciding or not, which a push to the head
    supersedes."""
    if not complete:
        raise GuardError(f"more than {RUN_PAGES} pages of workflow runs for pull request #{number}; which run of "
                         "each workflow decides cannot be established")
    going = [run for run in runs if run["status"] != "completed"]
    superseded = [f"{run.get('name') or 'workflow ' + str(run['workflow_id'])} run {run['id']} ({run['status']})"
                  for run in going if run.get("event") in PULL_REQUEST_EVENTS]
    sources = {}
    for run in runs:
        sources.setdefault((run["workflow_id"], run.get("event")), []).append(run)
    deciding = [max(source, key=lambda run: run["id"]) for source in sources.values()]
    if any(run["status"] != "completed" for run in deciding):
        ci = "running"
    else:
        passed = [run["conclusion"] in PASSING for run in deciding]
        ci = "none" if not passed else "passed" if all(passed) else "failed"
    return {"workflowRuns": total, "ci": ci, "ciPassed": ci == "passed", "runsGoing": superseded,
            "runsListed": complete}


def prepare(value, api=github_api):
    c = validate_admission(value)
    directory = Path(c["directory"])
    if str(directory.resolve(strict=True)) != c["directory"]:
        raise GuardError("checkout path changed")
    if git(directory, "status", "--porcelain"):
        raise GuardError("publication checkout is dirty")
    if git(directory, "remote", "get-url", "--push", c["remote"]) != c["url"]:
        raise GuardError("remote push URL differs from admission")
    object_length = 64 if git(directory, "rev-parse", "--show-object-format") == "sha256" else 40
    for row in c["refs"]:
        git(directory, "check-ref-format", row["ref"])
        if len(row["source"]) != object_length:
            raise GuardError("admission object format differs from repository")
        git(directory, "cat-file", "-e", row["source"] + "^{commit}")
    # Refuse before anything is prepared; the hook checks again at the push,
    # since a pull request can become ready or its CI can pass in between.
    pull_requests = check_rewrites(c, api)
    for o in pull_requests:
        going = (("; once the push lands, cancel any of these pull request runs on the old head that its "
                  "concurrency group did not: " + ", ".join(o["runsGoing"])
                  + ("" if o["runsListed"] else f", and others past the first {RUN_PAGES} pages"))
                 if o["runsGoing"] else "")
        cost = (f"; it restarts its CI ({'' if o['runsListed'] else 'at least '}{o['workflowRuns']} workflow runs "
                f"on its current head)" if o["workflowRuns"] else "")
        print(f"Push guard: moving draft #{o['pullRequest']} in place: {o['reason']}{cost}{going}", file=sys.stderr)
    count = config_count(os.environ)
    git_dir = Path(git(directory, "rev-parse", "--absolute-git-dir"))
    original_hooks = Path(git(directory, "rev-parse", "--path-format=absolute", "--git-path", "hooks"))
    root = git_dir / "kgr-push-guards" / str(uuid.uuid4())
    hooks = root / "hooks"
    hooks.mkdir(parents=True, mode=0o700)
    original_pre_push = None
    if original_hooks.is_dir():
        for entry in original_hooks.iterdir():
            if entry.name == "pre-push":
                if entry.is_file() and os.access(entry, os.X_OK):
                    original_pre_push = str(entry)
            else:
                (hooks / entry.name).symlink_to(entry)
    source = Path(__file__).read_bytes()
    frozen = root / "guard.py"
    with frozen.open("xb") as stream:
        stream.write(source)
        stream.flush()
        os.fsync(stream.fileno())
    request = {"admission": c, "pullRequests": pull_requests, "directory": str(root), "originalHooks": str(original_hooks),
               "originalPrePush": original_pre_push, "helperDigest": hashlib.sha256(source).hexdigest(),
               "pythonBinary": str(Path(sys.executable).resolve()), "pythonVersion": sys.version,
               "injectedConfigIndex": count, "originalConfigCount": os.environ.get("GIT_CONFIG_COUNT")}
    config = root / "admission.json"
    write_once(config, {"schemaVersion": 1, "request": request, "digest": digest(request)})
    hook = hooks / "pre-push"
    hook.write_text("#!/bin/sh\nexec " + " ".join(shlex.quote(v) for v in
                    (request["pythonBinary"], str(frozen), "_hook", str(config))) + ' "$@"\n')
    hook.chmod(0o755)
    return {"directory": str(root), "configuration": {"GIT_CONFIG_COUNT": str(count + 1),
            f"GIT_CONFIG_KEY_{count}": "core.hooksPath", f"GIT_CONFIG_VALUE_{count}": str(hooks)}}


def original_hook_environment(config):
    environment = dict(os.environ)
    index = config["injectedConfigIndex"]
    if (environment.get("GIT_CONFIG_COUNT") != str(index + 1)
            or environment.get(f"GIT_CONFIG_KEY_{index}") != "core.hooksPath"
            or environment.get(f"GIT_CONFIG_VALUE_{index}") != str(Path(config["directory"]) / "hooks")):
        raise GuardError("guard configuration environment changed")
    del environment[f"GIT_CONFIG_KEY_{index}"]
    del environment[f"GIT_CONFIG_VALUE_{index}"]
    if config["originalConfigCount"] is None:
        environment.pop("GIT_CONFIG_COUNT", None)
    else:
        environment["GIT_CONFIG_COUNT"] = config["originalConfigCount"]
    return environment


def hook(config_path, remote, url):
    config = read_record(config_path)
    root = Path(config["directory"])
    if (Path(config_path).resolve().parent != root or Path(__file__).resolve() != root / "guard.py"
            or hashlib.sha256(Path(__file__).read_bytes()).hexdigest() != config["helperDigest"]
            or str(Path(sys.executable).resolve()) != config["pythonBinary"] or sys.version != config["pythonVersion"]):
        raise GuardError("frozen guard configuration or runtime changed")
    receipt = {"accepted": False, "admissionDigest": digest(config["admission"]), "pid": os.getpid(),
               "at": datetime.now(timezone.utc).isoformat()}
    try:
        if str(Path.cwd().resolve()) != config["admission"]["directory"]:
            raise GuardError("checkout identity changed")
        limit = sum(2 * len(r["ref"].encode("utf-8")) + len(r["source"]) + len(r["expected"]) + 4
                    for r in config["admission"]["refs"])
        data = sys.stdin.buffer.read(limit + 1)
        if len(data) > limit:
            raise GuardError("update input exceeds admitted scope")
        updates, pull_requests = admit_updates(config["admission"], remote, url, data.decode("utf-8"))
        receipt["pullRequests"] = pull_requests
        environment = original_hook_environment(config)
        if config["originalPrePush"]:
            result = subprocess.run([config["originalPrePush"], remote, url], input=data, env=environment)
            if result.returncode:
                raise GuardError("original pre-push hook rejected publication")
        receipt.update(accepted=True, updates=updates)
    except Exception as error:
        receipt["error"] = "Error: Push guard: " + str(error)
        raise
    finally:
        write_once(root / ("check-" + str(uuid.uuid4()) + ".json"), receipt)


# The guard follows the latest gh-stack release (checked at tag v0.3.0, 2a49e67)
# and checks only that the command is gh-stack, not its version: --version prints
# "gh stack version VERSION" on stdout (cmd/root.go:84), and the release notifier
# writes only to stderr (cmd/root.go:56-82). push and submit pass force=true with
# per-branch --force-with-lease and fully qualified refs/heads/B:refs/heads/B
# refspecs after a best-effort tracking fetch, all branches in one push
# (cmd/push.go:111-113, cmd/submit.go:216,254); link pushes only arguments naming
# local branches, without force (cmd/link.go:447-480). All three push with
# --atomic unless --no-atomic or GH_STACK_NO_ATOMIC is given.
# internal/git/gitops.go:258-306 builds those arguments; a forced push first runs
# git -c push.pushOption=pull.stacked push and repeats without the option when
# the remote does not support push options, so the hook can see the same updates
# twice. No guarded path pushes with --no-verify or a + refspec. push and submit
# refuse a stack GitHub retargeted after its base branch was deleted
# (cmd/utils.go:1145-1156). Pushes run in the current checkout through the
# unscoped executor; the worktree-scoped executor drops GIT_CONFIG but keeps
# GIT_CONFIG_COUNT/KEY/VALUE (internal/git/git.go:49-69). The flags are --auto,
# --open, --remote and --no-atomic for submit, --remote and --no-atomic for push,
# and --base, --open, --remote and --no-atomic for link; the accepted commands
# below pass no --no-atomic. link takes a stack or PR number, branch, or PR
# URL, then one or more branch-or-PR arguments (cmd/link.go:29,77); a number
# naming a stack appends to it, otherwise every PR the stack holds must be listed
# (cmd/link.go:175-196,666-693). Its base corrections only warn on failure
# (cmd/link.go:740-783).
GH_STACK_IDENTITY = re.compile(r"gh stack version \S+")
POSITIVE_NUMBER = re.compile(r"[1-9][0-9]*")
# What Go's strconv.Atoi parses; link tries such an argument as a PR number first
# (cmd/link.go:560-573), so a branch named like one is not a safe branch argument.
ATOI_NUMBER = re.compile(r"[+-]?[0-9]+")


def validate_native_command(command, admission):
    if len(command) < 3 or Path(command[0]).name != "gh" or command[1] != "stack":
        raise GuardError("run requires an explicit native gh stack command")
    tail = command[2:]
    if tail == ["submit", "--auto", "--remote", admission["remote"]]:
        return
    if tail == ["push", "--remote", admission["remote"]]:
        return
    # link STACK-OR-PR BRANCH-OR-PR... --remote REMOTE: each later argument is a
    # PR number or an admitted branch that cannot be read as a flag or a number. A number
    # that also names a local branch is pushed, and the hook refuses it unless
    # that branch is admitted.
    admitted = {r["ref"] for r in admission["refs"]}
    targets = tail[1:-2]
    if (len(tail) >= 5 and tail[0] == "link" and tail[-2:] == ["--remote", admission["remote"]]
            and POSITIVE_NUMBER.fullmatch(tail[1]) and len(set(targets)) == len(targets)
            and all(POSITIVE_NUMBER.fullmatch(argument)
                    or (not argument.startswith("-") and not ATOI_NUMBER.fullmatch(argument)
                        and "refs/heads/" + argument in admitted)
                    for argument in targets[1:])):
        return
    raise GuardError("unsupported native publication command; do not bypass hooks")


def main(argv=None):
    if sys.version_info < (3, 11):
        raise GuardError("Python 3.11 or newer is required")
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "_hook":
        if len(argv) != 4:
            raise GuardError("invalid hook invocation")
        hook(*argv[1:])
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "run"))
    parser.add_argument("--admission", required=True, help="JSON file, or - for stdin; keep outside tracked/untracked work")
    split = argv.index("--") if "--" in argv else len(argv)
    command = argv[split + 1:]
    argv = argv[:split]
    args = parser.parse_args(argv)
    raw = sys.stdin.buffer.read() if args.admission == "-" else Path(args.admission).read_bytes()
    admission = validate_admission(load_json(raw))
    if args.operation == "prepare" and command:
        raise GuardError("prepare does not execute a command")
    if args.operation == "run":
        validate_native_command(command, admission)
        try:
            version = subprocess.run([command[0], "stack", "--version"], capture_output=True, text=True)
        except OSError:
            version = None
        if version is None or version.returncode or not GH_STACK_IDENTITY.fullmatch(version.stdout.strip()):
            raise GuardError("command is not the gh-stack extension")
    prepared = prepare(admission)
    if args.operation == "prepare":
        print(json.dumps(prepared))
        return 0
    result = subprocess.run(command, cwd=admission["directory"], env={**os.environ, **prepared["configuration"]})
    write_once(Path(prepared["directory"]) / "run.json", {"command": command, "exitCode": result.returncode})
    print(json.dumps({"guardDirectory": prepared["directory"], "exitCode": result.returncode}), file=sys.stderr)
    return result.returncode if result.returncode >= 0 else 128 - result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("Error: Push guard: " + str(error), file=sys.stderr)
        sys.exit(1)
