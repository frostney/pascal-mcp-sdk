"""Tests for check-pr-title.py's commit-msg mode and its CI mode (#124).

Run from the repository root, where cliff.toml lives:

    python3 -m unittest discover -s .github/scripts -p 'test_*.py'
"""

import contextlib
import importlib.util
import io
import os
import pathlib
import shlex
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).with_name('check-pr-title.py')
SPEC = importlib.util.spec_from_file_location('check_pr_title', SCRIPT)
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


# Every case starts from git's defaults, set explicitly: configuration
# from the command line (GIT_CONFIG_COUNT) wins over a contributor's
# repository, global or system settings (#124 review).
BASELINE = [('commit.cleanup', 'default'), ('core.commentChar', '#')]


def git_settings(editing=False, config=None):
    """The environment git gives a commit-msg hook: GIT_EDITOR is ':'
    when no editor opens, and the baseline then CONFIG as GIT_CONFIG_*
    pairs (later pairs win)."""
    env = {'GIT_EDITOR': 'vi' if editing else ':',
           'GIT_CONFIG_GLOBAL': os.devnull,
           'GIT_CONFIG_SYSTEM': os.devnull}
    pairs = BASELINE + list((config or {}).items())
    for index, (key, value) in enumerate(pairs):
        env[f'GIT_CONFIG_KEY_{index}'] = key
        env[f'GIT_CONFIG_VALUE_{index}'] = value
    env['GIT_CONFIG_COUNT'] = str(len(pairs))
    return env


def isolated(env):
    """os.environ with ENV as the only PR_*, GITHUB_*, GIT_EDITOR and
    GIT_CONFIG* variables."""
    clean = {key: value for key, value in os.environ.items()
             if not key.startswith(('PR_', 'GITHUB_', 'GIT_EDITOR',
                                    'GIT_CONFIG'))}
    clean.update(env)
    return mock.patch.dict(os.environ, clean, clear=True)


def run(argv, env=None):
    """main(ARGV) under ENV: its exit status and what it printed."""
    output = io.StringIO()
    with isolated(env or git_settings()), \
            contextlib.redirect_stdout(output):
        status = checker.main(argv)
    return status, output.getvalue()


def subject(message, editing=False, config=None):
    """The subject recorded_subject reads from MESSAGE (str)."""
    with isolated(git_settings(editing, config)):
        return checker.recorded_subject(message.encode('utf-8'), editing)


SCISSORS = '# ' + '-' * 24 + ' >8 ' + '-' * 24


class RecordedSubject(unittest.TestCase):
    def test_first_line(self):
        self.assertEqual(subject('fix: x\n\nbody\n'), 'fix: x')

    def test_comments_kept_without_an_editor(self):
        self.assertEqual(subject('# c\nfix: x\n'), '# c')

    def test_comments_stripped_in_the_editor(self):
        text = '\n# Please enter the commit message\n\nfeat: y  \n# end\n'
        self.assertEqual(subject(text, editing=True), 'feat: y')

    def test_comment_string_and_its_alias(self):
        # The alias set last wins, as git resolves it.
        text = '// c\n; d\nfeat: z\n'
        self.assertEqual(subject(text, True, {'core.commentString': '//'}),
                         '; d')
        self.assertEqual(
            subject('; d\nfeat: z\n', True,
                    {'core.commentString': '//', 'core.commentChar': ';'}),
            'feat: z')

    def test_comment_string_with_a_space(self):
        text = '// c\n//x\n'
        self.assertEqual(subject(text, True, {'core.commentString': '// '}),
                         '//x')

    def test_cleanup_modes(self):
        self.assertEqual(subject('# c\nfix: x\n', False,
                                 {'commit.cleanup': 'strip'}), 'fix: x')
        self.assertEqual(subject('# c\nfix: x\n', True,
                                 {'commit.cleanup': 'whitespace'}), '# c')
        self.assertEqual(subject('\n  \nbad subject\n', True,
                                 {'commit.cleanup': 'verbatim'}),
                         'bad subject')

    def test_scissors_only_when_an_editor_opened(self):
        text = '\n' + SCISSORS + '\nbad subject\n'
        self.assertEqual(subject(text, editing=True), '')
        self.assertEqual(subject(text, False, {'commit.cleanup': 'strip'}),
                         'bad subject')

    def test_scissors_with_another_comment_string(self):
        text = '\n//' + SCISSORS[1:] + '\nbad subject\n'
        self.assertEqual(subject(text, True, {'core.commentString': '//'}),
                         '')

    def test_lines_split_at_lf_only(self):
        self.assertEqual(subject('fix: a\u2028b\n'), 'fix: a\u2028b')

    def test_non_breaking_space_is_not_blank(self):
        self.assertEqual(subject('\u00a0\nfix: x\n'), '\u00a0')

    def test_empty(self):
        self.assertEqual(subject('# only\n\n', editing=True), '')


class CommitMsgMode(unittest.TestCase):
    def commit(self, message, editing=False, config=None):
        with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False,
                                         encoding='utf-8') as handle:
            handle.write(message)
        self.addCleanup(os.unlink, handle.name)
        self.path = handle.name
        return run(['--commit-msg', handle.name],
                   git_settings(editing, config))

    def test_valid_subject(self):
        status, output = self.commit('fix(schema): keep defaults\n')
        self.assertEqual(status, 0)
        self.assertIn('commit subject is a valid Conventional Commit',
                      output)

    def test_bad_subject_refused_with_guidance(self):
        status, output = self.commit('Update stuff\n\n# comment\n',
                                     editing=True)
        self.assertEqual(status, 1)
        self.assertIn("error: commit subject is not a Conventional "
                      "Commit: 'Update stuff'", output)
        self.assertIn('Allowed types:', output)
        self.assertIn('gh pr create --fill', output)
        self.assertIn('git commit -e -F ' +
                      shlex.quote(os.path.abspath(self.path)), output)
        self.assertIn('replaced by -e -F', output)

    def test_comment_line_kept_by_git_commit_m(self):
        # git commit -m keeps "# ..." lines, so that is the subject.
        status, output = self.commit('# bad subject\n\nfix: body\n')
        self.assertEqual(status, 1)
        self.assertIn("'# bad subject'", output)

    def test_comment_line_stripped_in_the_editor(self):
        status, _ = self.commit('# lead\nfeat: edited\n', editing=True)
        self.assertEqual(status, 0)

    def test_comment_string_from_git_config(self):
        config = {'core.commentString': '//'}
        status, _ = self.commit('// lead\nfeat: slash\n', True, config)
        self.assertEqual(status, 0)
        status, _ = self.commit('# lead\nfeat: slash\n', True, config)
        self.assertEqual(status, 1)

    def test_comment_char_from_git_config(self):
        status, _ = self.commit('; lead\nfeat: semi\n', True,
                                {'core.commentChar': ';'})
        self.assertEqual(status, 0)

    def test_cleanup_mode_from_git_config(self):
        status, _ = self.commit('# c\nfix: x\n', False,
                                {'commit.cleanup': 'strip'})
        self.assertEqual(status, 0)
        status, _ = self.commit('# c\nfix: x\n', True,
                                {'commit.cleanup': 'whitespace'})
        self.assertEqual(status, 1)

    def test_uncurated_type_refused(self):
        status, output = self.commit('wip: halfway\n')
        self.assertEqual(status, 1)
        self.assertIn('is not one of this project', output)
        self.assertIn('from the PR title', output)

    def test_autosquash_and_merge_subjects_pass(self):
        for subject in ('fixup! fix: x', 'squash! feat: y',
                        'amend! docs: z', "Merge branch 'main' into topic"):
            with self.subTest(subject=subject):
                status, output = self.commit(subject + '\n')
                self.assertEqual(status, 0)
                self.assertIn('left to the PR checks', output)

    def test_revert_subject_refused(self):
        status, output = self.commit('Revert "feat: y"\n')
        self.assertEqual(status, 1)
        self.assertIn('revert: <original description>', output)

    def test_empty_message_left_to_git(self):
        status, _ = self.commit('# nothing\n\n', editing=True)
        self.assertEqual(status, 0)

    def test_usage(self):
        status, output = run(['--commit-msg'], git_settings())
        self.assertEqual(status, 2)
        self.assertIn('usage:', output)


class CIMode(unittest.TestCase):
    def test_title_only(self):
        status, _ = run([], {'PR_TITLE': 'feat: add hook'})
        self.assertEqual(status, 0)

    def test_bad_title_is_an_annotation_in_actions(self):
        status, output = run([], {'PR_TITLE': 'Add hook',
                                  'GITHUB_ACTIONS': 'true'})
        self.assertEqual(status, 1)
        self.assertIn("::error::PR title is not a Conventional Commit",
                      output)

    def test_single_commit_subject_checked_too(self):
        status, output = run([], {'PR_TITLE': 'feat: add hook',
                                  'PR_COMMIT_COUNT': '1',
                                  'PR_COMMIT_SUBJECT': 'Add hook'})
        self.assertEqual(status, 1)
        self.assertIn("sole commit's subject is not", output)

    def test_fixup_subject_not_waved_through_in_ci(self):
        status, _ = run([], {'PR_TITLE': 'feat: add hook',
                             'PR_COMMIT_COUNT': '1',
                             'PR_COMMIT_SUBJECT': 'fixup! feat: add hook'})
        self.assertEqual(status, 1)


if __name__ == '__main__':
    unittest.main()
