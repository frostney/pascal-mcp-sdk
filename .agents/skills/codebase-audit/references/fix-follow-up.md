# Fix follow-up

Read this after the user selects a remediation batch or finding IDs from a
completed audit. The authorization boundary in `SKILL.md` still applies.

1. Create or reuse a focused branch and implement the smallest complete remedy
   for each selected finding. Do not absorb unrelated findings.
2. The coordinator makes every edit. Do not redispatch completed audit lanes
   after fixes; re-engage a worker only to resolve incomplete or contradictory
   evidence.
3. Promote useful audit probes into regression tests, remove disposable
   artifacts, and run the affected behavioral probes and project gates.
4. Report fixed and unresolved IDs with observed evidence.

Use the repository's separate git and pull-request workflows only when the user
requests publication.
