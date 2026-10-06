#!/usr/bin/env bash
# Records a short Waypaper demo (MP4 + optimized GIF) for README assets.
# Requires: ffmpeg, python3, an active macOS GUI session, and Screen Recording permission for Cursor or Terminal.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

out_dir="$root/assets/images"
mkdir -p "$out_dir"
demo_video="$(mktemp -t waypaper-demo).mp4"
capture_mov="$(mktemp -t waypaper-capture).mov"
capture_mp4="$out_dir/waypaper-demo.mp4"
capture_gif="$out_dir/waypaper-demo.gif"
probe="$(mktemp -t waypaper-screen).png"

cleanup() {
  rm -f "$demo_video" "$capture_mov" "$probe"
  if [[ -n "${app_pid:-}" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "Checking Screen Recording permission…"
if ! screencapture -x -m "$probe" 2>"$probe.err"; then
  echo "This process cannot capture the screen." >&2
  cat "$probe.err" >&2 || true
  echo "Turn on Screen Recording for Cursor in System Settings → Privacy & Security → Screen Recording, then run ./scripts/record_demo.sh again." >&2
  exit 1
fi
rm -f "$probe" "$probe.err"

echo "Building release app…"
python3 scripts/package.py

echo "Generating sample wallpaper video…"
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=12" \
  -f lavfi -i "sine=frequency=220:duration=12" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$demo_video"

app="$root/dist/Waypaper.app/Contents/MacOS/Waypaper"
echo "Launching Waypaper with sample import…"
"$app" "$demo_video" &
app_pid=$!
sleep 4

echo "Recording 14s of the main display…"
# ffmpeg's avfoundation screen input hangs on this macOS when the pixel format is rejected.
screencapture -v -V 14 -m -x -C "$capture_mov"

echo "Encoding GIF…"
ffmpeg -y -loglevel error -i "$capture_mov" \
  -vf "scale=960:-2:flags=lanczos,fps=15" \
  -c:v libx264 -pix_fmt yuv420p "$capture_mp4"
palette="$(mktemp -t waypaper-palette).png"
ffmpeg -y -loglevel error -i "$capture_mp4" \
  -vf "fps=10,scale=640:-1:flags=lanczos,palettegen=stats_mode=diff" "$palette"
ffmpeg -y -loglevel error -i "$capture_mp4" -i "$palette" \
  -lavfi "fps=10,scale=640:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
  "$capture_gif"
rm -f "$palette"

echo "Done:"
echo "  $capture_mp4"
echo "  $capture_gif"
