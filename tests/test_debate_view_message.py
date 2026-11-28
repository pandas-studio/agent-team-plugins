"""Claude dispatch emits current-context viewing instructions as a host notice."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from jq_shim import write_jq_shim

HOOK = Path(__file__).resolve().parents[1] / 'debate-conductor/bin/announce-view.sh'


class ViewMessageTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="view message ' ")
        self.addCleanup(temp.cleanup)
        self.transcript = Path(temp.name) / 'transcript.jsonl'
        self.context = "/tmp/path ' with spaces/debate-view-context.abc123/context.json"
        self.view = dict(context_file=self.context, status='manual',
                         tail_commands=['tail -F /tmp/gen', 'tail -F /tmp/crit'],
                         user_message='Manual: tail -F /tmp/gen and tail -F /tmp/crit')

    def helper(self, view=None):
        return dict(type='user', message=dict(content=[dict(type='tool_result',
                    content=json.dumps(view or self.view))]))

    def chat(self, text):
        return dict(type='assistant', message=dict(content=[dict(type='text', text=text)]))

    def check(self, entries, command=None, env=None):
        self.transcript.write_text(''.join(json.dumps(e) + '\n' for e in entries))
        event = dict(tool_name='Bash', transcript_path=str(self.transcript), tool_input=dict(
            command=command or 'run-debate.sh --host=claude --context "' + self.context + '" -- topic'))
        return subprocess.run([str(HOOK)], input=json.dumps(event), text=True,
                              capture_output=True, timeout=5, env=env)

    def test_missing_helper_never_blocks_dispatch(self):
        result = self.check([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')

    def test_actual_commands_announced_without_permission_override(self):
        result = self.check([self.helper()])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), dict(systemMessage=self.view['user_message']))

    def test_foreign_context_and_chat_are_ignored(self):
        foreign = self.view | dict(context_file='/tmp/debate-view-context.other/context.json')
        result = self.check([self.helper(foreign), self.chat(self.view['user_message'])])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_latest_opener_message_replaces_attach_instructions(self):
        ready = self.view | dict(status='ready-detached', attach_command='tmux attach -t =view')
        opened = ready | dict(status='attached', user_message='Live view is attached.')
        result = self.check([self.helper(ready), self.chat(ready['attach_command']), self.helper(opened)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['systemMessage'], opened['user_message'])

    def test_unrelated_and_receipt_commands_are_ignored(self):
        for command in ('team-3pane.sh --view=auto', 'open-view.sh --context path',
                        'run-debate.sh --read-receipt --context path', 'ls',
                        'grep -n -- --host= debate-conductor/bin/run-debate.sh',
                        'echo run-debate.sh --host=claude'):
            result = self.check([self.helper()], command)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')

    def test_truncated_and_malformed_lines_do_not_poison_valid_helper(self):
        original = self.check([self.helper()])
        self.transcript.write_text('not JSON\n42\n"primitive"\n' + self.transcript.read_text() + '{"truncated":"')
        event = dict(tool_name='Bash', transcript_path=str(self.transcript), tool_input=dict(
            command='run-debate.sh --host=claude --context "' + self.context + '" -- topic'))
        result = subprocess.run([str(HOOK)], input=json.dumps(event), text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), json.loads(original.stdout))

    def test_unreadable_or_absent_transcript_is_advisory(self):
        event = dict(tool_name='Bash', transcript_path=str(self.transcript), tool_input=dict(
            command='run-debate.sh --host=claude --context missing -- topic'))
        result = subprocess.run([str(HOOK)], input=json.dumps(event), text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_absolute_and_quoted_runner_paths(self):
        import shlex
        for runner in (str(HOOK.with_name('run-debate.sh')),
                       shlex.quote(str(HOOK.with_name('run-debate.sh')))):
            result = self.check([self.helper()], runner + ' --host=claude --context "' + self.context + '" -- topic')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['systemMessage'], self.view['user_message'])

    def test_context_like_prefix_in_tmpdir_does_not_hide_actual_context(self):
        self.context = '/tmp/debate-view-context.parent/debate-view-context.abc123/context.json'
        self.view['context_file'] = self.context
        result = self.check([self.helper()])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['systemMessage'], self.view['user_message'])

    def test_tool_content_blocks_and_quoted_paths(self):
        helper = self.helper()
        helper['message']['content'][0]['content'] = [dict(type='text', text=json.dumps(self.view))]
        result = self.check([helper, self.chat(self.view['user_message'])])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['systemMessage'], self.view['user_message'])

    def test_failed_notice_reads_print_nothing_and_never_block(self):
        # A failed jq in the notice is an absent notice (#297): rc 0, nothing on either stream.
        temp = tempfile.TemporaryDirectory(prefix='view message jq ')
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        for query, modes in (('.user_message', ('empty', 'output')),
                             ('{systemMessage:$message}', ('empty', 'output'))):
            for mode in modes:
                for noisy in (False, True):
                    with self.subTest(query=query, mode=mode, noisy=noisy):
                        counter = root / 'count'
                        write_jq_shim(root, counter, shutil.which('jq'), query, mode=mode, stderr=noisy)
                        result = self.check([self.helper()],
                                            env=dict(os.environ, PATH=f'{root}{os.pathsep}{os.environ["PATH"]}'))
                        self.assertEqual(int(counter.read_text()), 1)
                        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))


if __name__ == '__main__':
    unittest.main()
