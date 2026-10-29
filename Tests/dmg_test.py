"""Check release architecture validation and the drag-and-drop layout."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dmg


class DiskImageTests(unittest.TestCase):
    def test_universal_binary_is_accepted(self):
        with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, stdout="x86_64 arm64\n")):
            dmg.verify_universal(Path("sample-binary"))

    def test_single_architecture_is_rejected(self):
        with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, stdout="arm64\n")):
            with self.assertRaises(ValueError):
                dmg.verify_universal(Path("sample-binary"))

    def test_drag_and_drop_layout_contains_portable_app_and_bilingual_guides(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "binary"
            binary.write_bytes(b"fixture")
            stage = root / "contents"
            with patch("subprocess.run"):
                app = dmg.stage_release(stage, binary)
            self.assertEqual((stage / "Applications").readlink(), Path("/Applications"))
            self.assertTrue((app / "Contents/MacOS/AiQuotaBar").is_file())
            self.assertEqual({item.name for item in stage.iterdir() if not item.name.startswith(".")}, {"AiQuotaBar.app", "Applications"})
            self.assertTrue((app / "Contents/Resources/Documentation/Install.txt").is_file())
            self.assertTrue((app / "Contents/Resources/Documentation/Install.ko.txt").is_file())
            self.assertTrue((app / "Contents/Resources/LICENSE").is_file())
            self.assertTrue((stage / ".background/background.tiff").is_file())
            self.assertFalse((app / "Contents/Resources/codex-path.txt").exists())

    def test_missing_finder_layout_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / ".background").mkdir()
            (folder / ".background/background.tiff").write_bytes(b"background")
            with self.assertRaisesRegex(ValueError, "Finder layout"):
                dmg.verify_layout(folder)

    def test_missing_installer_background_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / ".DS_Store").write_bytes(b"saved Finder layout")
            with self.assertRaisesRegex(ValueError, "background"):
                dmg.verify_layout(folder)


if __name__ == "__main__":
    unittest.main()
