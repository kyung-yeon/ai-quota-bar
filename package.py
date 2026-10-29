"""Package the locally built app, including its editable source."""
from pathlib import Path
import argparse
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent


def package(binary=None, destination=None, portable=False):
    binary = Path(binary or ROOT / "build/AiQuotaBar")
    app = Path(destination or ROOT / "dist/AiQuotaBar.app")
    if not binary.is_file():
        raise FileNotFoundError(f"Build the executable first: {binary}")
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    resources = contents / "Resources"
    (contents / "MacOS").mkdir(parents=True)
    (resources / "source").mkdir(parents=True)
    shutil.copy2(binary, contents / "MacOS/AiQuotaBar")
    shutil.copy2(ROOT / "Info.plist", contents / "Info.plist")
    shutil.copy2(ROOT / "AppIcon.icns", resources / "AppIcon.icns")
    shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
    shutil.copytree(ROOT / "Assets", resources / "Assets")
    for name in ["main.swift", "Info.plist", "Makefile", "README.md", "README.ko.md", "LICENSE", "package.py", "install.py", "dmg.py", "AppIcon.icns", "AppIcon.png", "icon-prompt.md", ".gitignore"]:
        shutil.copy2(ROOT / name, resources / "source" / name)
    for name in ["Sources", "Tests", "Assets", "Docs"]:
        shutil.copytree(ROOT / name, resources / "source" / name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"))
    if not portable:
        for name in ["codex", "claude"]:
            executable = shutil.which(name)
            if executable:
                (resources / f"{name}-path.txt").write_text(executable + "\n")
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--portable", action="store_true", help="Omit this machine's CLI paths for distribution")
    options = parser.parse_args()
    print(package(binary=options.binary, destination=options.output, portable=options.portable))
