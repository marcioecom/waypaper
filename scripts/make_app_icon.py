#!/usr/bin/env python3
"""Build AppIcon.icns from a square PNG master using sips and iconutil."""
import argparse
import subprocess
import tempfile
from pathlib import Path

ICONSET_ENTRIES = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)


def resize(source: Path, destination: Path, size: int) -> None:
    subprocess.run(
        ["sips", "-z", str(size), str(size), str(source), "--out", str(destination)],
        check=True,
        capture_output=True,
    )


def apply_rounded_mask(source: Path, destination: Path, dimension: int = 1024) -> None:
    mask_script = Path(__file__).resolve().parent / "apply_icon_rounded_mask.swift"
    subprocess.run(
        ["swift", str(mask_script), str(source), str(destination), str(dimension)],
        check=True,
    )


def build_icns(master: Path, output_icns: Path) -> None:
    output_icns.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="waypaper-icon-") as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for filename, size in ICONSET_ENTRIES:
            resize(master, iconset / filename, size)
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(output_icns)],
            check=True,
        )


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--master",
        type=Path,
        default=root / "Sources" / "Waypaper" / "Resources" / "AppIcon.png",
        help="Square PNG master (1024px recommended)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=root / "Sources" / "Waypaper" / "Resources" / "AppIcon.icns",
        help="Destination .icns path",
    )
    parser.add_argument(
        "--mask-from",
        type=Path,
        default=None,
        help="Apply rounded-square alpha mask from this raster into --master (1024px) before building .icns",
    )
    parser.add_argument(
        "--mask-dimension",
        type=int,
        default=1024,
        help="Output pixel size when using --mask-from",
    )
    args = parser.parse_args()
    master = args.master.resolve()
    if not master.is_file():
        raise SystemExit(f"Master PNG not found: {master}")
    if args.mask_from is not None:
        source = args.mask_from.resolve()
        if not source.is_file():
            raise SystemExit(f"Mask source not found: {source}")
        apply_rounded_mask(source, master, args.mask_dimension)
    build_icns(master, args.out.resolve())
    print(f"Ready: {args.out.resolve()}")


if __name__ == "__main__":
    main()
