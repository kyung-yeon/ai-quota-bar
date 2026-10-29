"""Build and verify a portable universal macOS drag-and-drop disk image."""
from pathlib import Path
import hashlib
import os
import plistlib
import shutil
import subprocess
import tempfile

from package import ROOT, package


def verify_universal(binary):
    result = subprocess.run(["/usr/bin/lipo", "-archs", str(binary)], check=True, capture_output=True, text=True)
    if set(result.stdout.split()) != {"arm64", "x86_64"}:
        raise ValueError("The DMG requires an arm64 + x86_64 universal executable. Run make dmg.")


def stage_release(folder, binary):
    folder.mkdir(parents=True)
    app = package(binary=binary, destination=folder / "AiQuotaBar.app", portable=True)
    (folder / "Applications").symlink_to("/Applications", target_is_directory=True)
    (folder / ".background").mkdir()
    shutil.copy2(ROOT / "Assets/installer/background.tiff", folder / ".background/background.tiff")
    return app


def verify_layout(folder):
    layout = folder / ".DS_Store"
    if not layout.is_file() or layout.stat().st_size == 0:
        raise ValueError("Missing saved Finder layout")
    if not (folder / ".background/background.tiff").is_file():
        raise ValueError("Missing installer background")


def style_image(image, mountpoint):
    try:
        subprocess.run(["/usr/bin/hdiutil", "attach", str(image), "-nobrowse", "-mountpoint", str(mountpoint)], check=True)
        subprocess.run([
            "/usr/bin/osascript", str(ROOT / "Tools/layout-dmg.applescript"), str(mountpoint)
        ], check=True, timeout=90)
        verify_layout(mountpoint)
    finally:
        if os.path.ismount(mountpoint):
            subprocess.run(["/usr/bin/hdiutil", "detach", str(mountpoint)], check=True)


def verify_image(image, mountpoint):
    subprocess.run(["/usr/bin/hdiutil", "verify", str(image)], check=True)
    try:
        subprocess.run(["/usr/bin/hdiutil", "attach", str(image), "-readonly", "-nobrowse", "-mountpoint", str(mountpoint)], check=True)
        app = mountpoint / "AiQuotaBar.app"
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        verify_universal(app / "Contents/MacOS/AiQuotaBar")
        verify_layout(mountpoint)
        subprocess.run([
            "/usr/bin/osascript", str(ROOT / "Tools/verify-dmg-layout.applescript"), str(mountpoint)
        ], check=True, timeout=30)
        visible = {item.name for item in mountpoint.iterdir() if not item.name.startswith(".")}
        if visible != {"AiQuotaBar.app", "Applications"}:
            raise ValueError(f"Unexpected visible installer items: {visible}")
        if os.readlink(mountpoint / "Applications") != "/Applications":
            raise ValueError("Missing Applications shortcut")
        for name in ["Documentation/Install.txt", "Documentation/Install.ko.txt", "LICENSE"]:
            if not (app / "Contents/Resources" / name).is_file():
                raise ValueError(f"Missing installation document: {name}")
        for name in ["codex-path.txt", "claude-path.txt"]:
            if (app / "Contents/Resources" / name).exists():
                raise ValueError("Release contains a build-machine CLI path")
        # Runs offline; no account lookup or installation is performed.
        subprocess.run([str(app / "Contents/MacOS/AiQuotaBar"), "--self-test"], check=True)
    finally:
        if os.path.ismount(mountpoint):
            subprocess.run(["/usr/bin/hdiutil", "detach", str(mountpoint)], check=True)


def build_dmg():
    binary = ROOT / "build/universal/AiQuotaBar"
    verify_universal(binary)
    version = plistlib.loads((ROOT / "Info.plist").read_bytes())["CFBundleShortVersionString"]
    destination = ROOT / "dist" / f"AiQuotaBar-{version}-universal.dmg"
    destination.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aiquotabar-dmg-") as temporary:
        workspace = Path(temporary)
        stage = workspace / "contents"
        stage_release(stage, binary)
        writable = workspace / "layout.dmg"
        image = workspace / destination.name
        subprocess.run([
            "/usr/bin/hdiutil", "create", "-volname", f"AiQuotaBar {version}",
            "-srcfolder", str(stage), "-fs", "HFS+", "-format", "UDRW", str(writable)
        ], check=True)
        style_image(writable, workspace / "layout")
        subprocess.run(["/usr/bin/hdiutil", "convert", str(writable), "-format", "UDZO", "-o", str(image)], check=True)
        verify_image(image, workspace / "mounted")
        # Keep any previous artifact until the replacement has passed verification.
        shutil.copy2(image, destination)
    checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix(".dmg.sha256").write_text(f"{checksum}  {destination.name}\n")
    print(f"Verified DMG: {destination}")
    print(f"SHA-256: {checksum}")
    return destination


if __name__ == "__main__":
    build_dmg()
