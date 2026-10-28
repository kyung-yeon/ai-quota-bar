"""Package the locally built app, including its editable source."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent
app = root / "dist" / "AiQuotaBar.app"
if app.exists():
    shutil.rmtree(app)
contents = app / "Contents"
resources = contents / "Resources"
(contents / "MacOS").mkdir(parents=True)
(resources / "source").mkdir(parents=True)
shutil.copy2(root / "build" / "AiQuotaBar", contents / "MacOS" / "AiQuotaBar")
shutil.copy2(root / "Info.plist", contents / "Info.plist")
shutil.copy2(root / "AppIcon.icns", resources / "AppIcon.icns")
shutil.copytree(root / "Assets", resources / "Assets")
for name in ["main.swift", "Info.plist", "Makefile", "README.md", "README.ko.md", "package.py", "install.py", "AppIcon.icns", "AppIcon.png", "icon-prompt.md", ".gitignore"]:
    shutil.copy2(root / name, resources / "source" / name)
for name in ["Sources", "Tests", "Assets"]:
    shutil.copytree(root / name, resources / "source" / name)
for name in ["codex", "claude"]:
    executable = shutil.which(name)
    if executable:
        (resources / f"{name}-path.txt").write_text(executable + "\n")
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(app)
