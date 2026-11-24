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

    KEY_WAIT = 'IFS= read -rs -t 1 -n 1 KEY </dev/tty'

    def start_viewer(self, team, tmux_body, ignore_hup=False):
        """Start the gen viewer on a new pty, as in a pane whose `tmux` is TMUX_BODY. Its
        process group is killed and it is reaped at cleanup, whatever the test did. The
        script copy notes every key wait it begins in viewer['waits']."""
        log_base = self.root / (team + '-logs')
        debate = log_base / team / 'debate-one'
        debate.mkdir(parents=True)
        (debate / 'stream-gen.log').write_text('STREAM-IS-SHOWN\n')
        (log_base / team / 'latest-debate.json').write_text(json.dumps(dict(
            v=1, sequence=1, debate_dir=str(debate))))
        self.tool('tmux', tmux_body)
        script = self.plugin / 'bin/tail-role.sh'
        source = script.read_text()
        if 'VIEWER_TEST_WAITS' not in source:
            self.assertEqual(source.count(self.KEY_WAIT), 1)
            script.write_text(source.replace(
                self.KEY_WAIT, 'echo wait >> "$VIEWER_TEST_WAITS"; ' + self.KEY_WAIT))
        viewer = dict(waits=self.root / (team + '-waits'), calls=self.root / (team + '-tmux-calls'),
                      master=None, status=None, left=None)
        viewer['waits'].write_text('')
        environment = self.env | dict(TMUX='', TMUX_PANE='%0', DEBATE_VIEW_NONCE='nonce-1', AGENT_TEAM=team,
                                      DEBATE_LOG_DIR=str(log_base), VIEWER_TEST_WAITS=str(viewer['waits']),
                                      VIEWER_TMUX_CALLS=str(viewer['calls']))
        pid, master = pty.fork()
        if pid == 0:
            try:
                if ignore_hup:
                    signal.signal(signal.SIGHUP, signal.SIG_IGN)
                os.chdir(self.workspace)
                os.execvpe('/bin/bash', ['/bin/bash', str(script), 'gen'], environment)
            finally:
                os._exit(127)  # never back into the test runner this child was forked from
        viewer.update(pid=pid, master=master)
        self.addCleanup(self.end_viewer, viewer)
        return viewer

    def close_terminal(self, viewer):
        if viewer['master'] is not None:
            os.close(viewer['master'])
            viewer['master'] = None

    def end_viewer(self, viewer):
        """Close the terminal, kill what is left of the viewer's process group and reap
        the viewer. The group is the pty's own session, and it is killed while the
        viewer's PID is still held, so the number cannot have passed to anyone else."""
        self.close_terminal(viewer)
        if viewer['status'] is None:
            # The group, then the viewer itself: a child that has not reached its own
            # session yet has no group to signal. macOS answers EPERM for a group that
            # holds only the exited viewer.
            for send in (os.killpg, os.kill):
                try:
                    send(viewer['pid'], signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            viewer['status'] = os.waitpid(viewer['pid'], 0)[1]

    def pump(self, viewer, seconds):
        """Let SECONDS pass, reading the viewer's terminal while it is open: a process
        cannot finish exiting while its terminal holds unread output."""
        deadline = time.monotonic() + seconds
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return
            if viewer['master'] is None:
                time.sleep(min(left, 0.05))
            elif select.select([viewer['master']], [], [], min(left, 0.05))[0]:
                try:
                    data = os.read(viewer['master'], 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b''
                if not data:  # the other end is closed: an empty read here, EIO on Linux
                    self.close_terminal(viewer)

    def waits(self, viewer):
        return viewer['waits'].read_text().count('wait')

    def enter_key_wait(self, viewer):
        """Return a third of a second into a key wait, so that a signal sent now arrives
        inside the 1 s read. A runner stalled for longer than the rest of that second
        would deliver it outside the read; the tests below then pass on a script that
        mishandles the read, and cannot fail on one that handles it."""
        before = self.waits(viewer)
        deadline = time.monotonic() + 15
        while self.waits(viewer) == before:
            self.assertLess(time.monotonic(), deadline, 'viewer did not start a key wait')
            self.pump(viewer, 0.02)
        self.pump(viewer, 0.3)

    def has_exited(self, viewer):
        # An exited, unreaped child stays in the table as a zombie, still holding its PID.
        state = subprocess.run(['ps', '-o', 'stat=', '-p', str(viewer['pid'])],
                               capture_output=True, text=True, check=True, timeout=10).stdout
        return state.strip().startswith('Z')

    def wait_status(self, viewer, seconds):
        """Wait for the viewer to exit by itself and return its status. viewer['left']
        gets the other members its process group still had at that moment."""
        deadline = time.monotonic() + seconds
        while not self.has_exited(viewer):
            if time.monotonic() >= deadline:
                self.end_viewer(viewer)
                self.fail(f'viewer was still running {seconds} s later')
            self.pump(viewer, 0.1)
        listing = subprocess.run(['ps', '-A', '-ww', '-o', 'pid=', '-o', 'pgid=', '-o', 'args='],
                                 capture_output=True, text=True, check=True, timeout=10).stdout
        rows = [line.split(None, 2) for line in listing.splitlines()]
        viewer['left'] = [row for row in rows if len(row) > 1 and row[1] == str(viewer['pid'])
                          and row[0] != row[1]]
        self.end_viewer(viewer)
        return viewer['status']

    def assert_exit(self, viewer, expected):
        status = self.wait_status(viewer, 12)
        self.assertFalse(os.WIFSIGNALED(status), f'viewer died of signal {os.WTERMSIG(status)}')
        self.assertEqual(os.WEXITSTATUS(status), expected)
        self.assertEqual(viewer['left'], [], 'processes the viewer left in its group')

    def test_signal_during_the_key_wait_still_finishes_a_slow_cleanup(self):
        # Every bash must exit with the signal's status after a complete cleanup. What this
        # guards against is bash 3.2 (macOS): it runs a trap inside `read -t` with that
        # read's alarm still set, and a cleanup the alarm interrupts crashed the shell or
        # left it spinning with TERM ignored. The pane lookup below outlasts the 1 s alarm.
        tmux = ('printf "%s\\n" "$*" >> "$VIEWER_TMUX_CALLS"\n'
                'case " $* " in *" show-options "*) sleep 1.5; echo \'{"nonce":"nonce-1"}\' ;; esac\n')
        for name, expected in (('hangup', 129), ('TERM', 143), ('INT', 130)):
            with self.subTest(signal=name):
                viewer = self.start_viewer('viewer-key-wait-' + name.lower(), tmux)
                self.enter_key_wait(viewer)
                if name == 'hangup':
                    self.close_terminal(viewer)
                else:
                    os.kill(viewer['pid'], getattr(signal, 'SIG' + name))
                self.assert_exit(viewer, expected)
                calls = viewer['calls'].read_text().splitlines()
                self.assertEqual(calls[-1], 'set-option -pu -t %0 @debate-view-ready', calls)

    def test_key_wait_stays_paced_when_the_terminal_closes_without_a_hangup(self):
        # A viewer started with SIGHUP ignored cannot trap it. With its terminal closed the
        # key wait fails at once, and that wait was the loop's only pacing.
        viewer = self.start_viewer('viewer-no-hangup', 'exit 0\n', ignore_hup=True)
        self.enter_key_wait(viewer)
        self.close_terminal(viewer)
        self.pump(viewer, 1)
        before = self.waits(viewer)
        self.pump(viewer, 3)
        begun = self.waits(viewer) - before
        self.assertTrue(1 <= begun <= 6, f'{begun} key waits begun in 3 s; a paced loop begins about 3')
        os.kill(viewer['pid'], signal.SIGTERM)
        self.assert_exit(viewer, 143)
