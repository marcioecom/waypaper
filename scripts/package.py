#!/usr/bin/env python3
"""Build an ad-hoc signed macOS app and ZIP using Apple tools and the stdlib."""
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    build = ["swift", "build", "--package-path", str(root), "-c", "release", "--arch", "arm64"]
    subprocess.run(build, check=True)
    binary_directory = Path(subprocess.check_output(build + ["--show-bin-path"], text=True).strip())
    output = root / "dist" / "Waypaper.zip"
    output.parent.mkdir(exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="waypaper-package-") as temporary:
        app = Path(temporary) / "Waypaper.app"
        contents = app / "Contents"
        executable_directory = contents / "MacOS"
        executable_directory.mkdir(parents=True)
        shutil.copy2(binary_directory / "Waypaper", executable_directory / "Waypaper")
        with (contents / "Info.plist").open("wb") as file:
            plistlib.dump({
                "CFBundleDevelopmentRegion": "pt_BR",
                "CFBundleDisplayName": "Waypaper",
                "CFBundleName": "Waypaper",
                "CFBundleExecutable": "Waypaper",
                "CFBundleIdentifier": "dev.waypaper.app",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0",
                "LSUIElement": True,
                "NSHighResolutionCapable": True,
            }, file)
        subprocess.run(["plutil", "-lint", str(contents / "Info.plist")], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=True)
        archive = Path(temporary) / "Waypaper.zip"
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
        # Publish only a completely built and signed archive.
        shutil.copy2(archive, output)
    print(f"Ready: {output}")


if __name__ == "__main__":
    main()
