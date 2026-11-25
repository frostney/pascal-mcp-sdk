---
name: delivery-wait
description: >-
  Provides deterministic, resumable GitHub transition waits used internally by
  delivery workflows. Use when another workflow must await CI, merge, tag, or
  release state without model heartbeats.
license: Unlicense OR MIT
compatibility: >-
  Requires Python 3.11 or newer, the GitHub CLI (gh) authenticated to the target
  repository, and network access.
---

# Delivery wait

Run `scripts/delivery_wait.py` whenever a workflow must await external GitHub
state. The harness passively waits for the command to finish; it must not
simulate waiting with model heartbeats.

## Running a wait

Hosts limit how long one command may run, and a delivery transition can take
longer. These rules keep a wait armed for as long as the transition needs:

- If the host can run a command in the background and resume the session when
  it exits, run the wait that way. Then end the turn, or continue only work
  independent of the awaited state. If that capability is absent, use the
  fallback below; never hold the turn open with a blocking wait.
- Set each invocation's `--deadline` inside the host's limit for one command,
  and keep the time the caller gives up on the transition separately. A
  `timed-out` result before that time means: run the wait again with the same
  `--state`. That resumes one wait; it is not a heartbeat.
- Run the helper as the whole command, with nothing piped or chained after it,
  so the exit status the host reports is the helper's own. A host notice that
  the command finished says only that it ended; the result envelope says what
  happened.
- Keep one running wait per state file. Never detach a wait from the host, for
  example with `setsid`, `nohup` or `&`: a detached process cannot resume the
  session.
- Leave pacing to the helper. It keeps its own use of the account's shared
  REST budget low, as [GitHub budget](#github-budget) describes, so do not
  poll the same state beside it with `gh run list`, `gh api` or `gh pr checks`
  loops.
- While a wait runs, do not inspect the state it covers. Act on its result.

The `address-feedback` CodeRabbit adapter's `run` follows the same rules. It
keeps no state file: run it again with the same arguments, and it re-reads the
head's state from GitHub.

## Long commands and delegated lanes

Apply the same turn discipline to long builds, tests and other commands, in
coordinators and workers alike. Start commands expected to outlast a short
check through the host's tracked background execution. Keep the task or session
ID, output location, exact revision, completion condition and resume action in
the handoff. A launch acknowledgment is pending work, never passing evidence.
Short commands and bounded diagnostic checks can stay in the foreground.

Confirm that the command survives the owning lane's turn and that completion
can resume that lane or its coordinator. Some hosts stop a foreground worker's
commands when it returns; have a surviving owner start the command instead.
Respect background-command and monitor deadlines. A monitor must emit only
meaningful changes or terminal results; streaming unchanged status wakes the
model just as polling does. Keep one owner and one active wait per transition.

When only a command, worker or external transition remains, record the pending
state and end the turn. Continue independent work while it runs, then inspect
the returned exit status and result before resuming dependent work. Do not use
foreground `gh pr checks --watch`, sleep loops, repeated `gh pr view`, or
repeated output/status reads to keep a lane alive. A worker with pending work
returns its handle and next transition to its coordinator, not a completion
claim; do not create another worker just to poll it. A coordinator that
receives a report saying work is still running treats it as pending, not as the
lane's result: it takes over the wait and keeps its own wake for the final
result. If the host does not guarantee a later notification, it continues the
work in a new task round or uses the fallback below.

A closing message that names a pending transition is a park, not a finish. Before
ending the turn, check each one against a wake this agent armed that is still
live: a tracked background command, a host PR watch where the host's rules allow
one, or a delegated task that will report back. Otherwise hand it to the person
explicitly as theirs to do. Do not promise to follow work that cannot wake this
session, such as another top-level thread, another machine or another person's
session, unless a tracked wait covers it; hand it over, or use the fallback
below with a stated check time. Prefer a tracked `delivery-wait` command for
CI, check and review transitions over timer-based wakeups; a host PR watch may
complement it.

If the host cannot notify or resume the owner, make one bounded status check,
record the missing capability and an explicit next check time or event, and
return pending. Use the caller's cadence when given; otherwise check no sooner
than five minutes later, with a transition deadline. Each resumed turn checks
once and parks again if unchanged. This is a fallback only: do not replace a
working notification path with scheduled polling. If commands cannot survive a
turn at all, return the required execution capability to the caller rather than
launching an untracked process or claiming the check ran.

## Inputs

The caller supplies the repository, expected identity, absolute deadline, and
an optional state path. The command reconciles any saved state with fresh
GitHub state, waits while nothing relevant changes, and exits with one result.
Use `--json` from workflow skills; human output is for direct terminal use.
Skills default state files beneath `.agent/waits/`, which the consuming
repository must gitignore; another harness may supply any private state path
through `--state`.

## Invocation

The first argument is the operation, `wait` or `inspect`, and the kind follows
it. A kind alone, such as `delivery_wait.py checks-terminal`, is rejected. The
path is relative to this skill directory, and the helper runs the same with or
without `python3 -I`:

```sh
python3 scripts/delivery_wait.py wait checks-terminal --repo <owner/repo> \
  --pr <number> --head <sha> --all-workflows \
  --deadline <ISO 8601> --json
```

`wait <kind> --repo <owner/repo> --deadline <ISO 8601> [--interval <seconds>]
[--state <path>] [--json]` runs a wait; `inspect <kind>` takes the
same identity flags without `--deadline`, `--interval`, or `--state`. Each kind
requires its own identity flags, which `--help` also lists:

- `checks-terminal`: `--head <sha>`, and `--all-workflows`, one
  `--check <name>` per expected check context, or both. A run with neither
  exits with an operational error instead of waiting. With `--pr <number>` it
  waits on that pull request's head. Without `--pr` it waits on the commit
  itself, such as a merge commit on the default branch after a merge:
  `--head` is then the full commit SHA, which `pr-merged` reports as
  `mergeCommit`, and `--check` reads that commit's own checks and statuses.
  A commit has no head to move, so the head-lag rules below do not apply.
  - `--all-workflows` needs no check names. It finds every GitHub Actions
    workflow run for the exact head and every job in each run's latest attempt.
    Of several runs of one workflow for the same event, only the newest
    counts, as for GitHub's own merge checks: GitHub numbers runs and check
    suites in creation order, whichever run was cancelled. An older run is
    reported with `superseded` and decides nothing.
    It waits while there is no run, or while any run or job is queued, in
    progress, waiting, pending or requested. It reports `changed` as soon as a
    run or job ends in failure, cancelled, timed out, action required or
    another non-success conclusion, except a cancelled duplicate run, below.
    It reports `satisfied` only when every run
    and job succeeded, was skipped or was neutral, and two consecutive
    observations one interval apart show the same runs, jobs and named checks. Jobs added by later
    matrix or `needs` stages keep their run in progress. A run started after
    another run finishes shows up in the second observation. `inspect` cannot
    confirm a stable census, so it reports `waiting` instead of `satisfied` for
    an all-success snapshot.
  - One event can start two runs of a workflow on the same head, and a
    `concurrency` group with `cancel-in-progress` cancels whichever joined it
    first, which can be the newer run. GitHub then counts that cancelled run
    and blocks merging, although the older run passed. The wait marks such a
    newest run with `cancelledDuplicate` instead of counting it as a failure
    when it raced the older run: both come from the same branch of the same
    repository and, where GitHub names their pull requests, belong to this
    one (without `--pr`, where both name pull requests, they share one), the
    older run, on its first attempt, had started before the
    newer one was cancelled and was still running then, and no job of the
    cancelled run failed another way. While that older run has not finished,
    the wait waits for it. Once it has passed and every other run on the
    head has finished, so that a rerun cannot cancel a workflow sharing its
    concurrency group, the wait reports `recoverable` after the same two
    identical observations that `satisfied` needs, unless another run,
    job or named check failed, which is `changed`. A cancelled newest run
    beside only failed older runs is an ordinary failure, and so is one
    cancelled after the older run finished, one with a failed job and one
    cancelled again after its rerun. A cancelled named check left from an
    earlier attempt, of a rerun that has not finished or that passed with a
    job of that name, waits for that run's jobs. A cancelled job or named
    check of a first attempt that has an older run of its source waits for
    its run to complete. `inspect` reports a cancelled duplicate as `waiting`, naming
    the rerun.
  - A run whose event GitHub records on the default branch's latest commit,
    whatever started it, says nothing about that commit: `repository_dispatch`,
    `workflow_run`, `schedule`, `check_run`, `check_suite`, `status`, and
    activity on issues, comments, labels, discussions and the repository.
    After a merge, these arrive on the merge commit from other work, such as a
    deployment gate dispatched for an earlier commit or another pull
    request's chained build. `--all-workflows` lists them under `unboundRuns`
    without reading their jobs, and they decide nothing, and neither do their
    check runs, even under a `--check` name; a commit status still counts.
    While one is still running, a cancelled duplicate is not yet
    `recoverable`, since a rerun could cancel it. To await one that is yours,
    such as the gate dispatched for your own deployment, find it from its own
    record and wait on it with `workflow-terminal`, or name the commit status
    it posts on your commit with `--check`. A `pull_request_target` run is
    recorded on the pull request's head and counts.
  - `--all-workflows` does not cover commit statuses or check runs from other
    apps, such as CodeRabbit or Vercel. Add a `--check` for each one the caller
    needs; the wait then also requires those contexts to succeed.
  - A named check passes when it ends in success, skipped or neutral. The wait
    reports `changed` as soon as one named check ends any other way, even
    while the rest still run. Check runs that share a name count once per
    source: their app and, for GitHub Actions, their workflow and triggering
    event. A workflow that runs on both `push` and `pull_request` therefore
    needs both runs to pass. From one source only the newest check suite
    counts, so a re-run, a run cancelled by a newer one or a re-check after an
    edit replaces the older run, whichever started first. A commit status
    counts by its latest state. Telling a cancelled duplicate run from a
    cancelled check needs the run census, so only `--all-workflows` reports
    it as `recoverable`; with `--all-workflows`, a named check from that run
    fails with it.
  - `--check` alone judges only the named contexts, whatever else is still
    running for the head. Use it only when the complete expected set is known,
    such as the repository's required status checks. Checks visible at wait
    time are not that set: workflows add jobs in stages.
- `pr-merged`: `--pr <number>` and `--head <sha>`. It reports `changed` when
  the pull request is closed without merging.
- `workflow-terminal`: `--run-id <id>`. Use it for a dispatched or other run
  whose checks do not appear on the pull request. A run keeps its commit, so
  `--head <sha>` is optional: given, it reports `invalidated` when the run is
  for another commit.
- `tag-target`: `--tag <name>` and `--head <sha>`.
- `release-assets`: `--tag <name>`, `--head <sha>`, and one `--asset <name>` per
  required asset.
- `wake-at` (`wait` only): `--deadline` alone. It keeps no state file, so
  `--state` has no effect.

There is no `--checkpoint` flag. The state path is `--state`, and the command
derives a default path from the kind and identity when it is omitted.

Both `inspect` and `wait` accept `--rest-page-size <1..100>` (default: 100).
Use a smaller value when GitHub fails to serve large REST pages. It applies
to workflow runs, jobs, and the REST fallback for checks and statuses. All
pages are still read and the complete workflow census is still required.
The option does not change GraphQL queries or the saved wait identity, so
an existing wait can resume with a different REST page size.

## Results

`--json` prints one envelope whose `state` is the result. Only `satisfied`
establishes the awaited fact. `changed` means a check or workflow reached a
non-success terminal result or other relevant state moved; inspect it before
deciding. `recoverable`, from `checks-terminal --all-workflows`, means a run
is a cancelled duplicate whose older run passed, nothing else has failed and
no other run on the head is still running. Each such run's
`cancelledDuplicate.rerun` holds the `gh run rerun` command that replaces its
result. Run one, wait again on the same head, and run the next one the new
result names: reruns that share a concurrency group would cancel each other.
If `gh run rerun` reports that the run is already running, the rerun was
accepted; wait again. The wait sees only the head's own runs, so a group that
spans other branches can still lose a run elsewhere to the rerun. A rerun
retries the same commit; it is never a reason to bypass a required check or
merge protection. `invalidated` means the
expected head, ref, or saved identity no longer matches, `timed-out` means the
deadline passed, and `cancelled` means the wait was interrupted. These exit 0;
`operational-error` exits 2. `inspect` can also report `waiting`.

GitHub moves a pull request's head to a pushed commit some seconds after
`git push` returns, so `checks-terminal` and `pr-merged` can be armed right
after a push, and so can `address-feedback`'s review wait and CodeRabbit
`run`. Until the wait has seen the expected head, a head that is an
ancestor of it, one it diverged from as after a force-push, or any head while
GitHub does not yet know the expected commit is recorded as `headLag` and
keeps the wait `waiting` for five minutes from the first such observation,
across runs on the same `--state`. The wait looks again when the five minutes
end, whatever `--interval` is, unless GitHub's limits hold the read. A head
that descends from the expected commit is a later push and reports
`invalidated` at once, and so does any other head once the wait has seen the
expected one, which the state file keeps, or once the five minutes have
passed: then check that the push reached the pull request's branch. The
CodeRabbit `run` keeps no state file, so its five minutes start with each
run, and it posts no trigger while it waits for the head; on a closed pull
request it reports `closed` instead, unless the head is a later commit.

Use `inspect` for a single authoritative delivery snapshot and `wait` to
await a transition. Supported predicates are exact-head checks,
pull-request merge, workflow completion, tag target, release assets, and an
absolute wake time. A changed expected head or ref invalidates the wait instead
of being followed silently. GitHub remains authoritative; checkpoints contain
normalized identities and observations, no credentials, raw comment bodies, or
raw API payloads.

The helper uses authenticated `gh` transport. GraphQL is primary. A REST
fallback is used only when GraphQL is rate-limited and REST preserves the same
fact, or when GitHub exposes the fact only through REST.

## GitHub budget

Every agent and person signed in to one GitHub account shares its hourly REST
budget of 5,000 requests, and the publication guard and reviews need some of
it. A workflow census reads the head's runs and each run's jobs through REST,
so the helper keeps that use low:

- Each REST read repeats the ETag of its last answer. GitHub answers an
  unchanged resource with 304 Not Modified, which its rate limit does not
  count, so runs that sit in a queue cost next to nothing after the first
  observation. `metrics.notModified` counts these reads.
- Each REST answer reports how much of the budget is left. A wait's
  allowance in each hourly window is a quarter of what was left above 1,000
  when it first saw that window. After an observation that spent budget, the
  wait stretches `--interval` to spread the rest of its allowance evenly up to
  the reset. The allowance is checked between observations, so one
  observation can go past it. Once the allowance is used up, the wait reads
  nothing more until the reset. With fewer than 1,000 requests left it makes
  no REST read at all until the reset, not even the next page of a census. Several waits on one account therefore slow each other
  down instead of emptying the budget. An observation that spent nothing
  keeps `--interval`.
- A rate-limited read, including a 429 or a secondary limit, retries after
  the reset or the `Retry-After` GitHub gives, or a minute later when a
  secondary limit names no time, rather than every `--interval`. When that falls after `--deadline`, the wait ends at the
  deadline without another read and names the time in its reason. The
  checkpoint keeps that time and the window's allowance under
  `githubLimits`, so a wait run again with the same `--state` honours them
  before its first read.
- The reserve is 1,000, or a fifth of a smaller budget such as a GitHub
  Actions token's 1,000 an hour.
- `inspect` takes its one snapshot even below the reserve.

The checkpoint's `nextAttemptAt` shows when the next observation is due.
