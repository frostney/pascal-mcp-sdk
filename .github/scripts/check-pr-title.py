#!/usr/bin/env python3
"""Validate the subject a squash merge will carry, as a Conventional Commit.

This repository squash-merges, so the squash commit's subject becomes
the CHANGELOG entry git-cliff generates. A non-conventional subject is
silently dropped: PR #38 ("Implement all remaining open issues: ...")
shipped the entire HTTP-era release and contributed nothing to the
changelog, and left `git cliff --bumped-version` recommending a patch
bump for a release containing a breaking change (caught during the
2.0.0 cut).

Which text becomes that subject depends on a repository setting:

  PR_TITLE            — always the pull-request title.
  COMMIT_OR_PR_TITLE  — the sole commit's subject when the PR has
                        exactly one commit, else the PR title.

A workflow token cannot read that setting (GitHub exposes it only to
admins), so this checker does not depend on knowing it: it validates
the PR title, and additionally validates the sole commit's subject
whenever the PR has exactly one commit. Whichever text GitHub picks,
it has been checked.

The accepted types are read from cliff.toml's commit_parsers rather
than duplicated here, so this gate cannot drift from the generator it
protects.

In CI, inputs arrive through the environment (never a command line or
shell interpolation — these strings are attacker controlled):

  PR_TITLE            the pull-request title (required)
  PR_COMMIT_COUNT     number of commits on the PR (optional)
  PR_COMMIT_SUBJECT   subject of the sole commit when there is one

Locally, lefthook's commit-msg hook runs it as
`check-pr-title.py --commit-msg FILE` on the message git is about to
record (#124), so a bad subject is caught before it is pushed. A
single-commit PR's title usually starts as that subject. The CI check
stays the gate: the title is written on GitHub, where no hook runs.
"""

import os
import re
import subprocess
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


# Subjects the hook lets through: git's autosquash prefixes, which
# `git rebase --autosquash` or the squash merge folds away, and merge
# commits. CI still checks a PR whose only commit carries one.
PASSED_PREFIXES = ('fixup! ', 'squash! ', 'amend! ', 'Merge ')


def message_subject(text, comment_char='#'):
    """The subject git records for message TEXT: its first line that is
    neither blank nor a comment. The commit-msg hook sees the message
    before git strips its comment lines."""
    for line in text.splitlines():
        if line.startswith(comment_char):
            continue
        if line.strip():
            return line.rstrip()
    return ''


def comment_char():
    """git's comment character: core.commentChar, '#' when unset or
    'auto' (which picks a character the message does not use, after
    the hook has run)."""
    try:
        value = subprocess.run(
            ['git', 'config', '--get', 'core.commentChar'],
            capture_output=True, text=True, check=False).stdout.strip()
    except OSError:
        value = ''
    if not value or value == 'auto':
        return '#'
    return value


def commit_candidates(path):
    """The commit-msg hook's candidates for the message in PATH: none
    for an empty message, which git refuses itself, or a subject the
    hook lets through."""
    with open(path, encoding='utf-8', errors='replace') as handle:
        subject = message_subject(handle.read(), comment_char())
    if not subject:
        return []
    if subject.startswith(PASSED_PREFIXES):
        print(f'commit subject left to the PR checks: {subject}')
        return []
    return [('commit subject', subject)]


def error_prefix():
    """A GitHub annotation in Actions, a plain prefix in a terminal."""
    return '::error::' if os.environ.get('GITHUB_ACTIONS') else 'error: '


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == '--commit-msg':
        if len(argv) != 2:
            print('usage: check-pr-title.py --commit-msg FILE')
            return 2
        candidates = commit_candidates(argv[1])
        if not candidates:
            return 0
    else:
        candidates = None
    try:
        with open(CLIFF_CONFIG, encoding='utf-8') as handle:
            types = allowed_types(handle.read())
    except OSError as error:
        print(f'{error_prefix()}cannot read {CLIFF_CONFIG}: {error}')
        return 1

    if not types:
        print(f'{error_prefix()}no commit types found in {CLIFF_CONFIG} '
              '— the commit_parsers block changed shape; update '
              '.github/scripts/check-pr-title.py to match')
        return 1

    # type(optional-scope)!: description — the "!" marks a breaking
    # change, which git-cliff routes to the Breaking Changes group.
    pattern = re.compile(
        r'^(' + '|'.join(types) + r')(\([^()\s]+\))?!?: \S.*$')

    # Every string GitHub could turn into the squash subject. The sole
    # commit's subject is only a candidate when there is exactly one
    # commit — that is the case where COMMIT_OR_PR_TITLE prefers it
    # over the title.
    if candidates is None:
        candidates = [('PR title', os.environ.get('PR_TITLE', ''))]
        commit_subject = os.environ.get('PR_COMMIT_SUBJECT', '')
        if os.environ.get('PR_COMMIT_COUNT') == '1' and commit_subject:
            candidates.append(("sole commit's subject", commit_subject))

    failed = [(label, text)
              for label, text in candidates if not pattern.match(text)]

    if not failed:
        for label, text in candidates:
            print(f'{label} is a valid Conventional Commit: {text}')
        return 0

    for label, text in failed:
        print(f'{error_prefix()}{label} is not a Conventional Commit: '
              f'{text!r}')
    print()

    if len(candidates) > 1:
        print('This PR has a single commit, so depending on the')
        print("repository's squash setting GitHub may use either the PR")
        print('title or that commit subject as the squash subject — and')
        print('therefore the CHANGELOG entry. Both must be valid.')
        print()

    # Explain against the first failure; the guidance is identical.
    title = failed[0][1]

    # Two different failures deserve two different explanations: an
    # unparseable title vanishes from the changelog, while a parseable
    # one with an uncurated type still appears — under "Other Changes".
    # Saying "dropped entirely" for the latter sends the author hunting
    # a changelog bug that is not there.
    generic = re.match(r'^([A-Za-z]+)(\([^()\s]+\))?!?: \S.*$', title)
    if generic:
        print(f'The type "{generic.group(1)}" is not one of this '
              "project's changelog types, so git-cliff would file the")
        print('entry under "Other Changes" instead of a curated section.')
    else:
        print('This repository squash-merges, so that text becomes the')
        print('commit subject and the CHANGELOG entry. A subject git-cliff')
        print('cannot parse is dropped from the changelog entirely and')
        print('does not count toward the version bump.')

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

    if title.startswith('Revert "'):
        print()
        print("GitHub's Revert button titles the PR "
              '`Revert "<original title>"`, which git-cliff cannot')
        print('parse. Retitle it as a revert commit, keeping the subject '
              'of the change being undone:')
        print('  revert: <original description>')
    if argv and argv[0] == '--commit-msg':
        print()
        print('The commit was not made. Your message is in '
              '.git/COMMIT_EDITMSG; edit it with')
        print('  git commit -e -F .git/COMMIT_EDITMSG')
    return 1


if __name__ == '__main__':
    sys.exit(main())
