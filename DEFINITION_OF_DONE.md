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

- New protocol surface gets both a co-located unit test and, when it is
  reachable end-to-end, an `mcpsmoke` check.
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
- No push and no PR without explicit maintainer go-ahead.
