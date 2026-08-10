# Definition of Done

A change is done only when every applicable requirement below is
satisfied. A requirement may be marked not applicable only with a
recorded reason.

## Implementation

- The delivered behaviour matches its investigated issue or
  user-confirmed mini-spec, including non-goals and failure behaviour.
- The change satisfies the [AGENTS.md](AGENTS.md) hard constraints —
  in particular: protocol rules live in their owning layer, and no new
  dependencies arrive without explicit maintainer approval.
- Protocol behaviour cites the official spec page it implements, with
  the verification date, next to the code (unit header or inline).
- Workaround comments cite the issue that currently blocks removal.
  When it closes, re-verify the condition and retarget or delete the
  workaround; closure alone is not evidence it can go.
- The solution is the smallest complete change; no unrelated
  refactoring rides along.

## Tests and verification

- The universal project gate passes:

  ```sh
  lwpt install --frozen
  lwpt format --check
  lwpt build
  lwpt test
  ./build/mcpsmoke
  ```

- A gate counts as evidence only when it can fail: force a failure once
  on any new or newly-relied-on check and confirm it reports one. A
  green summary is not proof.
- Verify in the environment and at the privilege level the change will
  run in. A local run on one OS, CPU target, or an admin session is not
  evidence about CI, another target, or a fork's token.
- New protocol surface gets both a co-located unit test and, when it is
  reachable end-to-end, an `mcpsmoke` check.
- New protocol surface must be tested on its failure paths, not only
  its happy path: malformed or hostile input, resource limits,
  error-code and status mapping, and teardown under concurrency.
- String-carrying surfaces must be tested with non-ASCII payloads
  (multi-byte UTF-8, ideally adjacent multi-byte and astral-plane
  characters), asserted byte-exact on the encoded wire line — never on
  decoded values, where a symmetric encode/decode regression cancels
  out (#10, #26).
- The no-lwpt path still works when the dependency set or layout
  changed: `fpc @lwpt.cfg source/apps/mcpdemo.pas` compiles on a fresh
  checkout.

## Documentation

- Docs affected by the change are updated in the same change
  (README, docs/, AGENTS.md tables).
- Markdown passes markdownlint (`.markdownlint-cli2.jsonc`).

## Delivery

- Commits follow Conventional Commits (git-cliff feeds CHANGELOG.md
  from them).
- A change that breaks existing consumers must carry the breaking
  marker (`type!:` or a `BREAKING CHANGE:` footer) and a migration note
  in the docs naming the replacement or escape hatch.
- A release sweeps version-pinned references in the same change:
  install commands in README and docs resolve to the released
  version, and verification citations name the artifacts the
  interop battery pins.
- PR titles follow Conventional Commits, and on a single-commit PR the
  commit subject must too — a squash merge turns one of them into the
  CHANGELOG entry. Reverts need a `revert:` title. Enforced by the
  `PR title` workflow.
- PR descriptions put each closing keyword on its own line
  (`Closes #N`); comma-separated keywords on one line do not
  auto-close (#25).
- No push and no PR without explicit maintainer go-ahead.
