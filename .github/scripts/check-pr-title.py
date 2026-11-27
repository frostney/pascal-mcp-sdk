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
import shlex
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


def git_output(args, data=b''):
    """git ARGS fed DATA on stdin: its output as bytes, b'' when git
    fails or is missing."""
    try:
        result = subprocess.run(['git'] + args, input=data,
                                capture_output=True, check=False)
    except OSError:
        return b''
    return result.stdout if result.returncode == 0 else b''


def comment_prefix():
    """git's comment string, as git itself resolves core.commentString
    and core.commentChar (the one set last wins): `git stripspace -c`
    writes it, then a space, before each line."""
    marked = git_output(['stripspace', '-c'], b'x\n')
    if marked.endswith(b' x\n'):
        return marked[:-len(b' x\n')]
    return b'#'


def verbose_config():
    """Whether commit.verbose asks for the diff below a scissors line."""
    value = git_output(['config', '--get', 'commit.verbose']).strip()
    value = value.decode('utf-8', 'replace').lower()
    return value in ('true', 'yes', 'on') or (value.isdigit()
                                              and int(value) > 0)


def recorded_subject(message, editing):
    """The subject git records for MESSAGE (bytes), the text the
    commit-msg hook gets before git cleans it up, under git's own
    cleanup (git-commit(1), --cleanup): in an editor, the scissors line
    and everything after it go under `scissors` or with commit.verbose;
    comments go under `strip`, and under `default` when an editor
    opened; `verbatim` keeps the text as it is. The subject is the
    first line, split at LF, that git does not count as blank (git's
    whitespace is space, tab, CR and LF only). Options on the command
    line (--cleanup, -v) are not visible to the hook; with -v, an
    empty message is refused here rather than aborted by git."""
    mode = git_output(['config', '--get', 'commit.cleanup']).strip()
    mode = mode.decode('utf-8', 'replace') or 'default'
    if editing and (mode == 'scissors' or verbose_config()):
        scissors = (comment_prefix() + b' ' + b'-' * 24 + b' >8 ' +
                    b'-' * 24 + b'\n')
        cut = (b'\n' + message).find(b'\n' + scissors)
        if cut >= 0:
            message = message[:cut]
    if mode == 'verbatim':
        cleaned = message
    elif mode == 'strip' or (mode == 'default' and editing):
        cleaned = git_output(['stripspace', '--strip-comments'], message)
    else:
        cleaned = git_output(['stripspace'], message)
    for line in cleaned.split(b'\n'):
        if line.strip(b' \t\r'):
            return line.rstrip(b' \t\r').decode('utf-8', 'replace')
    return ''


def commit_candidates(path):
    """The commit-msg hook's candidates for the message in PATH: none
    for an empty message, which git refuses itself, or a subject the
    hook lets through."""
    with open(path, 'rb') as handle:
        # Git sets GIT_EDITOR to ':' for its hooks when it opens no
        # editor, whatever the caller's environment says.
        subject = recorded_subject(handle.read(),
                                   os.environ.get('GIT_EDITOR') != ':')
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
    hook = bool(argv) and argv[0] == '--commit-msg'
    if hook:
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
    if hook:
        print('The squash merge takes its subject, and the CHANGELOG')
        print('entry, from the PR title. `gh pr create --fill` copies a')
        print("single commit's subject into that title, and the PR title")
        print("check also checks a single-commit PR's commit subject, so")
        print('a subject this check refuses would fail it there.')
    elif not generic:
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
    if hook:
        saved = shlex.quote(os.path.abspath(argv[1]))
        print()
        print(f'The commit was not made. Its message is saved in {saved}.')
        print('Run the same commit again with -m or -F replaced by -e -F')
        print('and that file, keeping its other options and paths:')
        print(f'  git commit -e -F {saved}')
        print('A commit made with -C <commit> keeps that commit\'s author')
        print('when run again with -c <commit>, which opens the editor.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
