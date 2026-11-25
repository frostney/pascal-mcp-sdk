# Documentation terminal recordings

The `.cast` files under `docs/casts/` are **real terminal sessions**:
each demo script here runs the actual built binaries (`lwpt build`,
`./build/mcpdemo`) and is recorded with
[asciinema](https://asciinema.org) — nothing is staged or synthesized
(see [CONTEXT.md](../../CONTEXT.md)). The website plays them with a
self-hosted asciinema-player; GitHub links to the raw files.

## Re-recording

When library output changes (new tool output, changed wire shapes),
re-record and commit:

```sh
bash tools/casts/record-all.sh
```

Prerequisites: the repo-pinned `lwpt` on PATH, `asciinema` (>= 3),
and `jq` (used inside the sessions to make JSON readable — it is
part of the recorded pipeline, not post-processing).

Recording is maintainer-local by design: the Pages build serves the
committed `.cast` files and never records, so the site build needs no
FPC, lwpt, or asciinema.

## Layout

- `lib.sh` — shared presentation helpers (prompt-style command
  echo, pacing) and the modern `_meta` envelope.
- `demo-<name>.sh` — one session per cast; run from the repo root.
- `record-all.sh` — builds, then records every demo at 80x24 with a
  2s idle cap.
