#!/usr/bin/env python3
"""Build a short demo GIF from a real smoke-test UI capture over a synthetic wallpaper clip."""
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


def root() -> Path:
    return Path(__file__).resolve().parent.parent


def ensure_app() -> Path:
    app = root() / "dist" / "Waypaper.app" / "Contents" / "MacOS" / "Waypaper"
    if not app.is_file():
        subprocess.run(["python3", "scripts/package.py"], cwd=root(), check=True)
    return app


def synthetic_wallpaper(path: Path) -> None:
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24:duration=8",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", str(path),
        ],
        check=True,
    )


def smoke_ui_snapshot(app: Path, wallpaper: Path) -> Path:
    completed = subprocess.run(
        [str(app), "--smoke-test", str(wallpaper)],
        cwd=root(), check=True, capture_output=True, text=True,
    )
    for line in completed.stdout.splitlines():
        if line.startswith("UI snapshot:"):
            snapshot = Path(line.split(":", 1)[1].strip())
            if snapshot.is_file():
                return snapshot
    raise SystemExit("Smoke test did not emit a UI snapshot path")


def render_gif(wallpaper: Path, ui: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="waypaper-demo-") as temporary:
        mp4 = Path(temporary) / "composite.mp4"
        palette = Path(temporary) / "palette.png"
        subprocess.run(
            [
                "ffmpeg", "-y", "-loglevel", "error",
                "-stream_loop", "-1", "-i", str(wallpaper),
                "-loop", "1", "-i", str(ui),
                "-filter_complex",
                (
                    "[1:v]scale=920:-1,format=rgba[ui];"
                    "[0:v][ui]overlay=x=(main_w-overlay_w)/2:"
                    "y=(main_h-overlay_h)/2+12*sin(2*PI*t/2.5):shortest=1,"
                    "scale=720:-2:flags=lanczos,fps=12"
                ),
                "-t", "6", "-an", str(mp4),
            ],
            check=True,
        )
        subprocess.run(
            [
                "ffmpeg", "-y", "-loglevel", "error", "-i", str(mp4),
                "-vf", "fps=10,scale=640:-1:flags=lanczos,palettegen=stats_mode=diff",
                str(palette),
            ],
            check=True,
        )
        subprocess.run(
            [
                "ffmpeg", "-y", "-loglevel", "error", "-i", str(mp4), "-i", str(palette),
                "-lavfi",
                "fps=10,scale=640:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3",
                str(destination),
            ],
            check=True,
        )


def main() -> None:
    out = root() / "assets" / "images" / "waypaper-demo.gif"
    app = ensure_app()
    with tempfile.TemporaryDirectory(prefix="waypaper-wallpaper-") as temporary:
        wallpaper = Path(temporary) / "wallpaper.mp4"
        synthetic_wallpaper(wallpaper)
        ui = smoke_ui_snapshot(app, wallpaper)
        render_gif(wallpaper, ui, out)
    size_kb = out.stat().st_size // 1024
    print(f"Ready: {out} ({size_kb} KiB)")


if __name__ == "__main__":
    main()
