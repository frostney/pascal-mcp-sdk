# Address stack feedback

Converge review feedback for exactly one native GitHub stack. Review every
initial layer at its exact head, preserve the heads of frozen layers, place
each fix under step 7's rule, and stop only when the complete live stack
reaches a clean fixed point or an explicit blocker.
[stack-readiness.md](stack-readiness.md#frozen-members-and-invalidation)
defines when a layer is frozen.

Apply the parent SKILL.md shared authority, attribution, and evidence rules.
Require one repository-scoped native stack number verified through the Stacks
API or `gh stack`. A finding is live only when true in the integrated stack-top
tree and within its confirmed claim. Never mutate a frozen layer; use only
guarded official stack operations allowed by `git-workflow`.

Read [stack-readiness.md](stack-readiness.md) before assigning layer or
stack state.

Use `scripts/stack_state.py` with `--json` for native topology snapshots and
change waits. Use `scripts/review_wait.py` with `--json` for
each pull request's finding surfaces, review transitions, replies, and
resolutions. The helpers supply facts and exact mutations; this workflow owns
finding judgment, remediation, coverage, and readiness.

Without a valid review policy, `inspect` still returns feedback and check facts
but marks automation requirements unknown. Use these facts for discovery;
neither missing policy nor an empty finding list establishes completion. Supply
a verified policy before using `wait`.

The helper completes pagination and rejects changing feedback censuses. Its
automation state accounts for newer incomplete attempts and distinguishes
reply-only review records from verdicts. See the deterministic mechanism in
[pr-readiness.md](pr-readiness.md) when interpreting those helper states; the
complete-stack gate remains in `stack-readiness.md`.

When current policy or activity identifies CodeRabbit as active, use its
adapter as [CodeRabbit](pr-readiness.md#coderabbit) states. In read-only mode,
run only `status`, with every exact `PR=SHA`.

## Review rounds

1. Confirm a clean worktree for normal mode, fetch the remote default, read the
   native-stack rules, verify `gh stack` authentication, and inspect the exact
   stack number. In read-only mode, inspect remotely without checking out the
   stack. Capture the bottom-to-top members, base, drafts, exact heads, current
   checks, review policy, provider activity, threads, and finding surfaces.
2. Establish the complete stack claim from its pull-request bodies, linked
   requirements, project contracts, and current integrated top. Mark inferred
   claims. Stop when member scope is unrelated or the stack cannot safely ship
   as one atomic unit.
3. Discover active review providers from current policy, checks, and activity.
   Keep the core provider-neutral. Use executable adapter code only for behavior
   that generic GitHub checks, reviews, comments, and explicit retry times cannot
   represent. A missing or ambiguous required provider operation is pending,
   never a guessed trigger, completion, or wait.
4. Review every initial member once for its exact head. Serialize triggers when
   the active provider has account-wide, repository-wide, or other shared
   limits. For CodeRabbit, read `status` for every member, then `run` one
   member at a time, bottom-up. During waits, run transition commands under
   [`delivery-wait`'s running rules](../../delivery-wait/SKILL.md#running-a-wait).
   Do not wake the model merely to report unchanged state.
5. Inspect every inline thread, exact-head review body, and top-level
   finding surface. Record each finding's impact, gain, and if-not-done facts
   and apply the repository's finding policy as the [PR workflow](pr.md)
   describes; a finding the policy does not select is `declined`. Classify
   each claim against the integrated stack top:
   `moot`, `satisfied-later`, `mutated`, `live`, `declined`, or
   `material-decision`. Cite the exact descendant commit and call path for
   `satisfied-later`; do not accept a vague later-layer claim.
6. Reply and resolve a moot, satisfied-later, or evidence-backed decline only
   after its disposition is supported and accepted under repository policy. A
   decline requiring human judgment remains unresolved and blocks readiness.
   Record every live finding with its originating PR and thread or surface.
7. If live findings remain, check out the current native stack and record every
   remote head. Choose where each fix lands, against the live stack:
   - A finding on a layer that is not frozen, with no frozen layer above it,
     is fixed on that layer in place.
   - Every other fix goes on the top layer when it is a fix layer from an
     earlier round and is not frozen, since nothing sits above it.
   - Otherwise it goes into exactly one new branch above the current top,
     created with `gh stack add`, shared by every such fix this round.

   Only a frozen layer at or above a finding's layer calls for a new layer;
   red or unfinished CI never freezes a draft. Fix every validated live
   finding where it lands. Group commits by one
   coherent cause or originating PR where that preserves traceability; every
   source reply must link the exact landing commit and the PR it landed in. For a
   documentation finding, search the document and any file that mirrors the
   same fact for sibling statements, and fix them in the same commit; an
   incremental review surfaces each missed sibling one round later.
8. Run focused validation while fixing. Before publishing a substantive fix,
   in place or in a fix layer, restack it as step 9 describes, then repeat
   `/code-review fix-all` and `/test-against-spec fix` against the complete
   integrated tree as it will be published until both pass on the same
   unchanged content,
   leaving a finding declined under the finding policy unfixed, then
   establish the project's declared gate using matching current results. Stop
   for a material product, architecture, security, compatibility, or scope
   decision.
   If required behavior can only be exercised on a PR preview, complete the
   available checks and use step 9 to publish the layer that took the fix,
   explicitly retaining the missing preview evidence. Test its exact revision
   and resume this loop before readiness. Further repairs still respect frozen
   members: place each further repair under step 7's rule, checked against
   the live stack at that moment. The push helper refuses to move a layer that
   is ready for review or a draft whose GitHub Actions CI passed; for such a
   draft that the frozen rule does not freeze, list its ref under `rewrite`
   with `draftOnly` and the reason, checked again just before the push.
9. When another [review round on local commits](../SKILL.md#review-rounds-on-local-commits)
   will read the restacked local heads, commit and restack locally, run that
   round on them, and publish below once, after the last round. Layers can
   freeze while the fixes wait, and a restack moves every layer above a fix:
   before that push, repeat step 5's inspection on the still-published heads
   and route any new live finding through step 7, read the live stack
   again, place every waiting fix anew under step 7 against it, and keep
   every frozen head. When the new placement changes a layer's base or
   head, rerun step 8 on the integrated tree and review that layer's new
   diff before the push, within the caller's round limit. When the caller's
   rounds are spent, apply its rule for the last round's fixes to the new
   placement and name the changed layers in the result; if the caller
   requires another review instead, return that as a blocker. Enforce the
   native-stack reference's push-boundary checks for the frozen
   prefix and every branch the push moves or creates; preserve the frozen PR
   heads and metadata. Publish a fix made in place through the native-stack
   reference's in-place repair path: commit it on its layer, restack only the
   layers above it with `gh stack rebase --upstack --no-trunk` from that
   branch when there are any, check that every layer below kept its head,
   run step 8's review, specification test and project gate on the restacked
   top, push through the protected helper with each moved branch admitted, and
   cancel the superseded runs it names. Publish a new fix layer as the
   native-stack reference's
   [Open a layer's pull request](../../git-workflow/references/github-stacks.md#open-a-layers-pull-request)
   describes: protected `gh stack push`, its PR opened in one write with its
   actual claim, validation, originating finding links and the project's PR
   evidence, then native append. The helper
   refuses to move a layer that is ready for review or a draft whose CI passed;
   never list a frozen member under `rewrite` to land a fix. A fix in place
   moves the layer and every layer above it, so each moved head needs its
   exact-head CI, review and coverage again under step 11. Reconcile a
   partial result before continuing. Keep a layer
   that took a fix draft until its own local evidence and checks permit
   review. Trigger and collect its exact-head review under the active provider
   contract.
10. Once each layer a fix landed on has successful exact-head CI and a
    terminal review on its new head, reply to and resolve the originating
    threads with the exact fix evidence. Do not wait for that CI before
    handling new work: classify any live finding the review of a moved head
    returns, and any CI failure on it, as soon as it is known, and place its
    fix under step 7, which never pushes into a frozen member.
11. After every head, topology, review, or thread transition, reconcile native
    membership through the stack helper. An expected append-only fix layer keeps
    the frozen prefix valid but needs its own review. A fix in place, planned
    or not, changes the head of its layer and of every layer restacked above
    it: under the readiness reference's changed-head rule, each moved head
    needs its exact-head CI, review and coverage again before readiness. An
    unexpected head or topology change invalidates the affected evidence under
    the readiness reference and restarts the required portion of the round.
12. Before reporting readiness, capture the live stack again and compare it with
    the snapshot used by the final evidence pass. Require every current member
    to be present in the evidence set, and every layer that took a fix this
    round, in place or appended, to be reviewed clean at its current head. A
    drained trigger list is not completion when live membership differs.

## Provider adapters

Provider-neutral behavior is the default. A provider adapter may define only
the provider-specific trigger, completion evidence, contention scope, explicit
retry source, and escalation needed to obtain a trustworthy review. It does not
own stack identity, findings, fixes, readiness, merge authority, or general CI.

Do not invent adapters for ordinary GitHub review state. Do not copy provider
commands, comment parsing, timers, or paid options into the core workflow. The
CodeRabbit adapter is the only definition of CodeRabbit's triggers, waits,
refusals, and completion; [CodeRabbit](pr-readiness.md#coderabbit) lists its
states and what this workflow does for each.

## Result contract

Return:

- repository and native stack number;
- final bottom-to-top PR, branch, and exact-head list;
- each member's `reviewed`, `covered`, `pending`, or `blocked` state;
- every finding surface and its disposition, source thread, and exact fix or
  decline evidence;
- each fix made in place and each created fix layer, with its validation,
  CI, and review result;
- current unresolved and unanswered thread counts;
- active provider state and safely derived `retry_at` or `null`;
- topology changes and the evidence they invalidated;
- complete-stack state: `ready`, `pending`, or `blocked`; and
- blocker or next required transition.

Never report a partial prefix as ready when any required fix exists only in a
higher layer. A `ready` result never means merged. Started directly, continue
under the [delivery settings](../../deliver/SKILL.md#delivery-settings); with
`entry-points: deliver`, the stack goes on to `/deliver`, which takes it to the
configured endpoint (its default when `ORCHESTRATION.md` sets none).
With `stop`, end with this result.
