#!/usr/bin/env python3
"""Build an ad-hoc signed macOS app, ZIP, and DMG using Apple tools and the stdlib."""
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def swift_binary_directory(root: Path) -> Path:
    build = [
        "swift",
        "build",
        "--package-path",
        str(root),
        "-c",
        "release",
        "--arch",
        "arm64",
    ]
    subprocess.run(build, check=True)
    return Path(subprocess.check_output(build + ["--show-bin-path"], text=True).strip())


def resource_bundles(binary_directory: Path) -> list[Path]:
    bundles = sorted(binary_directory.glob("Waypaper_*.bundle"))
    if not bundles:
        raise SystemExit(
            f"No SwiftPM resource bundle found in {binary_directory}. "
            "Ensure the Waypaper target declares resources (e.g. Waypaper_Waypaper.bundle)."
        )
    return bundles


def assemble_app(root: Path, binary_directory: Path, staging_app: Path) -> None:
    contents = staging_app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)

    shutil.copy2(binary_directory / "Waypaper", macos / "Waypaper")

    for bundle in resource_bundles(binary_directory):
        destination = resources / bundle.name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(bundle, destination)

    app_icon_icns = root / "Sources" / "Waypaper" / "Resources" / "AppIcon.icns"
    if app_icon_icns.is_file():
        shutil.copy2(app_icon_icns, resources / "AppIcon.icns")

    info: dict[str, object] = {
        "CFBundleDevelopmentRegion": "pt_BR",
        "CFBundleDisplayName": "Waypaper",
        "CFBundleName": "Waypaper",
        "CFBundleExecutable": "Waypaper",
        "CFBundleIdentifier": "dev.waypaper.app",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.1.0",
        "CFBundleVersion": "2",
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
    }
    if app_icon_icns.is_file():
        info["CFBundleIconFile"] = "AppIcon"

    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump(info, file)
    subprocess.run(["plutil", "-lint", str(contents / "Info.plist")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(staging_app)], check=True)
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(staging_app)],
        check=True,
    )


def write_zip(app: Path, destination: Path) -> None:
    archive = destination.with_suffix(".zip.part")
    subprocess.run(
        ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)],
        check=True,
    )
    shutil.move(str(archive), destination)


def write_dmg(app: Path, destination: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="waypaper-dmg-") as temporary:
        source_folder = Path(temporary) / "dmg-root"
        source_folder.mkdir()
        shutil.copytree(app, source_folder / app.name, symlinks=True)
        applications = source_folder / "Applications"
        if not applications.exists():
            applications.symlink_to("/Applications")
        subprocess.run(
            [
                "hdiutil",
                "create",
                "-volname",
                "Waypaper",
                "-srcfolder",
                str(source_folder),
                "-ov",
                "-format",
                "UDZO",
                str(destination),
            ],
            check=True,
        )


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    dist = root / "dist"
    dist.mkdir(exist_ok=True)
    zip_output = dist / "Waypaper.zip"
    dmg_output = dist / "Waypaper.dmg"

    binary_directory = swift_binary_directory(root)

    with tempfile.TemporaryDirectory(prefix="waypaper-package-") as temporary:
        app = Path(temporary) / "Waypaper.app"
        assemble_app(root, binary_directory, app)
        write_zip(app, zip_output)
        write_dmg(app, dmg_output)

    bundle_names = [path.name for path in resource_bundles(binary_directory)]
    print(f"Ready: {zip_output}")
    print(f"Ready: {dmg_output}")
    print(f"SwiftPM resource bundles packaged under Contents/Resources/: {', '.join(bundle_names)}")


if __name__ == "__main__":
    main()
