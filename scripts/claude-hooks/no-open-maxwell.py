#!/usr/bin/env python3
"""Claude Code PreToolUse hook: refuses `open ... Maxwell` from a Claude session.

`open` launches through LaunchServices, which drops CLAUDECODE, so Maxwell can't tell a
session started it: the window comes to the front and takes focus over Robin's work.
Run the binary directly instead; it is then quiet (see docs/harness.md).
"""
import json, re, sys

command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
if re.search(r"(^|[\s;&|(])open\s[^;&|]*Maxwell", command):
    sys.stderr.write(
        "Don't `open` Maxwell from a session: it comes to the front over the user's work. "
        "Run build/Maxwell.app/Contents/MacOS/Maxwell with --quit-after N (plus --snap, --keys, "
        "--click as needed). That run is quiet: its window stays off every screen. See docs/harness.md.\n"
    )
    sys.exit(2)
