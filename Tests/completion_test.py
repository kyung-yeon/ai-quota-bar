"""Exercise the shipped hook executable without real accounts, settings, or GUI."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/AiQuotaBar"


class CompletionIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"]}

    def tearDown(self):
        self.temp.cleanup()

    def hook(self, payload, provider="codex"):
        return subprocess.run([str(BINARY), "--completion-hook", provider,
                               "--completion-data-dir", str(self.directory)],
                              input=json.dumps(payload), text=True, capture_output=True,
                              env=self.env, timeout=8)

    def state(self):
        return json.loads((self.directory / "completions.json").read_text())

    def completion(self, session, turn):
        return {"hook_event_name": "Stop", "session_id": session,
                "turn_id": turn, "cwd": "/projects/sample",
                "last_assistant_message": "secret message never persisted"}

    def test_concurrent_sessions_and_duplicate_delivery(self):
        payloads = [self.completion(f"session-{i}", "turn-1") for i in range(12)] * 2
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:
            results = list(workers.map(self.hook, payloads))
        self.assertTrue(all(p.returncode == 0 for p in results), [p.stderr for p in results])
        self.assertEqual(len(self.state()["events"]), 12)
        raw = (self.directory / "completions.json").read_text()
        self.assertNotIn("secret message", raw)
        self.assertEqual((self.directory / "completions.json").stat().st_mode & 0o777, 0o600)

    def test_claude_without_prompt_id_keeps_identical_responses_in_separate_turns(self):
        start = {"hook_event_name": "UserPromptSubmit", "session_id": "claude-session", "cwd": "/project"}
        stop = {**start, "hook_event_name": "Stop", "last_assistant_message": "Done"}
        for _ in range(2):
            self.assertEqual(self.hook(start, "claude").returncode, 0)
            self.assertEqual(self.hook(stop, "claude").returncode, 0)
            self.assertEqual(self.hook(stop, "claude").returncode, 0)
        self.assertEqual(len(self.state()["events"]), 2)

    def test_concurrent_turns_keep_one_unread_card_per_provider_and_session(self):
        payloads = [self.completion("same-session", f"turn-{i}") for i in range(12)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:
            results = list(workers.map(self.hook, payloads))
        self.assertTrue(all(p.returncode == 0 for p in results), [p.stderr for p in results])
        stored = self.state()["events"]
        unread = [e for e in stored if e.get("acknowledgedAt") is None]
        self.assertEqual(len(stored), 12)  # Retain replaced IDs to suppress replays.
        self.assertEqual(len(unread), 1)
        latest_id = unread[0]["id"]
        for payload in payloads:
            self.assertEqual(self.hook(payload).returncode, 0)
        self.assertEqual([e["id"] for e in self.state()["events"] if e.get("acknowledgedAt") is None], [latest_id])
        self.assertEqual(self.hook(self.completion("same-session", "claude-turn"), "claude").returncode, 0)
        self.assertEqual(len([e for e in self.state()["events"] if e.get("acknowledgedAt") is None]), 2)

    def test_ignored_events_do_not_create_alerts(self):
        for event in ["SessionStart", "Interrupt", "StopFailure", "SessionEnd", "SubagentStop"]:
            result = self.hook({"hook_event_name": event, "session_id": "s", "cwd": "/p"})
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()["events"], [])

    def test_corrupt_store_is_not_overwritten(self):
        file = self.directory / "completions.json"
        file.write_text("corrupted")
        self.assertNotEqual(self.hook(self.completion("s", "t")).returncode, 0)
        self.assertEqual(file.read_text(), "corrupted")

    def test_oversized_input_is_rejected(self):
        data = self.completion("s", "t")
        data["last_assistant_message"] = "x" * 1_048_577
        self.assertNotEqual(self.hook(data).returncode, 0)
        self.assertFalse((self.directory / "completions.json").exists())

    def test_codex_notify_uses_same_identity_as_stop_hook(self):
        self.assertEqual(self.hook(self.completion("s", "t")).returncode, 0)
        notify = {"type": "agent-turn-complete", "thread-id": "s", "turn-id": "t", "cwd": "/p"}
        result = subprocess.run([str(BINARY), "--notify-codex", json.dumps(notify),
                                 "--completion-data-dir", str(self.directory)],
                                text=True, capture_output=True, env=self.env, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.state()["events"]), 1)

    def test_unsupported_current_host_does_not_reuse_a_previous_destination(self):
        self.env["ITERM_SESSION_ID"] = "old-session"
        self.hook({"hook_event_name": "SessionStart", "session_id": "s", "cwd": "/p"})
        self.env.pop("ITERM_SESSION_ID")
        self.env["TERM_PROGRAM"] = "vscode"
        self.assertEqual(self.hook(self.completion("s", "new-turn")).returncode, 0)
        self.assertEqual(self.state()["events"][0]["destination"]["host"], "unsupported")

    def test_ephemeral_exec_is_detected_from_the_real_parent_process(self):
        # A tiny local process named codex exercises the OS metadata boundary,
        # without launching an AI CLI, contacting a service, or touching real alerts.
        source = self.directory / "parent.c"
        source.write_text('''#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
int main(void) {
    pid_t child = fork();
    if (child == 0) {
        execl(getenv("TEST_APP"), "AiQuotaBar", "--completion-hook", "codex",
              "--completion-data-dir", getenv("TEST_STORE"), (char *)0);
        _exit(127);
    }
    int status; if (child < 0 || waitpid(child, &status, 0) < 0) return 1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}''')
        parent = self.directory / "codex"
        subprocess.run(["/usr/bin/xcrun", "clang", str(source), "-o", str(parent)], check=True, capture_output=True)
        env = {**self.env, "TEST_APP": str(BINARY), "TEST_STORE": str(self.directory),
               "AIQUOTABAR_EPHEMERAL_EXEC": "1"}
        payload = json.dumps(self.completion("automatic", "one"))
        automatic = subprocess.run([str(parent), "exec", "--ephemeral"], input=payload,
                                   text=True, capture_output=True, env=env, timeout=8)
        self.assertEqual(automatic.returncode, 0, automatic.stderr)
        self.assertEqual(self.state()["events"], [])
        # The inherited marker cannot suppress a normal session or prompt text.
        normal = subprocess.run([str(parent), "exec", "--", "--ephemeral"], input=payload,
                                text=True, capture_output=True, env=env, timeout=8)
        self.assertEqual(normal.returncode, 0, normal.stderr)
        self.assertEqual(len(self.state()["events"]), 1)

    def test_progress_hook_round_trip_is_session_scoped_and_private(self):
        def update(session, title):
            return {"hook_event_name": "PostToolUse", "session_id": session, "cwd": "/sample",
                    "turn_id": "turn", "tool_name": "update_plan", "tool_use_id": "plan-1",
                    "tool_input": {"explanation": "private reasoning", "plan": [
                        {"step": "Analyze", "status": "completed"}, {"step": title, "status": "in_progress"}]},
                    "tool_response": "Plan updated"}
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            results = list(workers.map(self.hook, [update("a", "Build A"), update("b", "Build B")] * 2))
        self.assertTrue(all(r.returncode == 0 and r.stdout.strip() == "{}" for r in results))
        state = self.state()
        self.assertEqual(len(state["progress"]), 2)
        self.assertEqual({v["steps"][1]["title"] for v in state["progress"].values()}, {"Build A", "Build B"})
        self.assertEqual(state["events"], [])
        self.assertNotIn("private reasoning", (self.directory / "completions.json").read_text())
        self.assertEqual((self.directory / "completions.json").stat().st_mode & 0o777, 0o600)

    def test_progress_registration_preserves_unrelated_tool_hooks(self):
        file = self.directory / "settings.json"
        original = {"hooks": {"PostToolUse": [{"matcher": "Write", "hooks": [{"type": "command", "command": "echo unrelated"}]}]}}
        file.write_text(json.dumps(original))
        self.assertEqual(self.configure("--install-completion-hooks").returncode, 0)
        groups = json.loads(file.read_text())["hooks"]["PostToolUse"]
        self.assertEqual(groups[0], original["hooks"]["PostToolUse"][0])
        self.assertEqual(groups[1]["matcher"], "^(TodoWrite|TaskCreate|TaskUpdate|TaskList)$")
        self.assertEqual(self.configure("--remove-completion-hooks").returncode, 0)
        self.assertEqual(json.loads(file.read_text()), original)

    def configure(self, action):
        environment = {**self.env, "CLAUDE_CONFIG_DIR": str(self.directory)}
        return subprocess.run([str(BINARY), action, "claude"], env=environment,
                              text=True, capture_output=True, timeout=8)

    def test_custom_profile_install_and_uninstall_preserve_original_settings(self):
        original = {"theme": "dark", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo custom"}]}]}}
        file = self.directory / "settings.json"
        file.write_text(json.dumps(original))
        result = self.configure("--install-completion-hooks")
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = file.read_bytes()
        self.assertEqual(self.configure("--install-completion-hooks").returncode, 0)
        self.assertEqual(file.read_bytes(), installed)
        backups = list(self.directory.glob("settings.json.aiquotabar-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(json.loads(backups[0].read_text()), original)
        self.assertEqual(self.configure("--remove-completion-hooks").returncode, 0)
        self.assertEqual(json.loads(file.read_text()), original)
        self.assertTrue((self.directory / "settings.json.aiquotabar-disabled").exists())
        self.assertEqual(self.configure("--install-completion-hooks").returncode, 0)
        self.assertFalse((self.directory / "settings.json.aiquotabar-disabled").exists())

    def test_invalid_and_disabled_configuration_is_not_rewritten(self):
        file = self.directory / "settings.json"
        for value in ["broken JSON", '{"disableAllHooks":true}', '{"hooks":{"Stop":"invalid"}}']:
            file.write_text(value)
            self.assertNotEqual(self.configure("--install-completion-hooks").returncode, 0)
            self.assertEqual(file.read_text(), value)

    def test_symbolic_link_configuration_is_not_replaced(self):
        target = self.directory / "real-settings.json"
        target.write_text('{"keep":true}')
        link = self.directory / "settings.json"
        link.symlink_to(target)
        self.assertNotEqual(self.configure("--install-completion-hooks").returncode, 0)
        self.assertTrue(link.is_symlink())
        self.assertEqual(target.read_text(), '{"keep":true}')


if __name__ == "__main__":
    unittest.main()
