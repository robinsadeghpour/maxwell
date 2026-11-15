#!/bin/zsh
# Records the launch demo: the real app on the invented world from demo/world.py, one continuous
# take driven by Maxwell's own test flags. Frames come from the app's own window (no screen
# recording permission). Needs an unlocked screen.
#   ./demo/record.sh [out.mp4]          default: build/demo/raw.mp4
#   WIDTH=2560 keeps the full Retina size, for edits that zoom in (demo/reel).
# Then ./demo/cut.sh adds the captions.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-build/demo/raw.mp4}
ROOT=$HOME/demo
FRAMES=build/demo/frames
LENGTH=36
python3 demo/world.py "$ROOT" --live >/dev/null
rm -rf $FRAMES; mkdir -p $FRAMES "$(dirname $OUT)"

# Times are seconds after launch. The story: what needs you, live; answer it in place; every
# group in one project; the evidence behind Safe to close; close them all.
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID $(cat $ROOT/.env) \
  build/Maxwell.app/Contents/MacOS/Maxwell --size ${SIZE:-1280x800} --retina --hide system \
  --select "Dark mode for settings" \
  --keys "9:cmd+j;12.5:1;16.5:cmd+1;25.5:cmd+0;26.5:cmd+shift+x" \
  --expand "Bump dependencies" --expand-after 19 \
  --confirm-after 31 \
  --record $PWD/$FRAMES --record-for $LENGTH --quit-after $((LENGTH + 2)) >build/demo/run.log 2>&1 &
APP=$!
sleep 6.3; python3 demo/world.py ask passkeys "$ROOT"
wait $APP || true
grep -E 'keys|expanded|confirm|recorded' build/demo/run.log

# Frames are named by their time in ms; hold each until the next so the video keeps real time.
python3 - $FRAMES <<'EOF'
import os, sys
d = sys.argv[1]
fs = sorted(f for f in os.listdir(d) if f.endswith(".tiff"))
with open(f"{d}/list.txt", "w") as out:
    for a, b in zip(fs, fs[1:] + [None]):
        out.write(f"file '{a}'\nduration {((int(b[:-5]) if b else int(a[:-5]) + 33) - int(a[:-5])) / 1000:.3f}\n")
    out.write(f"file '{fs[-1]}'\n")
EOF
ffmpeg -v error -y -f concat -safe 0 -i $FRAMES/list.txt -vf "fps=30,scale=${WIDTH:-1920}:-2:flags=lanczos,format=yuv420p" \
  -c:v libx264 -preset slow -crf 16 -movflags +faststart $OUT
rm -rf $FRAMES
echo $OUT
