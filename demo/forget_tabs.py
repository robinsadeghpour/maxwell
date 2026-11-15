#!/usr/bin/env python3
"""Maxwell Dev remembers each session's viewer tabs, and the demo sessions keep their ids, so a file
opened in one take would already be open in the next. This forgets the demo sessions' tabs only.
    python3 demo/forget_tabs.py ~/demo"""
import json, plistlib, subprocess, sys

ids = {s["id"] for s in json.load(open(f"{sys.argv[1]}/.sessions.json")).values()}
r = subprocess.run(["defaults", "export", "dev.maxwell.app.dev", "-"], capture_output=True)
if r.returncode == 0:
    raw = plistlib.loads(r.stdout).get("Maxwell.viewerTabs")
    if raw:
        saved = json.loads(raw)
        saved["entries"] = {k: v for k, v in saved.get("entries", {}).items() if k not in ids}
        subprocess.run(["defaults", "write", "dev.maxwell.app.dev", "Maxwell.viewerTabs", "-data",
                        json.dumps(saved).encode().hex()], check=True)
