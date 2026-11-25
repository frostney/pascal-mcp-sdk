#!/usr/bin/env python3
"""Shared deterministic GitHub observation mechanics for known-good-route."""

from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import re
import signal
import subprocess
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote


class WaitError(RuntimeError):
    """An actionable invocation or GitHub transport failure."""


class RateLimited(WaitError):
    """The primary GraphQL read is explicitly rate-limited."""


class TransientError(WaitError):
    """A temporary transport failure that may recover before the deadline."""


# REST core requests a wait leaves unspent for the account's other work: the
# publication guard, reviews and people. Below it, a wait observes nothing
# more until the budget resets.
CORE_RESERVE = 1000
# A smaller budget, such as a GitHub Actions token's 1,000 an hour, keeps
# this share of its limit instead, so a wait can still read in each window.
RESERVE_SHARE = 0.2
# A wait paces itself to spend at most this share of the core budget left above
# the reserve before the reset, so several waits on one account fit together.
CORE_SHARE = 0.25
# GitHub asks a client that hit a secondary limit without a Retry-After to
# wait at least a minute.
SECONDARY_BACKOFF = 60
# A retry for a follow-up read that is already due waits this long first.
FOLLOW_UP_RETRY = 5
NEXT_LINK = re.compile(r'<([^>]+)>\s*;\s*rel="next"')


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_time(value: str) -> float:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise WaitError(f"invalid RFC 3339 timestamp: {value}") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise WaitError(f"RFC 3339 timestamp needs an explicit timezone: {value}")
    return parsed.timestamp()


def positive_interval(value: float) -> float:
    if not math.isfinite(value) or value <= 0:
        raise WaitError("poll interval must be a positive finite number")
    return value


@dataclass
class Metrics:
    started: float
    observations: int = 0
    api_requests: int = 0
    retries: int = 0
    rate_limit_fallbacks: int = 0
    not_modified: int = 0

    def result(self) -> dict[str, int]:
        return {
            "durationMilliseconds": round((time.monotonic() - self.started) * 1000),
            "observations": self.observations,
            "apiRequests": self.api_requests,
            "retries": self.retries,
            "rateLimitFallbacks": self.rate_limit_fallbacks,
            "notModified": self.not_modified,
        }


def parse_included(stdout: str) -> tuple[int | None, dict[str, str], str]:
    """The status, lower-cased headers and body of `gh api --include` output."""
    lines = stdout.split("\n")
    match = re.match(r"HTTP/\S+\s+(\d{3})", lines[0]) if lines else None
    if not match:
        return None, {}, stdout
    headers: dict[str, str] = {}
    for index, line in enumerate(lines[1:], 1):
        line = line.rstrip("\r")
        if not line:
            return int(match.group(1)), headers, "\n".join(lines[index + 1:])
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return int(match.group(1)), headers, ""


class Gh:
    """`gh` calls that spend as little of the account's REST core budget as they can.

    A GET repeats its last ETag, and GitHub answers an unchanged resource with
    304 Not Modified, which its primary rate limit does not count. Each REST
    answer reports the core budget left, which `pace` uses to slow a wait down.
    A wait sets `reserve`: with less than that left, a REST read raises
    RateLimited without asking GitHub.
    """

    def __init__(self, metrics: Metrics, timeout: int = 30, reserve: int | None = None) -> None:
        self.metrics = metrics
        self.timeout = timeout
        self.reserve = reserve
        self.cached: dict[str, tuple[str, Any, str | None]] = {}
        self.core: tuple[int, float] | None = None  # (remaining, reset epoch)
        self.limit: int | None = None  # The hourly budget GitHub reports.
        # This window's allowance, CORE_SHARE of the budget above the reserve
        # when this client first saw the window, and what it has spent of it.
        self.window: dict[str, float] = {}
        self.retry_at: float | None = None  # From a Retry-After header.
        self.spent = 0  # REST requests GitHub counted against the core budget
        self.paced_spent = 0

    def call(self, args: list[str], stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        self.metrics.api_requests += 1
        try:
            return subprocess.run(
                ["gh", *args],
                input=stdin,
                text=True,
                capture_output=True,
                timeout=self.timeout,
                check=False,
            )
        except FileNotFoundError as error:
            raise WaitError("gh is not installed or not on PATH") from error
        except subprocess.TimeoutExpired as error:
            raise TransientError(f"gh request timed out after {self.timeout}s") from error

    @staticmethod
    def fail(completed: subprocess.CompletedProcess[str], body: str | None = None) -> None:
        message = (completed.stderr or (completed.stdout if body is None else body)).strip()
        lowered = message.lower()
        if "rate limit" in lowered or "rate-limit" in lowered or "quota" in lowered or "http 429" in lowered:
            raise RateLimited(message or "GitHub API rate limit exceeded")
        if any(marker in lowered for marker in ("timeout", "timed out", "connection reset", "temporary failure", "could not resolve host", "http 502", "http 503", "http 504")):
            raise TransientError(message or "temporary GitHub transport failure")
        raise WaitError(message or f"gh exited {completed.returncode}")

    @staticmethod
    def decode(text: str) -> Any:
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as error:
            raise WaitError("gh returned malformed JSON") from error
        if isinstance(payload, dict) and payload.get("errors"):
            message = json.dumps(payload["errors"], sort_keys=True)
            lowered = message.lower()
            if "rate limit" in lowered or "rate-limit" in lowered or "quota" in lowered:
                raise RateLimited(message)
            raise WaitError(f"GitHub GraphQL error: {message}")
        return payload

    def run(self, args: list[str], stdin: str | None = None) -> Any:
        completed = self.call(args, stdin)
        if completed.returncode != 0:
            self.fail(completed)
        return self.decode(completed.stdout)

    def note_rate(self, headers: dict[str, str], spent: bool = True) -> None:
        """The budget and retry time HEADERS report; SPENT counts the response against the window."""
        try:
            self.retry_at = time.time() + float(headers["retry-after"])
        except (KeyError, ValueError):
            pass
        if headers.get("x-ratelimit-resource", "core") != "core":
            return
        try:
            remaining, reset = int(headers["x-ratelimit-remaining"]), float(headers["x-ratelimit-reset"])
        except (KeyError, ValueError):
            return
        try:
            self.limit = int(headers["x-ratelimit-limit"])
        except (KeyError, ValueError):
            pass
        self.core = (remaining, reset)
        if self.window.get("reset") != reset:
            # Counts the request that reported the window, so the allowance is what is left.
            allowance = max(0, remaining + spent - self.kept()) * CORE_SHARE
            self.window = {"reset": reset, "allowance": allowance, "spent": 0}
        self.window["spent"] += spent

    def not_before(self, now: float | None = None) -> float | None:
        """The earliest time GitHub's limits let this client's next REST read go, or None for now."""
        now = time.time() if now is None else now
        times = [self.retry_at] if self.retry_at is not None and self.retry_at > now else []
        if self.core is not None and now < self.core[1] and (
            self.below_reserve(now) or self.window.get("allowance", 0) <= self.window.get("spent", 0)
        ):
            times.append(self.core[1] + 1)
        return max(times) if times else None

    def below_reserve(self, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        return self.core is not None and now < self.core[1] and self.core[0] < self.kept()

    def kept(self) -> int:
        """The REST requests a wait leaves for other work: CORE_RESERVE, or less of a smaller budget."""
        return CORE_RESERVE if self.limit is None else min(CORE_RESERVE, int(self.limit * RESERVE_SHARE))

    def export(self) -> dict[str, Any]:
        """The budget state a resumed wait needs, so it neither reads too soon nor gets a fresh allowance."""
        return {"core": list(self.core) if self.core else None, "limit": self.limit,
                "window": dict(self.window), "retryAt": self.retry_at}

    def restore(self, saved: Any) -> None:
        if not isinstance(saved, dict):
            return
        try:
            if saved.get("core"):
                self.core = (int(saved["core"][0]), float(saved["core"][1]))
            if saved.get("limit") is not None:
                self.limit = int(saved["limit"])
            if isinstance(saved.get("window"), dict):
                self.window = {key: float(value) for key, value in saved["window"].items()}
            if saved.get("retryAt") is not None:
                self.retry_at = float(saved["retryAt"])
        except (TypeError, ValueError, IndexError, KeyError):
            pass  # A damaged record only costs the resumed wait its first paced read.

    def get(self, endpoint: str) -> tuple[Any, str | None]:
        """One REST page and the URL of the next, revalidated against its last ETag."""
        if self.reserve is not None and self.below_reserve():
            raise RateLimited(f"{self.core[0]} REST requests left, under the {self.kept()} kept for other work, "
                              "until the budget resets")
        cached = self.cached.get(endpoint)
        args = ["api", "--include", endpoint]
        if cached:
            args[1:1] = ["--header", f"If-None-Match: {cached[0]}"]
        completed = self.call(args)
        status, headers, body = parse_included(completed.stdout)
        if status == 304 and cached:
            self.metrics.not_modified += 1
            self.note_rate(headers, spent=False)
            following = cached[2]
            if "link" in headers:
                # A Link replaces the cached one, and one without a next page ends the list.
                link = NEXT_LINK.search(headers["link"])
                following = link.group(1) if link else None
                self.cached[endpoint] = (cached[0], cached[1], following)
            return copy.deepcopy(cached[1]), following
        if status is not None:
            self.spent += 1
            self.note_rate(headers)
            if status in (403, 429) and "retry-after" not in headers and headers.get("x-ratelimit-remaining") != "0":
                if status == 429 or "rate limit" in (completed.stderr + body).lower():
                    self.retry_at = max(self.retry_at or 0.0, time.time() + SECONDARY_BACKOFF)
        if completed.returncode != 0 or status is None or not 200 <= status < 300:
            self.fail(completed, body)
        payload = self.decode(body)
        link = NEXT_LINK.search(headers.get("link", ""))
        following = link.group(1) if link else None
        if headers.get("etag"):
            self.cached[endpoint] = (headers["etag"], copy.deepcopy(payload), following)
        return payload, following

    def graphql(self, query: str, variables: dict[str, str | int]) -> dict[str, Any]:
        args = ["api", "graphql", "--input", "-"]
        payload = self.run(args, json.dumps({"query": query, "variables": variables}))
        if not isinstance(payload, dict) or not isinstance(payload.get("data"), dict):
            raise WaitError("GitHub GraphQL response is missing data")
        return payload["data"]

    def rest(self, endpoint: str, method: str = "GET", fields: dict[str, str] | None = None) -> Any:
        if method == "GET" and not fields:
            return self.get(endpoint)[0]
        args = ["api", "--method", method, endpoint]
        for key, value in (fields or {}).items():
            args.extend(["--raw-field", f"{key}={value}"])
        return self.run(args)

    def rest_pages(self, endpoint: str) -> list[Any]:
        """Every page of a REST list, following GitHub's next links."""
        pages: list[Any] = []
        following: str | None = endpoint
        while following:
            if len(pages) >= 1000:
                raise WaitError(f"more than 1000 pages of {endpoint}")
            page, following = self.get(following)
            pages.append(page)
        return pages

    def pace(self, interval: float, now: float | None = None) -> float:
        """The pause before the next observation, stretched while the core budget runs low.

        A window's allowance is CORE_SHARE of the budget above the reserve
        when this client first saw it. After an observation that spent some
        budget, the pause spreads what is left of the allowance evenly up to
        the reset, at that observation's cost. With the allowance used up or
        less than the reserve left, the next observation waits for the reset.
        An observation that cost nothing keeps the interval. A Retry-After
        GitHub sent is always honoured.
        """
        now = time.time() if now is None else now
        cost = self.spent - self.paced_spent
        self.paced_spent = self.spent
        wake = interval
        if self.retry_at is not None and self.retry_at > now:
            wake = max(wake, self.retry_at - now)
        if self.core is None or now >= self.core[1]:
            return wake
        until_reset = self.core[1] - now + 1
        if self.below_reserve(now):
            return max(wake, until_reset)
        if not cost:
            return wake
        left = self.window.get("allowance", 0) - self.window.get("spent", 0)
        if left < cost:
            return max(wake, until_reset)
        return max(wake, min(until_reset, until_reset * cost / left))


def stable_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def default_state_path(kind: str, identity: dict[str, Any]) -> Path:
    return Path(".agent/waits") / f"{kind}-{stable_digest(identity)[:12]}.json"


def load_state(path: Path | None) -> dict[str, Any] | None:
    if path is None or not path.exists():
        return None
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise WaitError(f"cannot read checkpoint {path}: {error}") from error
    if value.get("schemaVersion") != 1:
        raise WaitError(f"unsupported checkpoint schema in {path}")
    return value


def write_state(path: Path | None, value: dict[str, Any]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix="wait.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(handle, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class StateLock:
    def __init__(self, state: Path | None) -> None:
        self.path = Path(f"{state}.lock") if state else None
        self.owner = f"{os.getpid()}:{time.time_ns()}"

    @staticmethod
    def _process_exists(pid: int) -> bool:
        if os.name == "nt":
            import ctypes

            process_query_limited_information = 0x1000
            kernel32 = ctypes.windll.kernel32
            kernel32.OpenProcess.restype = ctypes.c_void_p
            handle = kernel32.OpenProcess(
                process_query_limited_information, False, pid
            )
            if not handle:
                return False
            kernel32.CloseHandle(handle)
            return True
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def __enter__(self) -> "StateLock":
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            for _attempt in range(2):
                try:
                    descriptor = os.open(
                        self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600
                    )
                    with os.fdopen(descriptor, "w") as stream:
                        stream.write(self.owner)
                        stream.write("\n")
                    break
                except FileExistsError as error:
                    try:
                        existing = self.path.read_text().strip()
                        pid = int(existing.split(":", 1)[0])
                    except (OSError, ValueError):
                        raise WaitError(
                            f"checkpoint lock is unreadable: {self.path}"
                        ) from error
                    if self._process_exists(pid):
                        raise WaitError(
                            f"checkpoint is already owned by process {pid}: {self.path}"
                        ) from error
                    try:
                        if self.path.read_text().strip() == existing:
                            self.path.unlink()
                    except FileNotFoundError:
                        pass
            else:
                raise WaitError(f"could not acquire checkpoint lock: {self.path}")
        return self

    def __exit__(self, *_: Any) -> None:
        if self.path:
            try:
                if self.path.read_text().strip() == self.owner:
                    self.path.unlink()
            except FileNotFoundError:
                pass


# How long a wait keeps going while GitHub still reports a pull request head
# that may be the one before a push, counted from the first such observation.
HEAD_GRACE = 300

# How an observed head relates to the expected one, from GitHub's comparison
# of the two. Only the relations a push can leave behind are lagging.
HEAD_RELATIONS = {
    "ahead": "ancestor",
    "behind": "descendant",
    "diverged": "diverged",
    "identical": "identical",
}
LAGGING_HEADS = {
    "ancestor": "an ancestor of the expected commit",
    "diverged": "a commit the expected one diverged from, as after a force-push",
    "missing": "while GitHub does not yet know the expected commit",
}
DIFFERENT_HEADS = {
    "descendant": "a later commit than the expected one",
    "identical": "the same commit under another name; pass the full SHA",
    "replaced": "after this wait had seen the expected head",
}


class ExpectedHead:
    """Tell a pull request head GitHub has not yet moved to a pushed commit from a different head.

    GitHub moves a pull request's head to a pushed commit some seconds after
    `git push` returns, so a wait armed at once can still see the head before
    the push: an ancestor of the expected commit, or after a force-push a
    commit it diverged from. Until the wait has seen the expected head, such
    a head is recorded as `headLag` and the wait keeps going for HEAD_GRACE
    seconds from the first lagging observation, across resumed runs. A head
    that descends from the expected commit is a later push and has no lag;
    neither has any head once the expected one was seen. The checkpoint
    keeps this state under `expectedHead`.
    """

    def __init__(self, gh: Gh, repo: str, expected: str, clock: Callable[[], float] = time.time) -> None:
        self.gh = gh
        self.repo = repo
        self.expected = expected
        self.clock = clock
        self.seen = False
        self.since: float | None = None
        self.relation = "missing"  # The last lagging relation GitHub reported.

    def resume(self, state_path: Path | None, kind: str, identity: dict[str, Any]) -> None:
        """Take over what this wait's checkpoint knows of the head, under the caller's StateLock.

        A checkpoint without `expectedHead`, such as an earlier helper's,
        counts the expected head as seen when it observed it. A digest it
        saved of another head, such as when that helper invalidated, is no
        baseline for the expected one. Another wait's checkpoint is left to
        wait_for_transition, which invalidates it.
        """
        prior = load_state(state_path)
        if not prior or prior.get("kind") != kind or prior.get("identity") != identity:
            return
        observed = (prior.get("observation") or {}).get("head")
        self.seen = self.seen or observed == self.expected
        if observed != self.expected and prior.get("digest") is not None:
            write_state(state_path, {**prior, "digest": None})

    def export(self) -> dict[str, Any]:
        """What the checkpoint keeps, so a resumed wait neither forgets the expected head nor restarts the grace."""
        return {"seen": self.seen, "since": None if self.since is None else timestamp(self.since), "relation": self.relation}

    def restore(self, saved: Any) -> None:
        if not isinstance(saved, dict):
            return
        self.seen = self.seen or saved.get("seen") is True
        if saved.get("relation") in LAGGING_HEADS:
            self.relation = saved["relation"]
        try:
            self.since = parse_time(str(saved["since"])) if saved.get("since") else self.since
        except WaitError:
            pass

    def note(self, observed: Any) -> None:
        """Record a head GitHub reported, before anything else read with it can fail."""
        if observed == self.expected:
            self.seen = True

    def compare(self, observed: str) -> str:
        try:
            compared = self.gh.rest(
                f"repos/{self.repo}/compare/{quote(observed, safe='')}...{quote(self.expected, safe='')}?per_page=1"
            )
        except (RateLimited, TransientError):
            raise
        except WaitError as error:
            if "404" in str(error) or "not found" in str(error).lower():
                return "missing"
            raise
        status = compared.get("status") if isinstance(compared, dict) else None
        if status not in HEAD_RELATIONS:
            raise WaitError(f"GitHub compared {observed} with {self.expected} as {status!r}")
        return HEAD_RELATIONS[status]

    def annotate(self, observation: dict[str, Any], fresh: bool = False) -> dict[str, Any]:
        """Record how the observed head relates to the expected one; FRESH asks GitHub even after the grace."""
        observed = observation.get("head")
        self.note(observed)
        if observed == self.expected or not isinstance(observed, str) or not observed:
            return observation
        if self.seen:
            observation["headLag"] = {"relation": "replaced"}
            return observation
        # The head was read just now; the grace is judged at that time, not
        # after a comparison that can take long. Once the grace has passed,
        # the head is judged without asking GitHub again.
        read = self.clock()
        expired = self.since is not None and read >= self.since + HEAD_GRACE
        relation = self.relation if expired and not fresh else self.compare(observed)
        lag: dict[str, Any] = {"relation": relation}
        if relation in LAGGING_HEADS:
            self.relation = relation
            self.since = read if self.since is None else self.since
            lag["since"] = timestamp(self.since)
            lag["until"] = timestamp(self.since + HEAD_GRACE)
            lag["readAt"] = timestamp(read)
        observation["headLag"] = lag
        return observation

    def grace_end(self) -> float | None:
        """When the grace of a lagging head ends, or None while no head lags."""
        return None if self.seen or self.since is None else self.since + HEAD_GRACE

    @staticmethod
    def due(observation: dict[str, Any]) -> float | None:
        """When a lagging head's grace ends, so the wait reads the head again then; None otherwise.

        A head read before the grace ended keeps the wait waiting even when
        the comparison finished after it, so a time already past asks for a
        prompt fresh read.
        """
        lag = observation.get("headLag") or {}
        if lag.get("relation") not in LAGGING_HEADS:
            return None
        return parse_time(str(lag.get("until")))


def timestamp(value: float) -> str:
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace("+00:00", "Z")


def classify_head(expected_head: str, observation: dict[str, Any]) -> tuple[str, str] | None:
    """The result for an observed head other than the expected one; None for the expected head."""
    observed = observation.get("head")
    if observed == expected_head:
        return None
    mismatch = f"expected head {expected_head}, observed {observed}"
    lag = observation.get("headLag") or {}
    relation = lag.get("relation")
    if relation in DIFFERENT_HEADS:
        return "invalidated", f"{mismatch}, {DIFFERENT_HEADS[relation]}"
    if relation == "unverified":
        return "invalidated", f"{mismatch}; GitHub could not compare them: {lag.get('error')}"
    if relation not in LAGGING_HEADS:
        return "invalidated", mismatch
    read = parse_time(str(lag["readAt"])) if lag.get("readAt") else time.time()
    if read >= parse_time(str(lag.get("until"))):
        return "invalidated", (
            f"{mismatch}: GitHub still reported a head other than the expected one "
            f"{HEAD_GRACE} seconds after the wait first saw it; check that the push reached the pull request's branch"
        )
    return "waiting", (
        f"GitHub still reports head {observed}, {LAGGING_HEADS[relation]}; "
        f"waiting until {lag.get('until')} for it to move to {expected_head}"
    )


def result_envelope(
    kind: str,
    state: str,
    identity: dict[str, Any],
    observation: dict[str, Any],
    metrics: Metrics,
    reason: str,
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "kind": kind,
        "state": state,
        "reason": reason,
        "timestamp": utc_now(),
        "identity": identity,
        "observation": observation,
        "metrics": metrics.result(),
    }


def wait_for_transition(
    *,
    kind: str,
    identity: dict[str, Any],
    observe: Callable[[], dict[str, Any]],
    classify: Callable[[dict[str, Any]], tuple[str, str]],
    state_path: Path | None,
    deadline: float,
    interval: float,
    metrics: Metrics,
    transition_key: Callable[[dict[str, Any]], Any] | None = None,
    deadline_result: tuple[str, str] = ("timed-out", "deadline reached"),
    change_precedes_terminal: bool = False,
    pace: Callable[[float], float] | None = None,
    not_before: Callable[[], float | None] | None = None,
    limits: Any = None,
    wake_by: Callable[[dict[str, Any]], float | None] | None = None,
    keep: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Observe until a transition, sleeping `pace(interval)`, or `interval`, between observations.

    `wake_by` can name an earlier time an observation must be followed up,
    such as the end of a grace period; GitHub's earliest permitted read
    still comes first. Each object in `keep` saves its state in the
    checkpoint under its key through `export` and `restore`, like `limits`.

    When pacing or `not_before`, GitHub's earliest permitted read, holds the
    next observation past the deadline, the wait ends at the deadline
    without making it. `limits`, such as the Gh client, keeps its budget
    state in the checkpoint through `export` and `restore`, so a resumed wait
    honours a hold an earlier run learned.
    """
    stopped = False
    held: float | None = None  # When the read the deadline cut off could have gone.

    def stop(_signum: int, _frame: Any) -> None:
        nonlocal stopped
        stopped = True

    def save(path: Path | None, value: dict[str, Any]) -> None:
        extra = {key: item.export() for key, item in (keep or {}).items()}
        if limits:
            extra["githubLimits"] = limits.export()
        write_state(path, {**value, **extra})

    def follow_up(observation: dict[str, Any], delay: float, retry: bool = False) -> float:
        """DELAY, shortened to an earlier time `wake_by` names for OBSERVATION.

        A time already past means at once, or for a RETRY after
        FOLLOW_UP_RETRY seconds, so a read that keeps failing cannot spin.
        """
        nonlocal held
        due = wake_by(observation) if wake_by else None
        if due is None:
            return delay
        if due <= time.time():
            due = time.time() + (min(interval, FOLLOW_UP_RETRY) if retry else 0.0)
        blocked = not_before() if not_before else None
        due = max(due, blocked or 0.0)
        if due < time.time() + delay:
            delay = max(0.0, due - time.time())
            if due < deadline:
                held = None
        return delay

    def nap(seconds: float) -> None:
        """Sleep, waking early once a signal asks the wait to stop."""
        end = time.time() + seconds
        while not stopped and end > time.time():
            time.sleep(max(0.0, min(0.5, end - time.time())))

    def pause() -> float:
        nonlocal held
        delay = pace(interval) if pace else interval
        blocked = not_before() if not_before else None
        if blocked is not None:
            delay = max(delay, blocked - time.time())
        now = time.time()
        held = None
        if now + delay >= deadline and (delay > interval or (blocked is not None and blocked >= deadline)):
            held = blocked if blocked is not None else now + delay
        return delay

    previous_handlers = {
        number: signal.signal(number, stop) for number in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        prior = load_state(state_path)
        if prior and (
            prior.get("kind") != kind or prior.get("identity") != identity
        ):
            observation = prior.get("observation", {})
            return result_envelope(
                kind,
                "invalidated",
                identity,
                observation,
                metrics,
                "checkpoint identity does not match the requested proof target",
            )
        if limits and prior:
            limits.restore(prior.get("githubLimits"))
        for key, item in (keep or {}).items():
            if prior:
                item.restore(prior.get(key))
        blocked = not_before() if not_before else None
        if blocked is not None:
            # A hold an earlier run learned comes before this run's first read.
            if blocked >= deadline:
                held = blocked
            nap(min(blocked, deadline) - time.time())
        while True:
            if stopped:
                observation = prior.get("observation", {}) if prior else {}
                result = result_envelope(kind, "cancelled", identity, observation, metrics, "interrupted")
                save(state_path, {"schemaVersion": 1, "kind": kind, "identity": identity, "observation": observation, "digest": prior.get("digest") if prior else None, "updatedAt": utc_now(), "terminalResult": result})
                return result
            if held is not None and time.time() >= deadline:
                observation = prior.get("observation", {}) if prior else {}
                at = datetime.fromtimestamp(held, timezone.utc).isoformat().replace("+00:00", "Z")
                result = result_envelope(
                    kind, deadline_result[0], identity, observation, metrics,
                    f"{deadline_result[1]}; the GitHub REST budget held the next observation until {at}",
                )
                base = prior or {"schemaVersion": 1, "kind": kind, "identity": identity, "observation": {}, "digest": None}
                save(state_path, {**base, "updatedAt": utc_now(), "terminalResult": result})
                return result
            try:
                observation = observe()
            except (RateLimited, TransientError) as error:
                metrics.retries += 1
                if time.time() >= deadline:
                    observation = prior.get("observation", {}) if prior else {}
                    result = result_envelope(
                        kind,
                        deadline_result[0],
                        identity,
                        observation,
                        metrics,
                        deadline_result[1],
                    )
                    save(
                        state_path,
                        {
                            "schemaVersion": 1,
                            "kind": kind,
                            "identity": identity,
                            "observation": observation,
                            "digest": prior.get("digest") if prior else None,
                            "updatedAt": utc_now(),
                            "connectivity": {
                                "state": "unavailable",
                                "error": str(error),
                            },
                            "terminalResult": result,
                        },
                    )
                    return result
                # A retry still looks again when the last observation asked to.
                delay = follow_up(prior.get("observation") or {} if prior else {}, pause(), retry=True)
                retry_at = min(deadline, time.time() + delay)
                save(
                    state_path,
                    {
                        "schemaVersion": 1,
                        "kind": kind,
                        "identity": identity,
                        "observation": prior.get("observation", {}) if prior else {},
                        "digest": prior.get("digest") if prior else None,
                        "updatedAt": utc_now(),
                        "connectivity": {
                            "state": "retrying",
                            "error": str(error),
                        },
                        "nextAttemptAt": datetime.fromtimestamp(
                            retry_at, timezone.utc
                        ).isoformat().replace("+00:00", "Z"),
                    },
                )
                nap(min(delay, max(0.0, deadline - time.time())))
                continue
            except WaitError:
                # What `keep` learned before the error, such as a head GitHub
                # reported, outlives it; the observation and digest stay.
                base = prior or {"schemaVersion": 1, "kind": kind, "identity": identity, "observation": {}, "digest": None}
                save(state_path, {**base, "updatedAt": utc_now()})
                raise
            metrics.observations += 1
            delay = pause()
            terminal, reason = classify(observation)
            if terminal == "waiting":
                delay = follow_up(observation, delay)
            key = transition_key(observation) if transition_key else observation
            # A key of None marks an observation with nothing to compare, such
            # as a pull request head GitHub has not moved to the pushed commit
            # yet. It is no baseline and no change either: the next comparable
            # observation sets one, and the head alone decides this one.
            digest = None if key is None else stable_digest(key)
            checkpoint = {
                "schemaVersion": 1,
                "kind": kind,
                "identity": identity,
                "observation": observation,
                "digest": digest,
                "updatedAt": utc_now(),
                "nextAttemptAt": datetime.fromtimestamp(
                    min(deadline, time.time() + delay), timezone.utc
                ).isoformat().replace("+00:00", "Z"),
                "connectivity": {"state": "connected", "error": None},
            }
            save(state_path, checkpoint)
            prior_digest = prior.get("digest") if prior else None
            changed = prior_digest is not None and digest is not None and prior_digest != digest
            if change_precedes_terminal and changed:
                result = result_envelope(kind, "changed", identity, observation, metrics, "authoritative state changed")
                checkpoint["terminalResult"] = result
                save(state_path, checkpoint)
                return result
            if terminal != "waiting":
                result = result_envelope(kind, terminal, identity, observation, metrics, reason)
                checkpoint["terminalResult"] = result
                save(state_path, checkpoint)
                return result
            if changed:
                result = result_envelope(kind, "changed", identity, observation, metrics, "authoritative state changed")
                checkpoint["terminalResult"] = result
                save(state_path, checkpoint)
                return result
            if time.time() >= deadline:
                result = result_envelope(
                    kind,
                    deadline_result[0],
                    identity,
                    observation,
                    metrics,
                    deadline_result[1],
                )
                checkpoint["terminalResult"] = result
                save(state_path, checkpoint)
                return result
            prior = checkpoint
            nap(min(delay, max(0.0, deadline - time.time())))
    finally:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)


def emit(result: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    else:
        print(f"{result['state']}: {result['reason']}")
