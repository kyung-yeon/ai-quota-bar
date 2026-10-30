"""Exercise command installation in isolated folders without launching apps."""
from pathlib import Path
import contextlib
import importlib.util
import io
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class InstallationTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("aiquota_install", ROOT / "install.py")
        self.installer = importlib.util.module_from_spec(spec)
        # Import must never install or stop a running app.
        with patch("subprocess.run") as run:
            spec.loader.exec_module(self.installer)
        run.assert_not_called()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.system = self.root / "Applications"
        self.agent = self.home / "Library/LaunchAgents/local.kyungyeon.ai-quota-bar.plist"
        self.source = self.root / "dist/AiQuotaBar.app"
        self.bundle(self.source, "new")

    def bundle(self, path, marker):
        binary = path / "Contents/MacOS/AiQuotaBar"
        binary.parent.mkdir(parents=True)
        binary.write_text(marker)
        return path

    def install(self, fail_bootstrap=False):
        bootstrap_calls = 0
        def run(command, **kwargs):
            nonlocal bootstrap_calls
            if fail_bootstrap and "bootstrap" in command:
                bootstrap_calls += 1
                if bootstrap_calls == 1:
                    raise subprocess.CalledProcessError(5, command)
            return subprocess.CompletedProcess(command, 1 if "pgrep" in command[0] else 0)
        with patch("subprocess.run", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            return self.installer.install(root=self.root, home=self.home, system_applications=self.system)

    def test_fresh_install_uses_user_applications_and_removes_staging_bundle(self):
        target = self.install()
        self.assertEqual(target, self.home / "Applications/AiQuotaBar.app")
        self.assertEqual((target / "Contents/MacOS/AiQuotaBar").read_text(), "new")
        self.assertEqual(plistlib.loads(self.agent.read_bytes())["ProgramArguments"], [str(target / "Contents/MacOS/AiQuotaBar")])
        self.assertFalse(self.source.exists())
        self.assertFalse((self.home / "Library/Application Support/AiQuotaBar/Backups").exists())

    def test_existing_system_install_is_replaced_without_a_second_copy(self):
        target = self.bundle(self.system / "AiQuotaBar.app", "old")
        self.assertEqual(self.install(), target)
        self.assertEqual((target / "Contents/MacOS/AiQuotaBar").read_text(), "new")
        self.assertFalse((self.home / "Applications/AiQuotaBar.app").exists())
        self.assertEqual(list(self.system.iterdir()), [target])

    def test_duplicate_copies_follow_existing_login_item_and_are_removed(self):
        system = self.bundle(self.system / "AiQuotaBar.app", "system old")
        user = self.bundle(self.home / "Applications/AiQuotaBar.app", "user old")
        self.agent.parent.mkdir(parents=True)
        self.agent.write_bytes(plistlib.dumps({"ProgramArguments": [str(user / "Contents/MacOS/AiQuotaBar")]}))
        self.assertEqual(self.install(), user)
        self.assertFalse(system.exists())
        self.assertEqual(list(user.parent.iterdir()), [user])

    def test_failed_launch_restores_previous_installation(self):
        target = self.bundle(self.system / "AiQuotaBar.app", "old")
        self.agent.parent.mkdir(parents=True)
        original = plistlib.dumps({"ProgramArguments": [str(target / "Contents/MacOS/AiQuotaBar")]})
        self.agent.write_bytes(original)
        with self.assertRaises(subprocess.CalledProcessError):
            self.install(fail_bootstrap=True)
        self.assertEqual((target / "Contents/MacOS/AiQuotaBar").read_text(), "old")
        self.assertEqual(self.agent.read_bytes(), original)
        self.assertTrue(self.source.exists())
        self.assertEqual(list(self.system.iterdir()), [target])

    def test_legacy_install_and_login_item_are_replaced(self):
        old = self.bundle(self.home / "Applications/Codex Weekly.app", "legacy")
        old_agent = self.agent.with_name("local.kyungyeon.codex-weekly-menubar.plist")
        old_agent.parent.mkdir(parents=True)
        old_agent.write_text("legacy login item")
        self.install()
        self.assertFalse(old.exists())
        self.assertFalse(old_agent.exists())

    def test_unremovable_old_bundle_fails_before_stopping_or_replacing(self):
        target = self.bundle(self.system / "AiQuotaBar.app", "old")
        directory = target / "Contents/MacOS"
        directory.chmod(0o555)
        try:
            with self.assertRaises(PermissionError), patch("subprocess.run") as run:
                self.installer.install(root=self.root, home=self.home, system_applications=self.system)
            self.assertFalse(any("bootout" in call.args[0] for call in run.call_args_list))
            self.assertEqual((directory / "AiQuotaBar").read_text(), "old")
            self.assertEqual(list(self.system.iterdir()), [target])
            self.assertTrue(self.source.exists())
        finally:
            directory.chmod(0o755)

    def test_rollback_stop_failure_does_not_prevent_restoring_files(self):
        target = self.bundle(self.system / "AiQuotaBar.app", "old")
        self.agent.parent.mkdir(parents=True)
        original = plistlib.dumps({"ProgramArguments": [str(target / "Contents/MacOS/AiQuotaBar")]})
        self.agent.write_bytes(original)

        def stop(bundle, binary):
            if bundle == target and (target / "Contents/MacOS/AiQuotaBar").read_text() == "new":
                raise RuntimeError("replacement did not stop")

        with patch.object(self.installer, "stop_process", side_effect=stop):
            with self.assertRaisesRegex(RuntimeError, "replacement did not stop"):
                self.install(fail_bootstrap=True)
        self.assertEqual((target / "Contents/MacOS/AiQuotaBar").read_text(), "old")
        self.assertEqual(self.agent.read_bytes(), original)
        self.assertEqual(list(self.system.iterdir()), [target])
        self.assertTrue(self.source.exists())

    def test_unexpected_cleanup_failure_reports_leftovers_and_cleans_other_files(self):
        target = self.bundle(self.system / "AiQuotaBar.app", "old")
        real_remove = self.installer.remove

        def remove(path):
            if path.name.startswith(".AiQuotaBar-previous-"):
                raise PermissionError("permission changed during installation")
            real_remove(path)

        with patch.object(self.installer, "remove", side_effect=remove):
            with self.assertRaisesRegex(RuntimeError, "Installed and started.*could not finish cleanup") as failure:
                self.install()
        self.assertEqual((target / "Contents/MacOS/AiQuotaBar").read_text(), "new")
        self.assertFalse(self.source.exists())
        retained = next(self.system.glob(".AiQuotaBar-previous-*"))
        self.assertIn(str(retained), str(failure.exception))


if __name__ == "__main__":
    unittest.main()
