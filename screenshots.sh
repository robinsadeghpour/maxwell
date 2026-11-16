#!/bin/zsh
# Re-takes the docs/screenshots set from the running app (its own window, no screen-recording
# permission needed). Needs background test sessions named mxtest-* and an unlocked screen.
#   ./screenshots.sh <session name> [limited session name]
cd "$(dirname "$0")"
mkdir -p docs/screenshots   # gitignored: these show your real sessions
BIN=build/Maxwell.app/Contents/MacOS/Maxwell
CLEAN=(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION)
sel=${1:?session name}; lim=${2:-$1}
shot() { local out=$1; shift; $CLEAN $BIN "$@" --snap docs/screenshots/$out.png --snap-after 4.5 --quit-after 5.5 2>&1 | grep -q snapshot && echo "docs/screenshots/$out.png"; }
# Maxwell Dev reopens the terminals open when it last quit; the screenshots start without any.
defaults delete dev.maxwell.app.dev Maxwell.terminals 2>/dev/null || true
caffeinate -u -t 120 &
for th in graphite silver paper; do
  shot session-$th --theme $th --select $sel
  shot limited-$th --theme $th --select $lim
  shot palette-$th --theme $th --select $sel --palette 1
done
shot new-session-graphite --select $sel --new 1
shot settings-graphite --settings 1
shot settings-paper --theme paper --settings 1
