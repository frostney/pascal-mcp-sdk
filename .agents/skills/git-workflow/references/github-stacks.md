# Native GitHub stacks

Use GitHub's official `gh stack` extension and native pull-request stack
topology. Branch names, labels, PR base branches, and delivery automation are
routing evidence, not proof of stack membership.

## When to start a stack

Publish a change as a native stack when it builds on an open, unmerged PR, as
[create-pr](../../create-pr/SKILL.md) step 1 defines and detects. A PR whose base
is set by hand to another PR's branch keeps that PR's commits after the lower PR
is squash-merged and conflicts with the base; `gh stack sync` handles that
transition for a native stack.

- When several open PRs match, the lower PR is the one sharing the most commits
  with this branch and, among equals, the one with the fewest commits above the
  remote default. Stop and report the topology when that leaves a tie.
- If the lower PR is the top layer of a native stack, publish the change as its
  new top layer under "Submit, validate, and merge" below. If it is a lower
  layer, stop and report the topology: the change would depend on the layers
  above it.
- Otherwise the lower PR must be based on the remote default with auto-merge
  disabled; stop and report any other base or auto-merge state. For an
  unstacked PR, `gh stack submit` retargets it onto the trunk and disables its
  auto-merge, and `gh stack link` retargets it onto the default branch and
  refuses it with auto-merge enabled. Require the local lower branch to match
  that PR's remote head and this branch to contain it; if the lower PR has
  moved on, merge its branch into this branch first. Then adopt both branches
  bottom to top with `gh stack init LOWER-BRANCH BRANCH`, which changes only
  local state, and publish this branch as
  [Open a layer's pull request](#open-a-layers-pull-request) describes: its
  stack step creates the stack from both PR numbers, which leaves the lower
  PR's commits, base and body as they are, so it also serves a lower PR that
  must stay frozen, for example because it is approved.

Joining a stack does not authorize changing the lower PR's commits, base or
metadata. Fast-forward the local default branch before `init`, and never sync
or rebase an adopted lower branch while its PR is open.

## Establish the stack

1. Require a clean worktree. Resolve and fetch the remote default branch, then
   record its exact remote head.
2. Verify that `gh stack` is installed and authenticated. Inspect local state
   with `gh stack view --json`; for existing PRs, also read GitHub's native
   `PullRequest.stack` and `stackEntry` data.
3. Before `gh stack init`, account for a stale local trunk: the extension uses
   the local default branch even when a detached checkout points at the fetched
   remote tip. Immediately verify the initialized bottom layer against the
   recorded remote-default head. If it is stale, perform the guarded sync below
   before editing; stop if the trunk or topology cannot be reconciled safely.
4. Use `gh stack init` for the first layer and `gh stack add` for later layers.
   Preserve bottom-to-top dependency order. When layers are independent, place
   the layer that shrinks the gate first; every layer above it pays the gate on
   each push. An empty new layer can omit `head` in `gh stack view --json`;
   resolve its actual local Git ref, and cross-check any head the extension
   does report. Do not manually imitate a native stack by changing PR bases alone.

## Guarded rewrite exception

`gh stack sync`, `gh stack rebase`, and `gh stack push` may cascade-rebase and
push with force-with-lease. They are allowed only when all of these are true:

- the worktree is clean before the operation;
- `gh stack view --json` confirms the intended local branches and order;
- GitHub native topology, when PRs exist, agrees with the intended stack;
- the current remote head of every affected branch is recorded first;
- no unrelated branch or worktree is in scope; and
- the cascade's CI load is accepted: a sync re-fires CI for every rebased layer
  at once, which on a seven-layer stack meant about 25 concurrent jobs and
  flaked two surfaces. Place each fix as `address-feedback`'s
  [stack step 7](../../address-feedback/references/stack.md#review-rounds)
  says: in place on a layer that is not frozen with no frozen layer above it,
  on the top fix layer while that is not frozen, and otherwise in a new top
  layer; after a sync, rerun flaked surfaces one at a time.

A stack, like any PR branch, need not be up to date with its trunk: sync it
onto a moved trunk only under `git-workflow`'s
[up-to-date rule](../SKILL.md#update-commit-and-push). A squash-merged lower
layer leaves the layers above it conflicting with the base, so they sync.

While the layers have open PRs, rewrite them at most once, immediately before
merging the whole stack, and only when that rule calls for it. A conflict that
appears earlier waits for that rebase; it never justifies re-pushing reviewed
layers. `address-feedback`'s [frozen
rule](../../address-feedback/references/stack-readiness.md#frozen-members-and-invalidation)
decides which layers are frozen: a draft whose CI failed, was cancelled, is
still running or never ran is not. A repair on a layer that is not frozen is not
such a rewrite: commit it on that layer and, when layers sit above it, restack
only those with `gh stack rebase --upstack --no-trunk` run from the repaired
branch, so the layers below it and the trunk stay where they are. Check that
every layer below it kept its recorded remote head, validate the restacked top,
then push through the [protected publication
helper](#protected-publication-helper) with each moved branch admitted. By
default the helper lets the push through only while no layer it moves is ready
for review or a draft whose CI passed; a draft whose CI passed while its review
has not finished, or another of whose checks has not passed, moves under a
`draftOnly` entry, as [that helper's
section](#protected-publication-helper) says, and nothing else goes under
`rewrite`. For the final rebase, rebase locally with `gh stack rebase`, then
push through the [protected publication helper](#protected-publication-helper)
with every member listed under `rewrite`. Every rewritten layer reruns its CI
once and needs its readiness again on the new head. Only the layer-by-layer
merge fallback below and a retargeted stack rewrite again, the same way. `gh
stack sync` pushes on its own, outside the helper, so use it only while no layer
has an open PR.

When a stack's base branch is deleted, GitHub retargets the stack onto the
default branch. From gh-stack 0.3.0, `gh stack push` and `gh stack submit`
refuse to publish it, even a new top layer, until it is rebased; they suggest
`gh stack sync`. With open PRs, run `gh stack rebase`, which from 0.3.0 moves
the layers onto the new base, then push through the helper with every member
under `rewrite`, naming the retarget as the reason. Stop when the rebase asks
before dropping commits of an old base that never merged.

Run the narrowest official command that satisfies the need. Stop on a rebase
conflict, unexpected divergence, changed topology, lease rejection, partial
push, or remote head that cannot be explained. Use `gh stack rebase --abort`
when the extension offers restoration; never resolve ambiguity by invoking raw
rebase or force-push commands.

Ordinary branches never inherit this exception. When that rule calls for an
update, merge the freshly fetched remote base and push normally.

## Submit, validate, and merge

- Run the [publication guard](../SKILL.md#publication-guard) before every stack
  push and every PR title or body write, including each layer's
  `gh pr create`.
- Bind GitHub API and CLI calls to the verified host and repository, including
  child helpers. `gh api --hostname HOST` selects the API host; inherited
  `GH_HOST` and `GH_REPO` can otherwise alter command defaults. A Git remote or
  push guard alone does not bind API requests. Set target overrides only for
  the scoped subprocess, preserving the user's saved login configuration.
  See [GitHub CLI environment settings](https://cli.github.com/manual/gh_help_environment).
- Preserve approved heads at the actual push boundary. A prior remote read or
  the presence of `--force-with-lease` alone is insufficient: `gh stack submit`
  in [gh-stack 0.3.0](https://github.com/github/gh-stack/blob/v0.3.0/cmd/submit.go)
  refreshes tracking refs before constructing its leases. For frozen layers,
  require both the queued source and advertised remote head to match the
  approved commit; require remote absence for a new branch. An enforced
  [pre-push check](https://git-scm.com/docs/githooks#_pre_push) can reject a
  mismatch before updates are sent while retaining existing hooks. A later
  remote update must still be rejected by Git's receive-side comparison.
  Use the bundled helper described below to enforce this constraint; it keeps
  existing hooks and does not change persistent Git configuration.
- For a new top layer above frozen PRs, approved or not, use protected `gh stack push`,
  then open its PR and append it as
  [Open a layer's pull request](#open-a-layers-pull-request) describes. Admit each frozen
  member with equal source and expected IDs and the new layer as absent: that
  push moves no PR head, so it needs no `rewrite` entry. Record successful push
  completion and re-read the exact remote heads before creation. The native push
  refreshes tracking leases first, so the guard must enforce the admitted
  source and expected remote IDs. From gh-stack 0.3.0 it updates every branch
  or none, unless `GH_STACK_NO_ATOMIC` is set; leave it unset. Earlier releases
  update each branch on its own. It performs no PR creation or base updates. A
  partial or uncertain push requires stopped ownership and fresh reconciliation
  before advancing.
- Check each frozen PR's full metadata as well as its head: its base branch and
  base commit must match the approved previous layer (or the stack's trunk for
  the bottom PR), and auto-merge must be disabled while the required overlay is
  incomplete. Missing metadata is not evidence of a safe state. If two reads
  disagree during inspection, discard that observation and reassess before a
  write. Stable reads do not make subsequent GitHub mutations atomic.
- `gh stack submit` is the extension's combined command. Its Git guard does
  not constrain later PR metadata writes, and it finds each layer's PR by
  branch name and opens one when it finds none, with the template unfilled
  under `--auto`, the only form the protected helper runs, so
  never use it to publish a layer: push, open and join every new layer as
  [Open a layer's pull request](#open-a-layers-pull-request) describes. Check
  every PR's title, body, base, draft state and linked requirements after
  publication, and check each layer's observed validation. Put a closing
  keyword only on the layer that completes the issue.
- Treat every layer as a real PR. Validate its exact head and review its own
  claim; do not let evidence from one layer stand in for another.
- `/address-feedback` is the explicit review exception for a whole native
  stack. It may freeze a layer whose exact-head CI passed and whose review is
  terminal, and cover a validated live finding on it with a later top fix
  layer. A covered lower layer is not independently
  merge-ready: the required overlay and every layer beneath it form one
  indivisible ready stack.
- Before merging, re-read native topology and exact remote heads. Merge every
  ready layer in one go with `gh stack merge NUMBER --squash --yes`: NUMBER is
  the stack number when the whole stack is ready, otherwise the highest PR of
  the ready prefix. GitHub merges every layer up to it in one all-or-nothing
  operation, or adds them to the base's merge queue when it has one. gh-stack
  reads a bare number as a stack number first, so pass a PR number only after
  `gh api repos/OWNER/REPO/stacks/NUMBER` answers 404, showing that no stack
  has that number. Never merge ready layers one at a
  time, and never wait for the base branch's push CI between layers. A prefix
  is ready only when every PR in it independently satisfies its current-head
  checks, review, and readiness gates. When `/address-feedback` supplied whole-stack readiness,
  select the complete reported stack only after its final membership audit
  still matches; never merge a prefix beneath its top overlays. Never select
  rebase-merge merely because stack maintenance used rebases.
- When `gh stack merge` refuses because required status checks have not
  succeeded, or a layer's `mergeStateStatus` is `BLOCKED` although its checks
  looked green, run `delivery-wait`'s `wait checks-terminal` on each layer's
  exact head with the same `--all-workflows` and `--check` set its readiness
  used. `recoverable` means GitHub counts a cancelled duplicate run on that
  head in place of an older run that passed. Rerun a run the result names
  with its `gh run rerun` command and wait again with that set on the
  unchanged head, one rerun at a time until the wait is satisfied, then
  retry the same merge. A run someone cancelled by hand while the older run
  was going looks the same; rerunning it is a retry of the same commit and
  needs no decision. Rerunning any other run does not help: GitHub counts
  the newest check suite of each workflow and event, so only a rerun of that
  cancelled run replaces its result. This refusal is a readiness gate: it
  never justifies the layer fallback below, an administrator merge or any
  other bypass of the repository's protections. Handle any other result as
  that result.
- A stack merges whole. Before merging a prefix, count the layers above it:
  the squash merge leaves each of them conflicting with the base, so each
  needs the rebase, a CI run and its readiness again. Merge a prefix only when
  the request names that part of the stack, or after the person decides it
  from that count and cost. A request that names one PR without its stack has
  not weighed them: bring the PR to ready, then ask, giving the number of
  layers above and what the merge forces on them. A layer that is ready sooner
  than the layers above it is no reason to merge it sooner.
- Fall back to layers only when `gh stack merge` is unavailable, the prefix's
  top PR number also names a stack, or GitHub refuses the stack merge for a
  reason other than a readiness gate. Then squash-merge the bottom ready
  layer, move the layers above it onto the updated base with `gh stack rebase`
  and a helper push that lists them under `rewrite`, as
  [Guarded rewrite exception](#guarded-rewrite-exception) describes, and merge
  the next layer as soon as its new head is ready;
  repeat up the prefix. Report the reason for the fallback.
- After merge, use the official stack cleanup/sync path, remove the clean local
  branches the run owns that no worktree holds,
  [remove merged worktrees](../SKILL.md#remove-merged-worktrees) with their
  branches, and verify the integrated remote default.

## Protected publication helper

Use [scripts/stack_push_guard.py](../scripts/stack_push_guard.py) from this
installed skill. It requires Python 3.11+, Git, a POSIX shell, and the official
gh-stack extension. It checks that `gh stack --version` identifies gh-stack, not
which version; this page describes the latest release, checked at 0.3.0. It has
no third-party Python or eval-harness dependency. Existing authorization and
native-topology checks still apply.

After validating the local commits and reading the exact remote heads, write
an admission JSON file outside the worktree's tracked/untracked files. It has
`directory` (the physical absolute checkout path), `remote`, `url` (the observed
push URL), and `refs`. Each entry of `refs` has exactly the keys `ref`, the
fully qualified `refs/heads/...` branch; `source`, the approved local commit;
and `expected`, the previously approved remote commit:

```json
{"directory": "/abs/checkout", "remote": "origin", "url": "<push URL>",
 "refs": [{"ref": "refs/heads/<branch>", "source": "<commit>", "expected": "<commit>"}]}
```

The helper refuses an object with any other key and names each key that is
unexpected or missing. Use all-zero object IDs of the repository's object format
only for branches verified absent remotely. Frozen members have equal source
and expected IDs. Include every branch the native command may push; never
refresh an approved expectation, or list a ref under `rewrite`, merely to make
a rejection pass.

Before any push, the helper looks up the open PR of each admitted ref whose
remote head would change, in the repository the remote URL names.
`address-feedback`'s [frozen
rule](../../address-feedback/references/stack-readiness.md#frozen-members-and-invalidation)
decides which layers are frozen. It needs a terminal review with its findings
classified, and it counts every check on the head as the PR gate does, while the
helper sees only GitHub Actions runs and no reviews. So by default the helper
refuses to move a PR that is ready for review, or a draft whose GitHub Actions
CI on its current head has passed. Passed means the newest run of every workflow
and event there finished successful, neutral or skipped; as in `delivery-wait`,
a newer run of a workflow and event replaces an older one, whether the older one
passed, failed or is still going. A newest run that was cancelled has not
passed, even beside an older passed run: the PR gate does not count that head
green until the run is rerun. A run list too long to read in full cannot show
which run decides, so the helper refuses a draft with one. A draft with no runs,
or whose deciding runs failed, were cancelled or are still queued or in
progress, may move: the helper reads it as not frozen. That reading covers
Actions only; a draft whose only checks come from other apps reads as having no
runs, so apply the frozen rule before admitting it. The prepared record gives
each such PR's CI state (`none`, `failed` or `running`) and the reason it may
move. For runs still going, the helper names the pull request runs on the old
head; once the push lands, cancel any that the workflow's concurrency group did
not, since their result would be for a head the PR no longer has. Moving a layer
also moves every layer above it and restarts their CI, so a fix in place on a
low layer can cost more runs than a new top layer; that cost never makes a layer
frozen. The refusal names each blocked PR, how many would have CI restarted, and
what to do: place a fix for a frozen layer as step 7 says.

The optional `rewrite` field lists refs allowed past the default check, as
`[{"ref": "refs/heads/...", "reason": "...", "draftOnly": true}]`: each an
admitted ref with a non-empty reason, and `draftOnly` only when it applies.

- With `"draftOnly": true`, the entry lets a draft whose Actions CI passed take
  its fix in place when the frozen rule does not freeze it: its review has not
  finished, or another check on its head failed or has not finished. Check that
  state again immediately before the push, and name it as the reason; if the
  draft has frozen meanwhile, place the fix again under step 7. The helper still
  looks that ref up when it prepares and at the push, and refuses it if any open
  PR on it is ready for review.
- Without it, the entry skips the check for that ref. Use it only for the
  rewrites the [Guarded rewrite exception](#guarded-rewrite-exception) allows:
  the final rebase before merging the whole stack, the layer-by-layer merge
  fallback, and a retargeted stack.

Never use either to put a fix into a frozen layer. The lookup needs `gh` signed
in to the remote's host; a missing `gh` or a failed lookup refuses. It reads
through REST. When GitHub refuses a REST read for a rate limit, the account's
hourly REST budget or a secondary limit, it asks GraphQL, which has a primary
budget of its own, for the same answer: the repository, its open PRs from the
same owner on the branch, and the GitHub Actions runs from the head's check
suites. Other apps' check suites do not count, and an Actions suite without its
run refuses. When GraphQL refuses too, the lookup has failed. A branch admitted
as absent
needs no lookup, and the hook rejects it if the remote already has it. The
helper checks when it prepares and the hook checks again at the push, with the
same rules, so a PR marked ready in between is still refused.

Run the authorized frozen-top push through the helper, using its actual installed
path and the chosen remote name:

```sh
python3 /path/to/git-workflow/scripts/stack_push_guard.py run \
  --admission /path/to/approved-stack.json -- \
  gh stack push --remote origin
```

For an observed partial publication, first reconcile native topology, branch
heads, candidate PRs, prior operation receipts and stopped ownership. Use the
creation and append steps below for recovery. The wrapper retains
support for native link commands, but its Git hook does not prevent their PR-base
changes. This helper guards Git updates; it
does not deduplicate GitHub requests or authorize retrying an uncertain command.

It accepts `gh stack link NUMBER BRANCH-OR-PR... --remote REMOTE`: a stack or PR
number, then one or more PR numbers or admitted branches, each listed once. A
branch argument may not start with `-` or read as a number, because link would
take it for a flag or try it as a PR number first. A first number that names a
stack and is not also a local branch name appends the rest to the stack's top.
Otherwise list every PR the stack already holds, bottom to top, or link refuses
to drop them. Link pushes only the arguments that name local branches and opens
a draft PR for each branch without one, with the template unfilled, which is
why [Open a layer's pull request](#open-a-layers-pull-request) joins new
layers through the native endpoints instead. It then moves each existing PR's base
onto the PR below it, and the bottom one onto the default branch, or onto the
stack's top when appending; a refused base change only warns. Check every PR's
base and the stack again afterwards.

Each invocation freezes the helper, records its Python runtime, admission and
the PRs it looked up, and keeps hook receipts under the checkout's Git
directory in `kgr-push-guards`. The final command reports that directory. Retain it for reconciliation. A
successful exit establishes command execution only; re-read GitHub and apply
the full PR/stack readiness contract. A rejected push leaves the prepared work
available and requires fresh scope/evidence assessment.

The helper also accepts `gh stack submit --auto --remote REMOTE` for its combined
workflow and legacy diagnostics. Neither command's successful exit establishes
PR creation or readiness. Keep each subsequent API phase's intent and executor
record separately; saved completion alone does not authorize a second live caller.

Programmatic callers can use `prepare --admission FILE` (or `-` for stdin) to
obtain a guard directory and only the new Git configuration fields. Merge those
fields into the child process environment at creation. Do not change a running
worker's environment and assume its children receive the update, and do not
disable or replace the supplied hook when launching the native command.

## Open a layer's pull request

Open each new layer's PR with its complete title and body, media included, in
one write. `gh stack submit --auto` and `gh stack link` open a PR for a branch
without one with the template unfilled, and neither they nor `gh api .../pulls`
can attach media, so each would leave the PR without its body until a second
write. A repository check that validates the body when a PR is opened then
fails its first run.

1. Before pushing, check that the repository answers
   `gh api repos/OWNER/REPO/stacks` and that the PR below, when there is one,
   is open or draft, not queued for merge and without auto-merge, as a stack
   requires. A layer opened where no stack can take it is a PR whose base is
   set by hand to another PR's branch.
2. Push the branch through the
   [protected publication helper](#protected-publication-helper) with
   `gh stack push --remote REMOTE`, admitting each branch as that section
   says: a member the push does not move with equal source and expected IDs,
   and each new branch as absent. Record the push's completion and re-read
   the exact remote heads.
3. Claim the creation once. Write the title and body files, run the
   [publication guard](../SKILL.md#publication-guard) on them, then, from the
   repository root, run
   `gh pr create --repo HOST/OWNER/REPO --draft --head BRANCH --base BASE-BRANCH --title TITLE --body-file FILE`,
   where BASE-BRANCH is the head branch of the PR directly below, or the
   stack's trunk for a bottom layer. Add `--attach PATH` for each media file
   as [PR media](../../create-pr/references/walkthroughs.md#upload-media)
   describes. With `--head`, gh pushes nothing: it names the branch already on
   the remote and creates no PR when the branch is not there. It refuses when
   an open PR for that head and base already exists.
4. Read the full PR: number, head branch and commit, base branch and base
   commit, draft and open state, auto-merge, and a body that matches the
   checked file with each media reference pointing at its upload. A non-zero
   exit or a lost response leaves creation uncertain: once the command has
   stopped, read GitHub for a PR on that head before anything else, and never
   run the creation again while one may exist. A failed upload can still
   create the PR; complete its body as PR media says.
5. Open every new layer first, bottom to top, then run this step once, with
   every approved new PR open. Read the full PRs again and look up the native
   stack of each new PR and of the PR below the lowest one with
   `gh api 'repos/OWNER/REPO/stacks?pull_request=NUMBER'`. Then join by the
   topology you observe, naming exact PR numbers bottom to top. Judge the join
   by the first unjoined PR: the lowest new PR that is in no stack, and the
   PR directly below it. Normally the first unjoined PR is the lowest new PR.
   After a lost response it can be a higher one, whose PR below is then a
   new PR already in a stack:
   - **Every new PR is already in a stack** whose order, heads and bases match
     the approved layers, as after an earlier request whose response was lost:
     adopt that stack and send no request. Any other membership is a conflict,
     such as new PRs split across stacks or a stack that does not match the
     approved order: stop and reconcile. A stack that holds only the lower new
     PRs, in the approved order, is not a conflict: its next new PR is the
     first unjoined PR, handled by the bullets below.
   - **The PR below the first unjoined PR is the top of a native stack:**
     append the first unjoined PR and every new PR above it in one request,
     bottom to top, through the endpoint in
     [Recover a partial publication](#recover-a-partial-publication). For
     native stack `[120, 121]` and new PRs `122` (based on `121`'s branch) and
     `123` (based on `122`'s branch), the body is
     `{"pull_requests":[122,123]}`; with `122` already in the stack, it is
     `{"pull_requests":[123]}`.
   - **The PR below the first unjoined PR is in a native stack but not its
     top:** stop. Another layer took its place, so the approved dependency no
     longer holds.
   - **The PR below the first unjoined PR and the chain under it are in no
     stack**, and each is eligible as step 1 says: create the stack through
     GitHub's
     [create endpoint](https://docs.github.com/en/rest/pulls/stacks#create-a-pull-request-stack).
     Write every PR number of the chain, new PRs included, bottom to top as
     integers in a JSON body, for example `{"pull_requests":[120,122,123]}`,
     and run
     `gh api --method POST repos/OWNER/REPO/stacks -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' --input /path/to/create.json`.
   - **No PR below the first unjoined PR:** it is a bottom layer on the trunk.
     With one new layer, a stack needs at least two PRs, so it stays a
     standalone PR and no request is sent; the next layer's step 5 creates the
     stack with both, and step 6 is skipped. With several, create the stack
     from all the new PRs, bottom to top.

   Both requests require each PR's base to be the head branch of the PR below
   and change no base. Without `--base`, `gh stack link` instead takes its
   bottom base from the local `origin/HEAD`, and it may retarget the lower PR
   before creating the stack; `gh stack submit` finds each layer's PR by
   branch name and opens a new one when it finds none. For several new layers,
   push once through the protected helper before opening them, so one request
   names them all. On a conflict, validation error or lost response, keep the
   intent, wait until the request's executor has stopped, and repeat this
   step's lookup before anything else: a stack that now holds the PRs as
   approved is adopted, never requested again.
6. Verify membership, order, heads and bases, then run
   `gh stack checkout STACK-NUMBER` so the local stack records the native
   stack's number; it only records it when the local layers match the stack's
   PRs. Stop on a composition conflict it reports.

## Recover a partial publication

If the approved branch was pushed but has no PR, claim a separate creation once
and create it with steps 3 and 4 of
[Open a layer's pull request](#open-a-layers-pull-request), at the exact
approved head branch, base branch, title and body.
Once every approved new PR exists, read the full PRs and native stack again and
join them by the topology step 5 there observes.
Do not use
combined branch linking to choose a different base from a concurrently changed
stack. Preserve creation evidence; a lost response requires reconciliation after
its executor stops, not a second creation. An older uncertain link attempt with
no visible PR does not establish that creation would be safe.

When recovery has existing PRs at the approved heads and bases, step 5 selects
its request in the same way, from the first unjoined PR: adopt a stack that
already holds every new PR as approved, append the first unjoined PR and every
new PR above it when the PR below it is a native stack's top, create the stack
when that PR below is in none, and send nothing for a lone bottom layer on the
trunk. Only the append below needs a stack number. For the append, use GitHub's
[native stack append endpoint](https://docs.github.com/en/rest/pulls/stacks#add-pull-requests-to-a-pull-request-stack).
`gh stack link` can retarget that PR's base before appending; a concurrent new
top could therefore change the approved dependency. The direct endpoint requires
the first candidate's base ref to match the current native top's head ref, each
later candidate's base to be the head of the one before it, and does not first
change any candidate's base.

Before the append, verify the repository, native stack identity and order, exact branch heads,
candidate PR number/head/base branch/base commit, and intended draft/open/unmerged
state with auto-merge disabled. Retain the original operation intent and verify
that its previous executor has stopped. Claim the remaining append once. Write
only the admitted PR numbers that are not yet in the stack in a JSON body,
bottom to top, from the current top upward: GitHub's endpoint takes an ordered list, and the first PR's base must be
the current top's head. One PR is `{"pull_requests":[123]}`; several new layers
are one request, `{"pull_requests":[122,123]}`. Then use the observed repository
and stack number:

```sh
gh api --method POST repos/OWNER/REPO/stacks/STACK_NUMBER/add \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2026-03-10' --input /path/to/append.json
```

On a conflict, validation error, or lost response, retain the intent and reconcile
GitHub without repeating the request or retargeting the PR. Verify membership,
heads and PR policy again after acceptance. The server's base-chain constraint
protects against an intervening append that leaves this PR's approved base
unchanged; it is not a conditional check of every commit, draft setting or review
event. This API operation uses native stack membership and performs no Git push.
