"""agy CLI-log parsing in dev-trio/lib/agy-denial.sh: a line counts only as a log event."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "dev-trio/lib/agy-denial.sh"

ID = "0179d9db-25b9-4d06-97c2-4b7f60b8eb8d"
OTHER = "11111111-2222-4333-8444-555555555555"
# The header agy 1.5.9 writes: level+mmdd, time, thread id padded to 7, file:line.
HEAD = "I1116 19:26:35.123456       1 "
CREATED = f"{HEAD}server.go:1233] Created conversation {ID} (backend=BACKEND_TYPE_UNSPECIFIED)"


def soft(kind, step, head=HEAD):
    return f'{head}tool_confirmation_manager.go:221] Print mode: soft-denying tool confirmation "{kind}" at step {step}'


def confirmation(conversation, step, approved="false"):
    return (f"{HEAD}server.go:2738] Tool confirmation for conversation {conversation} step {step} "
            f"(type=*gemini_coder_go_proto.Step_Generic approved={approved})")


def allow_rule(quoted):
    # The one real log line that carries text a user wrote: the allow list.
    return (f"{HEAD}cli_setting_manager.go:96] CLI settings initialized: "
            f"permissions=&{{Allow:[command(grep -n '{quoted}' notes.txt) command(git status)]}}")


class AgyDenialLogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="agy denial log ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "agy home"
        self.log = self.root / "cli.log"

    def call(self, function, *args):
        result = subprocess.run(
            ["bash", "-c", '. "$1"; shift; "$@"', "bash", str(LIB), function, *args],
            stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=15, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def write_log(self, *lines):
        self.log.write_text("".join(line + "\n" for line in lines))

    def conversations(self):
        return self.call("agy_denial_conversations", str(self.log)).splitlines()

    def steps(self, conversations=1):
        return json.loads(self.call("_agy_denial_steps", str(self.log), ID, str(conversations)))

    def targets(self, fourth_call):
        # One planner response whose four calls take steps 7-10; agy recorded
        # step 7 only, so 8, 9 and 10 can each be named from the planner.
        logs = self.home / "brain" / ID / ".system_generated/logs"
        logs.mkdir(parents=True, exist_ok=True)
        rows = [
            {"step_index": 6, "type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [
                {"id": "1", "name": "run_command", "args": {"CommandLine": "git diff"}},
                {"id": "2", "name": "read_url", "args": {"Url": "https://example.com"}},
                {"id": "3", "name": "run_command", "args": {"CommandLine": "git log"}},
                fourth_call,
            ]},
            {"step_index": 7, "type": "GENERIC", "status": "DONE"},
        ]
        (logs / "transcript_full.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
        return self.call("agy_denial_targets", str(self.home), str(self.log)).splitlines()

    NEVER_DENIED = {"id": "4", "name": "run_command", "args": {"CommandLine": "git status"}}

    def test_a_soft_denying_phrase_quoted_in_an_allow_rule_is_not_a_denial(self):
        # The real denial here is the read_url at step 8, which has no name to
        # give; step 10 exists only inside the allow rule's text.
        for kind in ("RunCommand", "ReadFile"):
            with self.subTest(kind=kind):
                self.write_log(
                    CREATED,
                    allow_rule(f'Print mode: soft-denying tool confirmation "{kind}" at step 10'),
                    soft("ReadURL", 8),
                )
                self.assertEqual(self.steps(), [8])
                self.assertEqual(self.targets(self.NEVER_DENIED), [])

    def test_a_confirmation_quoted_in_an_allow_rule_is_not_a_denial(self):
        self.write_log(
            CREATED,
            allow_rule(f"Tool confirmation for conversation {ID} step 10 (type=x approved=false)"),
            soft("ReadURL", 8),
        )
        self.assertEqual(self.steps(), [8])
        self.assertEqual(self.targets(self.NEVER_DENIED), [])

    def test_a_conversation_quoted_in_an_allow_rule_is_not_a_conversation(self):
        # A second id would also switch the soft-denying fallback off.
        self.write_log(
            CREATED,
            f"{HEAD}cli_setting_manager.go:96] CLI settings initialized: permissions=&{{Allow:["
            f"command(echo server.go:1] Created conversation {OTHER} done)]}}",
            soft("RunCommand", 10),
        )
        self.assertEqual(self.conversations(), [ID])
        self.assertEqual(self.targets(self.NEVER_DENIED), ["command(git status)"])

    def test_a_soft_denying_line_alone_gives_the_step_for_any_one_word_kind(self):
        for kind in ("RunCommand", "ReadFile", "ReadURL"):
            with self.subTest(kind=kind):
                self.write_log(CREATED, soft(kind, 10))
                self.assertEqual(self.steps(), [10])

    def test_a_soft_denied_command_is_named_without_a_confirmation_line(self):
        self.write_log(CREATED, soft("RunCommand", 10))
        self.assertEqual(self.targets(self.NEVER_DENIED), ["command(git status)"])

    def test_a_kind_that_is_not_one_word_gives_no_step(self):
        for kind in ("Read File", "", "Read-File", 'Read"File'):
            with self.subTest(kind=kind):
                self.write_log(CREATED, soft(kind, 10))
                self.assertEqual(self.steps(), [])

    def test_soft_denying_lines_are_not_used_when_the_log_has_two_conversations(self):
        self.write_log(CREATED, CREATED.replace(ID, OTHER), soft("RunCommand", 10))
        self.assertEqual(self.conversations(), [ID, OTHER])
        self.assertEqual(self.steps(conversations=2), [])
        self.assertEqual(self.targets(self.NEVER_DENIED), [])

    def test_a_confirmation_line_decides_over_soft_denying_lines(self):
        self.write_log(CREATED, soft("RunCommand", 9), confirmation(ID, 10), confirmation(OTHER, 8),
                       confirmation(ID, 3, approved="true"))
        self.assertEqual(self.steps(), [10])

    def test_a_line_that_does_not_start_with_the_log_header_is_not_an_event(self):
        for name, line in (
            ("indented", "  " + soft("RunCommand", 10)),
            ("no header", 'Print mode: soft-denying tool confirmation "RunCommand" at step 10'),
            ("header after text", "note: " + soft("RunCommand", 10)),
            ("no time", soft("RunCommand", 10, head="I1116 1 ")),
        ):
            with self.subTest(name):
                self.write_log(CREATED, line)
                self.assertEqual(self.steps(), [])
        self.write_log("  " + CREATED, "see " + CREATED)
        self.assertEqual(self.conversations(), [])

    def test_header_widths_seen_in_real_logs_and_fixtures_are_events(self):
        for head in (HEAD, "I1116 19:26:35.123456   51234 ", "W1026 12:08:06.8 1 ", "E0923 17:51:49.1 1 "):
            with self.subTest(head=head):
                self.write_log(f"{head}server.go:1239] Created conversation {ID}", soft("RunCommand", 10, head=head))
                self.assertEqual(self.conversations(), [ID])
                self.assertEqual(self.steps(), [10])

    def test_a_conversation_id_that_is_not_a_uuid_is_dropped(self):
        self.write_log(
            f"{HEAD}server.go:1233] Created conversation ../../etc (backend=x)",
            f"{HEAD}server.go:1233] Created conversation {ID}/../x",
            f"{HEAD}server.go:1233] Created conversation",
            CREATED, CREATED,
        )
        self.assertEqual(self.conversations(), [ID])


if __name__ == "__main__":
    unittest.main()
