#!/bin/zsh
# Screenshots of the Slack panel in Maxwell, from demo.json (invented people, no real Slack).
#   ./snap.sh <out-dir> [layout] [theme...]     layout: line (ships) | asks | people
# Needs ../../build/Maxwell.app with the plugin host. Uses scratch state and plugin folders.
set -euo pipefail
cd "$(dirname "$0")"
out=${1:?out dir}; layout=${2:-line}; shift 2 2>/dev/null || shift $#
themes=(${@:-graphite silver silver-light paper})
./build.sh >/dev/null
tmp=$(mktemp -d)
mkdir -p $tmp/state $tmp/plugins $out
cp -R build/slack $tmp/plugins/slack
cp demo.json $tmp/plugins/slack/
cp ../../fixtures/events/test-sessions.jsonl $tmp/state/events.jsonl
echo "linear.enabled = false" > $tmp/config
CLEAN=(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION)
for th in $themes; do
  $CLEAN MAXWELL_CONFIG=$tmp/config MAXWELL_STATE_DIR=$tmp/state MAXWELL_PLUGINS_DIR=$tmp/plugins MAXWELL_SLACK_FIXTURES=$tmp/plugins/slack/demo.json \
    MAXWELL_SLACK_LAYOUT=$layout ../../build/Maxwell.app/Contents/MacOS/Maxwell --theme $th --size 1280x800 --hide sessions,usage,system \
    --snap $out/slack-$layout-$th.png --snap-after 4.5 --quit-after 5.5 >/dev/null 2>&1
  echo $out/slack-$layout-$th.png
done
rm -rf $tmp
