#!/usr/bin/env python3
"""Validate a pull-request title as a Conventional Commit.

This repository squash-merges, so the PR title becomes the squash
commit's subject — and therefore the CHANGELOG entry git-cliff
generates for it. A non-conventional title is silently dropped by
git-cliff: PR #38 ("Implement all remaining open issues: ...") shipped
the entire HTTP-era release and contributed nothing to the changelog,
and left `git cliff --bumped-version` recommending a patch bump for a
release containing a breaking change (caught during the 2.0.0 cut).

The accepted types are read from cliff.toml's commit_parsers rather
than duplicated here, so this gate cannot drift from the generator it
protects.

Reads the title from the PR_TITLE environment variable (never from the
command line or a shell interpolation — a PR title is attacker
controlled).
"""

import os
import re
import sys

CLIFF_CONFIG = 'cliff.toml'


def allowed_types(config_text):
    """The commit types cliff.toml's parsers group into the changelog."""
    parsers = re.search(
        r'commit_parsers\s*=\s*\[(.*?)^\]', config_text, re.S | re.M)
    if parsers is None:
        return []
    return sorted({
        match.group(1)
        for match in re.finditer(r'message\s*=\s*"\^([a-z]+)"',
                                 parsers.group(1))
    })


def main():
    try:
        with open(CLIFF_CONFIG, encoding='utf-8') as handle:
            types = allowed_types(handle.read())
    except OSError as error:
        print(f'::error::cannot read {CLIFF_CONFIG}: {error}')
        return 1

    if not types:
        print(f'::error::no commit types found in {CLIFF_CONFIG} — the '
              'commit_parsers block changed shape; update '
              '.github/scripts/check-pr-title.py to match')
        return 1

    title = os.environ.get('PR_TITLE', '')
    # type(optional-scope)!: description — the "!" marks a breaking
    # change, which git-cliff routes to the Breaking Changes group.
    pattern = re.compile(
        r'^(' + '|'.join(types) + r')(\([^()\s]+\))?!?: \S.*$')

    if pattern.match(title):
        print(f'PR title is a valid Conventional Commit: {title}')
        return 0

    print(f'::error::PR title is not a Conventional Commit: {title!r}')
    print()
    print('This repository squash-merges, so the PR title becomes the')
    print('commit subject and the CHANGELOG entry. A title git-cliff')
    print('cannot parse is dropped from the changelog entirely and does')
    print('not count toward the version bump.')
    print()
    print('Use:  type(optional-scope): description')
    print('      type(optional-scope)!: description   (breaking change)')
    print()
    print(f'Allowed types: {", ".join(types)}')
    print()
    print('Examples:')
    print('  feat(transport): add Streamable HTTP binding')
    print('  fix(schema): make Build-reuse detection survive record copies')
    print('  feat(server)!: validate raw tool arguments against the subset')
    return 1


if __name__ == '__main__':
    sys.exit(main())
