#!/bin/zsh
# Performance budgets for build/Maxwell.app. Exits 1 if any budget is exceeded.
#   window on screen < 300 ms · idle < 150 MB · launch peak < 200 MB · 20 visited sessions < 400 MB
#   · artifacts on up to 3 accounts < 400 MB (claude.ai's sign-in page on each account's data store in turn)
# Memory is phys_footprint (what Activity Monitor shows) of Maxwell plus the WebKit
# helpers it started. The `claude attach` children are reported separately: they are
# Claude Code's processes, not Maxwell's.
# The 20-session run visits background sessions named mxtest* (create them first with
#   for i in $(seq -w 1 20); do claude --bg --model haiku --name mxtest-m$i; done   in a trusted folder).
cd "$(dirname "$0")"
BIN=build/Maxwell.app/Contents/MacOS/Maxwell
fail=0
fp() { footprint "$1" 2>/dev/null | awk -v k="${2:-phys_footprint}:" '$1 == k {v=$2; u=$3; if (u=="KB") v/=1024; if (u=="GB") v*=1024; printf "%.1f", v; exit}'; }
webkit() { pgrep -f 'com.apple.WebKit\.(WebContent|Networking|GPU)' | sort; }
# Run from a Claude Code session, the app would inherit its session markers.
CLEAN=(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION)
budget() { # name value limit unit
  if (( $(echo "$2 > $3" | bc) )); then echo "FAIL  $1: $2 $4 (budget $3)"; fail=1; else echo "ok    $1: $2 $4 (budget $3)"; fi
}

$CLEAN $BIN --quit-after 1 >/dev/null 2>&1   # warm-up: the first launch after a build is cold
times=()
for i in 1 2 3 4 5; do
  t=$($CLEAN $BIN --quit-after 1.5 2>&1 | awk '/window ordered front/ {print $(NF-1)}')
  times+=$t
done
echo "window on screen, 5 warm runs (ms): ${times[*]}"
budget "window on screen (worst of 5)" "$(printf '%s\n' $times | sort -n | tail -1)" 300 ms

measure() { # name wait limit args...
  local name=$1 wait=$2 limit=$3; shift 3
  local before=$(webkit)
  $CLEAN $BIN "$@" --quit-after $((wait + 4)) 2>/dev/null &
  local pid=$!
  sleep $wait
  local app=$(fp $pid) wk=0 kids=0 nk=0
  for p in $(comm -13 <(echo "$before") <(webkit)); do wk=$(echo "$wk + $(fp $p)" | bc); done
  for p in $(pgrep -P $pid); do kids=$(echo "$kids + $(ps -o rss= -p $p | awk '{printf "%.1f", $1/1024}')" | bc); nk=$((nk + 1)); done
  local total=$(echo "$app + $wk" | bc)
  budget "$name" "$total" "$limit" "MB (app $app + webkit $wk; $nk claude attach children ${kids} MB rss, not counted)"
  wait $pid 2>/dev/null
}

# The first listings read every live transcript; a spike there is gone by the 8 s sample, so
# sample every 250 ms for 15 s and also read the kernel's own peak.
launch_peak() {
  $CLEAN $BIN --quit-after 20 >/dev/null 2>&1 &
  local pid=$! max=0 v n=0 end=$((SECONDS + 15))
  while (( SECONDS < end )); do
    v=$(fp $pid); [[ -n $v ]] && { n=$((n + 1)); (( $(echo "$v > $max" | bc) )) && max=$v; }
    sleep 0.25
  done
  local kernel=$(fp $pid phys_footprint_peak)
  wait $pid 2>/dev/null
  budget "launch peak, $n samples 250 ms apart over 15 s" "$max" 200 "MB"
  budget "launch peak, kernel phys_footprint_peak" "${kernel:-9999}" 200 MB
}
launch_peak
measure "idle" 8 150
measure "20 visited sessions" 18 400 --visit-all 20
accts=$(grep -E '^account *=' "${MAXWELL_CONFIG:-$HOME/.config/maxwell/config}" 2>/dev/null | awk '{print $3}' | head -3 | paste -sd, -)
[[ -n $accts ]] && measure "artifacts on $accts" 30 400 --artifact-accounts $accts
exit $fail
