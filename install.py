"""Install AiQuotaBar for the current macOS user, preserving a rollback copy."""
from datetime import datetime
from pathlib import Path
import os
import plistlib
import re
import shutil
import subprocess

root = Path(__file__).resolve().parent
source = root / "dist" / "AiQuotaBar.app"
home = Path.home()
applications = home / "Applications"
agents = home / "Library" / "LaunchAgents"
label = "local.kyungyeon.ai-quota-bar"
old_label = "local.kyungyeon.codex-weekly-menubar"
app = applications / "AiQuotaBar.app"
old_app = applications / "Codex Weekly.app"
agent = agents / f"{label}.plist"
old_agent = agents / f"{old_label}.plist"
domain = f"gui/{os.getuid()}"

if not (source / "Contents/MacOS/AiQuotaBar").is_file():
    raise SystemExit("Run make package before installing.")
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)], check=True)
backup = home / "Library/Application Support/AiQuotaBar/Backups" / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
backup.mkdir(parents=True)
previous = [path for path in [app, old_app, agent, old_agent] if path.exists()]
for path in previous:
    target = backup / path.name
    if path.is_dir():
        shutil.copytree(path, target, symlinks=True)
    else:
        shutil.copy2(path, target)

# Stage the replacement before stopping the current application.
applications.mkdir(parents=True, exist_ok=True)
agents.mkdir(parents=True, exist_ok=True)
staged = applications / f".AiQuotaBar-install-{os.getpid()}.app"
shutil.copytree(source, staged, symlinks=True)


def stop(name, bundle, binary):
    subprocess.run(["/bin/launchctl", "bootout", f"{domain}/{name}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    executable = str(bundle / "Contents/MacOS" / binary)
    subprocess.run(["/usr/bin/pkill", "-TERM", "-f", f"^{re.escape(executable)}( |$)"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


try:
    stop(old_label, old_app, "CodexWeeklyMenuBar")
    stop(label, app, "AiQuotaBar")
    if app.exists():
        shutil.rmtree(app)
    staged.rename(app)
    configuration = {
        "Label": label,
        "ProgramArguments": [str(app / "Contents/MacOS/AiQuotaBar")],
        "RunAtLoad": True,
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive",
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
    }
    agent.write_bytes(plistlib.dumps(configuration))
    agent.chmod(0o644)
    subprocess.run(["/bin/launchctl", "bootstrap", domain, str(agent)], check=True)
    if old_app.exists():
        shutil.rmtree(old_app)
    if old_agent.exists():
        old_agent.unlink()
except Exception:
    stop(label, app, "AiQuotaBar")
    if app.exists():
        shutil.rmtree(app)
    if agent.exists():
        agent.unlink()
    for path in previous:
        if path.exists():
            continue
        saved = backup / path.name
        if saved.is_dir():
            shutil.copytree(saved, path, symlinks=True)
        else:
            shutil.copy2(saved, path)
    for path in [old_agent, agent]:
        if path.exists():
            subprocess.run(["/bin/launchctl", "bootstrap", domain, str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    raise
finally:
    if staged.exists():
        shutil.rmtree(staged)
print(f"Installed and started: {app}")
print(f"Login item: {agent}")
print(f"Previous installation backup: {backup}")
