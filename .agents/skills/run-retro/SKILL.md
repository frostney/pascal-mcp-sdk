---
name: run-retro
description: >-
  Reviews a completed workstream from conversation, repository, and forge
  evidence, uses grilling to agree durable lessons, and updates project vision
  and readiness/completion definitions after confirmation. Use when ending a
  substantial workstream or running a project retrospective.
license: Unlicense OR MIT
compatibility: >-
  Requires a registered grilling skill and access to the current workstream's
  available conversation, repository, and forge evidence.
---

# Run retrospective

## Instructions

Review the completed workstream, use the actual `grilling` skill to reach shared
understanding about durable project lessons, and then directly update the
project's `VISION.md`, `DEFINITION_OF_READY.md`, and
`DEFINITION_OF_DONE.md` after the user explicitly confirms the exact edits.

### Non-negotiable gates

#### GATE A — Ground the retrospective in workstream evidence

Use the current workstream conversation together with the repository and forge
evidence it produced. Inspect the relevant diff, commits, issues, pull requests,
reviews, checks, rework, and missed or successful gates. Look facts up rather
than asking the user to recall them.

If an evidence source is unavailable, record the absence and lower confidence;
never fill the gap with memory or an unsupported narrative. Keep the evidence
scope tied to the workstream rather than turning the retrospective into an
unrelated repository audit.

#### GATE B — `grilling` owns the decision loop

The registered `grilling` skill is a hard dependency. Invoke the actual skill,
give it the evidence and candidate lessons, and let it ask every decision
question one at a time with a recommended answer. Do not imitate its style or
replace it with an ad-hoc interview. If `grilling` is unavailable, stop with a
clear dependency message.

Do not edit project documents until `grilling` has reached shared understanding
and the user explicitly confirms the exact edit set.

#### GATE C — Promote only durable project lessons

A document change must be generalized, project-level, and supported by the
workstream evidence. Do not turn one-off mistakes, session chronology, personal
preferences, rules already covered, or speculative improvements into permanent
project policy.

Classify each durable lesson by the contract it changes:

- **`VISION.md`:** product purpose, intended users and outcomes, scope,
  non-goals, strategic direction, or architectural boundaries.
- **`DEFINITION_OF_READY.md`:** evidence, decisions, dependencies, acceptance
  criteria, or other conditions that must hold before work starts.
- **`DEFINITION_OF_DONE.md`:** implementation, verification, review,
  documentation, delivery, or operational conditions required before work is
  complete.
- **Report only:** a useful improvement that belongs in `AGENTS.md`, tooling,
  another skill, an upstream project, or nowhere in the three target documents.

Direct edits are limited to the three target documents. Report other
improvements separately without silently widening scope.

#### GATE D — Exact confirmation authorizes direct edits

Before editing, present the exact proposed changes grouped by target document,
the evidence for each change, and any observations intentionally left as
report-only. Ask for one explicit confirmation of that edit set through
`grilling`.

An existing target document may be edited after confirmation. A missing target
document may be created only when its creation and proposed contents are
explicitly included in that confirmation. If the user changes the proposal,
return to the `grilling` loop and confirm the revised set.

Confirmation authorizes only the agreed document edits. It does not authorize
commits, pushes, pull requests, issue changes, or edits to other files.

### Steps

1. **Resolve the workstream.** Identify the repository, completed task, linked
   issues or pull requests, and the time or turn boundary of the work being
   reviewed. Use the current conversation and `.agent/HANDOFF.md` when
   available; state any boundary that remains uncertain.
2. **Read the project contracts.** Search the root, relevant product areas, and
   `docs/` for the three target documents and spelling/case variants. Read every
   relevant match before proposing changes. Record which targets are absent.
3. **Build an evidence ledger.** Record concrete outcomes, friction, rework,
   surprises, missed expectations, gates that failed or caught problems, and
   successful practices worth preserving. Link every candidate lesson to the
   conversation, repository, or forge evidence that supports it.
4. **Filter and classify.** Remove duplicates, already-covered rules,
   session-specific details, and claims without evidence. Classify the remaining
   candidates under Vision, Ready, Done, or Report only using GATE C.
5. **Invoke `grilling`.** Give it the workstream boundary, evidence ledger,
   current target documents, absences, and classified candidates. Complete its
   one-question-at-a-time loop; all unresolved judgments belong in that loop.
6. **Present the edit set.** Show the exact proposed additions, replacements, or
   removals per target document, with evidence and rationale. Include missing
   documents proposed for creation and list report-only improvements separately.
7. **Confirm through `grilling`.** Obtain explicit confirmation of the complete
   edit set. Do not treat the original request to run a retrospective as this
   final confirmation.
8. **Apply the confirmed edits.** Preserve each document's structure and voice,
   make the smallest coherent change, and avoid duplicating or contradicting
   existing policy. Create a missing document only when confirmed and follow the
   project's existing documentation conventions.
9. **Verify.** Inspect the final diff against the confirmed edit set, re-read the
   affected sections for conflicts or accidental scope expansion, and run the
   project's declared documentation or markdown checks when available. Never
   invent a validation command.
10. **Report.** Summarize the changed contracts, report-only improvements,
    unavailable evidence, confidence limits, and verification results.

### Output

Before confirmation, provide:

1. **Evidence-backed lessons** — the observed event and durable implication.
2. **Proposed contract changes** — exact edits grouped by Vision, Ready, and
   Done, including any proposed document creation.
3. **Report-only improvements** — useful findings intentionally not promoted to
   the three project contracts.
4. **Confidence and gaps** — unavailable sources or uncertain boundaries.

After applying the confirmed edits, provide a concise changed-files summary and
the verification evidence. Keep the retrospective narrative in chat; do not add
session history to the project contracts.
