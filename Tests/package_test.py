"""Verify portable release packaging without invoking signing tools."""
from pathlib import Path
import importlib.util
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class PackageTests(unittest.TestCase):
    def load_packager(self):
        spec = importlib.util.spec_from_file_location("aiquota_package", ROOT / "package.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_import_does_not_replace_or_sign_an_app(self):
        with patch("shutil.rmtree") as remove, patch("shutil.copy2"), patch("shutil.copytree"), patch("subprocess.run") as run:
            self.load_packager()
        remove.assert_not_called()
        run.assert_not_called()

    def test_portable_bundle_omits_builder_cli_paths_and_keeps_license(self):
        packager = self.load_packager()
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            binary = folder / "universal-binary"
            binary.write_bytes(b"test universal executable")
            app = folder / "AiQuotaBar.app"
            with patch("subprocess.run"), patch("shutil.which", return_value="/Users/build-machine/bin/cli"):
                packager.package(binary=binary, destination=app, portable=True)
            resources = app / "Contents/Resources"
            self.assertEqual((app / "Contents/MacOS/AiQuotaBar").read_bytes(), binary.read_bytes())
            self.assertFalse((resources / "codex-path.txt").exists())
            self.assertFalse((resources / "claude-path.txt").exists())
            self.assertEqual((resources / "LICENSE").read_bytes(), (ROOT / "LICENSE").read_bytes())
            self.assertTrue((resources / "source/dmg.py").is_file())
            self.assertTrue((resources / "Assets/screenshots/aiquotabar-preview.png").is_file())

    def test_missing_binary_does_not_remove_existing_bundle(self):
        packager = self.load_packager()
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            app = folder / "AiQuotaBar.app"
            app.mkdir()
            marker = app / "original"
            marker.write_text("keep existing output")
            with self.assertRaises(FileNotFoundError):
                packager.package(binary=folder / "missing", destination=app, portable=True)
            self.assertEqual(marker.read_text(), "keep existing output")


if __name__ == "__main__":
    unittest.main()
