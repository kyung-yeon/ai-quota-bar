"""Install or update one local AiQuotaBar app and its login item."""
from pathlib import Path
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent
LABEL = "local.kyungyeon.ai-quota-bar"
OLD_LABEL = "local.kyungyeon.codex-weekly-menubar"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def installed_target(candidates, agent):
    if agent.is_file():
        try:
            arguments = plistlib.loads(agent.read_bytes()).get("ProgramArguments", [])
            for app in candidates:
                if app.exists() and arguments == [str(app / "Contents/MacOS/AiQuotaBar")]:
                    return app
        except (ValueError, plistlib.InvalidFileException):
            pass
    return next((app for app in candidates if app.exists()), candidates[0])


def stop_process(bundle, binary):
    pattern = f"^{re.escape(str(bundle / 'Contents/MacOS' / binary))}( |$)"
    subprocess.run(["/usr/bin/pkill", "-TERM", "-f", pattern], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 5
    while subprocess.run(["/usr/bin/pgrep", "-f", pattern], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Quit {bundle.name} before installing again.")
        time.sleep(0.05)


def remove(path):
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()


def check_removal_access(paths):
    for path in paths:
        directories = [path.parent]
        if path.is_dir():
            def failed(error):
                raise error
            directories.extend(Path(folder) for folder, _, _ in os.walk(path, onerror=failed))
        for directory in directories:
            if not os.access(directory, os.W_OK | os.X_OK):
                raise PermissionError(f"Write access is required to replace or remove: {directory}")


def install(root=ROOT, home=None, system_applications=Path("/Applications")):
    home = home or Path.home()
    source = root / "dist/AiQuotaBar.app"
    agents = home / "Library/LaunchAgents"
    agent = agents / f"{LABEL}.plist"
    old_agent = agents / f"{OLD_LABEL}.plist"
    candidates = [home / "Applications/AiQuotaBar.app", system_applications / "AiQuotaBar.app"]
    legacy = [folder / "Codex Weekly.app" for folder in [home / "Applications", system_applications]]
    app = installed_target(candidates, agent)
    previous = [path for path in candidates + legacy + [agent, old_agent] if path.exists() or path.is_symlink()]
    if any(path.is_symlink() for path in [source] + previous):
        raise RuntimeError("Replace symbolic-link installations with a regular app bundle before installing.")
    if not (source / "Contents/MacOS/AiQuotaBar").is_file():
        raise SystemExit("Run make package before installing.")
    check_removal_access(previous + [source])
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)], check=True)
    app.parent.mkdir(parents=True, exist_ok=True)
    agents.mkdir(parents=True, exist_ok=True)
    domain = f"gui/{os.getuid()}"

    def bootout(label):
        subprocess.run(["/bin/launchctl", "bootout", f"{domain}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Stage before stopping anything. Move old files aside only during replacement;
    # no persistent backup app is created for Launchpad to index.
    moved = []
    app_installed = False
    agent_written = False
    with tempfile.TemporaryDirectory(prefix=".AiQuotaBar-install-", dir=app.parent) as temporary:
        staged = Path(temporary) / "replacement"
        shutil.copytree(source, staged, symlinks=True)
        try:
            bootout(OLD_LABEL)
            bootout(LABEL)
            for bundle in candidates:
                stop_process(bundle, "AiQuotaBar")
            for bundle in legacy:
                stop_process(bundle, "CodexWeeklyMenuBar")
            stop_process(source, "AiQuotaBar")
            for path in previous:
                held = path.with_name(f".AiQuotaBar-previous-{uuid.uuid4().hex}")
                path.rename(held)
                moved.append((path, held))
            staged.rename(app)
            app_installed = True
            configuration = {
                "Label": LABEL,
                "ProgramArguments": [str(app / "Contents/MacOS/AiQuotaBar")],
                "RunAtLoad": True,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
                "StandardOutPath": "/dev/null",
                "StandardErrorPath": "/dev/null",
            }
            agent_written = True
            agent.write_bytes(plistlib.dumps(configuration))
            agent.chmod(0o644)
            subprocess.run(["/bin/launchctl", "bootstrap", domain, str(agent)], check=True)
        except Exception as failure:
            recovery_errors = []

            def recover(action):
                try:
                    action()
                except Exception as error:
                    recovery_errors.append(str(error))

            if app_installed:
                recover(lambda: bootout(LABEL))
                recover(lambda: stop_process(app, "AiQuotaBar"))
                recover(lambda: remove(app))
            if agent_written and agent.exists():
                recover(agent.unlink)
            for path, held in reversed(moved):
                recover(lambda: held.rename(path))
            for path in [old_agent, agent]:
                if path.exists():
                    recover(lambda: subprocess.run(["/bin/launchctl", "bootstrap", domain, str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            if recovery_errors:
                retained = [str(held) for _, held in moved if held.exists()]
                detail = f" Original files retained at: {', '.join(retained)}." if retained else " Previous files restored; check that the app is running."
                raise RuntimeError(f"Installation failed: {failure}. Recovery errors: {'; '.join(recovery_errors)}.{detail}") from failure
            raise

    for bundle in candidates + legacy + [source]:
        if bundle != app:
            subprocess.run([LSREGISTER, "-u", str(bundle)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cleanup_errors = []
    for path in [held for _, held in moved] + [source]:
        try:
            remove(path)
        except OSError as error:
            cleanup_errors.append(f"{path}: {error}")
    subprocess.run([LSREGISTER, "-f", str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if cleanup_errors:
        raise RuntimeError(f"Installed and started {app}, but could not finish cleanup: {'; '.join(cleanup_errors)}")
    print(f"Installed and started: {app}")
    print(f"Login item: {agent}")
    return app


if __name__ == "__main__":
    install()
