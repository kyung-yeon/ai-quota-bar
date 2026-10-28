"""Exercise installation and rollback in a temporary home, without launching apps."""
from pathlib import Path
import contextlib
import io
import runpy
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


class InstallationTests(unittest.TestCase):
    def run_installer(self, fail_bootstrap=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        home = root / "home"
        old_app = home / "Applications/Codex Weekly.app"
        old_app.mkdir(parents=True)
        (old_app / "original").write_text("old app")
        agents = home / "Library/LaunchAgents"
        agents.mkdir(parents=True)
        old_agent = agents / "local.kyungyeon.codex-weekly-menubar.plist"
        old_agent.write_text("old login item")
        source = root / "dist/AiQuotaBar.app/Contents/MacOS"
        source.mkdir(parents=True)
        (source / "AiQuotaBar").write_text("new app")
        script = root / "install.py"
        shutil.copy2(Path(__file__).resolve().parents[1] / "install.py", script)

        def run(command, **kwargs):
            if fail_bootstrap and "bootstrap" in command and command[-1].endswith("local.kyungyeon.ai-quota-bar.plist"):
                raise subprocess.CalledProcessError(5, command)
            return subprocess.CompletedProcess(command, 0)

        with patch("pathlib.Path.home", return_value=home), patch("subprocess.run", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            if fail_bootstrap:
                with self.assertRaises(subprocess.CalledProcessError):
                    runpy.run_path(str(script), run_name="__main__")
            else:
                runpy.run_path(str(script), run_name="__main__")
        return home, old_app, old_agent

    def test_upgrade_preserves_backup_and_replaces_old_login_item(self):
        home, old_app, old_agent = self.run_installer()
        self.assertFalse(old_app.exists())
        self.assertFalse(old_agent.exists())
        self.assertTrue((home / "Applications/AiQuotaBar.app/Contents/MacOS/AiQuotaBar").exists())
        backups = list((home / "Library/Application Support/AiQuotaBar/Backups").iterdir())
        self.assertEqual((backups[0] / "Codex Weekly.app/original").read_text(), "old app")
        self.assertTrue((home / "Library/LaunchAgents/local.kyungyeon.ai-quota-bar.plist").exists())

    def test_failed_launch_restores_previous_installation(self):
        home, old_app, old_agent = self.run_installer(fail_bootstrap=True)
        self.assertEqual((old_app / "original").read_text(), "old app")
        self.assertEqual(old_agent.read_text(), "old login item")
        self.assertFalse((home / "Applications/AiQuotaBar.app").exists())
        self.assertFalse((home / "Library/LaunchAgents/local.kyungyeon.ai-quota-bar.plist").exists())


if __name__ == "__main__":
    unittest.main()
