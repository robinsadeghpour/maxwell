#!/bin/zsh
# Cuts build/demo/raw.mp4 (from demo/record.sh) into the launch video: drops the launch second,
# adds one short caption at a time in a band under the window, so no caption covers the app.
#   ./demo/cut.sh [raw.mp4] [out.mp4]      default out: build/demo/maxwell-demo.mp4
# Caption times are seconds in the cut; record.sh's key times minus START.
set -euo pipefail
cd "$(dirname "$0")/.."
RAW=${1:-build/demo/raw.mp4}
OUT=${2:-build/demo/maxwell-demo.mp4}
START=2.0
CAPS=build/demo/captions
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
rm -rf $CAPS; mkdir -p $CAPS

captions=(
  "0|4.4|Eleven Claude Code sessions, three projects, three accounts"
  "4.4|7|One asks for permission. It moves to Needs you."
  "7|14.5|⌘J opens it. Answer it right there."
  "14.5|23.5|Safe to close only when every check passes."
  "23.5|34|Close them all at once. Each is checked again first."
)

i=0
for c in $captions; do
  text=${c##*|}
  cat > $CAPS/$i.html <<EOF
<!doctype html><meta charset="utf-8">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@500&display=swap">
<style>html,body{margin:0;background:#0a0a0b;height:140px}
body{display:flex;align-items:center;justify-content:center;font:500 40px/1 Geist,-apple-system,sans-serif;color:#ededef;letter-spacing:-.01em}</style>
<body>$text</body>
EOF
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1920,140 --virtual-time-budget=3000 \
    --screenshot=$PWD/$CAPS/$i.png file://$PWD/$CAPS/$i.html 2>/dev/null
  i=$((i + 1))
done

# Base: the take, scaled to 1920 wide, with a 140 px band below; each caption shown in its window.
inputs=(-ss $START -i $RAW)
filter="[0:v]scale=1920:-2:flags=lanczos,pad=1920:ih+140:0:0:color=0x0a0a0b[v0]"
i=0
for c in $captions; do
  from=${c%%|*}; rest=${c#*|}; to=${rest%%|*}
  inputs+=(-i $CAPS/$i.png)
  filter+=";[v$i][$((i + 1)):v]overlay=0:H-140:enable='between(t,$from,$to)'[v$((i + 1))]"
  i=$((i + 1))
done
ffmpeg -v error -y $inputs -filter_complex "$filter" -map "[v$i]" -t 34 -r 30 \
  -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -movflags +faststart $OUT
# A smaller copy for the website and X (both autoplay muted).
ffmpeg -v error -y -i $OUT -vf scale=1280:-2:flags=lanczos -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p \
  -movflags +faststart ${OUT:r}-1280.mp4
ffmpeg -v error -y -ss 9 -i $OUT -frames:v 1 ${OUT:r}-poster.png
ls -la $OUT ${OUT:r}-1280.mp4 ${OUT:r}-poster.png
