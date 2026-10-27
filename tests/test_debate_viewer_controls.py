"""Real PTY viewer controls and child lifetime, without a desktop terminal."""
import errno
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import time

if __package__:
    from .test_debate_views import ViewFixture
else:
    from test_debate_views import ViewFixture


class ViewerControlsTests(ViewFixture):
    def test_viewer_children_need_no_new_process_group_and_quit_while_paused(self):
        records = self.root / 'viewer-children.jsonl'
        for name in ('tail', 'awk'):
            real = shutil.which(name)
            tool = self.tools / name
            tool.write_text(f'#!{sys.executable}\n' + f'''
import json,os,sys
with open({str(records)!r},'a') as f:
 f.write(json.dumps(dict(pid=os.getpid(),pgid=os.getpgrp(),tool={name!r}))+'\\n')
os.execv({real!r},[{real!r},*sys.argv[1:]])
''')
            tool.chmod(0o755)
        team = 'viewer-controls'
        log_base = self.root / 'logs'
        log_dir = log_base / team
        first, second = log_dir / 'debate-first', log_dir / 'debate-second'
        first.mkdir(parents=True)
        second.mkdir()
        (first / 'stream-gen.log').write_text('BEFORE-PAUSE\n')
        (second / 'stream-gen.log').write_text('SECOND-DEBATE\n')

        def choose(directory, sequence):
            pending = log_dir / 'pending.json'
            pending.write_text(json.dumps(dict(v=1, sequence=sequence, debate_dir=str(directory))))
            pending.replace(log_dir / 'latest-debate.json')

        choose(first, 1)
        environment = self.env | dict(TMUX='', TMUX_PANE='', AGENT_TEAM=team,
                                      DEBATE_LOG_DIR=str(log_base))
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(self.workspace)
            os.execvpe('/bin/bash', ['/bin/bash', str(self.plugin / 'bin/tail-role.sh'), 'gen'], environment)
        reaped = False
        captured = ''

        def read_for(seconds):
            nonlocal captured
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if select.select([master], [], [], min(0.1, max(0, deadline-time.monotonic())))[0]:
                    try:
                        data = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            return
                        raise
                    if not data:
                        return
                    captured += data.decode(errors='replace')

        def wait_for(text):
            deadline = time.monotonic() + 10
            while text not in captured and time.monotonic() < deadline:
                read_for(0.1)
            self.assertIn(text, captured)

        def pause():
            previous = captured.count('[paused')
            os.write(master, b' ')
            deadline = time.monotonic() + 4
            while captured.count('[paused') == previous and time.monotonic() < deadline:
                read_for(0.1)
            self.assertGreater(captured.count('[paused'), previous)

        try:
            wait_for('BEFORE-PAUSE')
            pause()
            with (first / 'stream-gen.log').open('a') as f:
                f.write('DURING-PAUSE\n')
            read_for(1.3)
            self.assertNotIn('DURING-PAUSE', captured)
            os.write(master, b' ')
            wait_for('DURING-PAUSE')
            self.assertEqual(captured.count('BEFORE-PAUSE'), 1)
            self.assertEqual(captured.count('DURING-PAUSE'), 1)

            pause()
            with (first / 'stream-gen.log').open('a') as f:
                f.writelines(f'ABANDONED-PAUSED-{i}\n' for i in range(200))
            choose(second, 2)
            wait_for('SECOND-DEBATE')
            self.assertNotIn('ABANDONED-PAUSED-', captured)
            with (first / 'stream-gen.log').open('a') as f:
                f.write('STALE-FIRST-DEBATE\n')
            read_for(1.2)
            self.assertNotIn('STALE-FIRST-DEBATE', captured)
            pause()
            with (second / 'stream-gen.log').open('a') as f:
                f.writelines(f'QUIT-WHILE-PAUSED-{i}\n' for i in range(200))
            os.write(master, b'q')
            wait_for('[quit]')
            self.assertNotIn('QUIT-WHILE-PAUSED-', captured)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                ended, status = os.waitpid(pid, os.WNOHANG)
                if ended:
                    reaped = True
                    self.assertTrue(os.WIFEXITED(status))
                    self.assertEqual(os.WEXITSTATUS(status), 0)
                    break
                read_for(0.1)
            self.assertTrue(reaped, captured)
            children = [json.loads(line) for line in records.read_text().splitlines()]
            self.assertEqual({item['tool'] for item in children}, {'tail', 'awk'})
            # This detects actual group changes, regardless of how a viewer
            # might enable them. The old monitor-mode pipeline fails here.
            self.assertTrue(all(item['pgid'] == pid for item in children), children)
            for item in children:
                with self.assertRaises(ProcessLookupError):
                    os.kill(item['pid'], 0)
            self.assertNotIn('setpgid', captured)
        finally:
            if not reaped:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    ended, _ = os.waitpid(pid, os.WNOHANG)
                    if ended:
                        reaped = True
                        break
                    time.sleep(0.1)
                if not reaped:
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
            os.close(master)

    def test_term_during_each_child_registration_reaps_both_children(self):
        team = 'viewer-startup-signal'
        log_base = self.root / 'signal-logs'
        log_dir = log_base / team
        debate = log_dir / 'debate-start'
        debate.mkdir(parents=True)
        (debate / 'stream-gen.log').write_text('SIGNAL-START\n')
        (log_dir / 'latest-debate.json').write_text(json.dumps(dict(
            v=1, sequence=1, debate_dir=str(debate))))
        script = self.plugin / 'bin/tail-role.sh'
        source = script.read_text()
        assignments = {
            'FILTER_PID=$!': '$!',
            'TAIL_PID=$(jobs -p %+ 2>/dev/null) || TAIL_PID=""': '$(jobs -p %+)',
        }
        for assignment in assignments:
            self.assertIn(assignment, source)
        for phase in assignments:
            with self.subTest(phase=phase):
                children = self.root / 'started-pids'
                children.write_text('')
                modified = source
                for assignment, expression in assignments.items():
                    injected = f'printf "%s\\n" "{expression}" >> "$VIEWER_TEST_PIDS"\n'
                    if phase == assignment:
                        injected += 'kill -TERM "$$"\n'
                    modified = modified.replace(assignment, injected + assignment, 1)
                script.write_text(modified)
                environment = self.env | dict(TMUX='', TMUX_PANE='', AGENT_TEAM=team,
                                               DEBATE_LOG_DIR=str(log_base), VIEWER_TEST_PIDS=str(children))
                process = subprocess.Popen(['/bin/bash', str(script), 'gen'], cwd=self.workspace,
                                           env=environment, stdin=subprocess.DEVNULL, text=True,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           start_new_session=True)
                try:
                    _, stderr = process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)  # private test session only
                    process.communicate(timeout=5)
                    self.fail('viewer did not finish startup-signal cleanup')
                self.assertEqual(process.returncode, 143, stderr)
                pids = children.read_text().splitlines()
                self.assertEqual(len(pids), 2)
                for pid in pids:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(int(pid), 0)
