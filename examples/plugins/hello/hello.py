#!/usr/bin/env python3
"""A complete Maxwell plugin (docs/plugins.md). JSON lines in on stdin, out on stdout."""
import json, sys

sessions, settings = {}, {}

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})

def annotate(s):
    branch = s.get("branch")
    notify("session/annotate", {
        "session": s["id"],
        "badges": [{"text": branch, "tone": "neutral", "action": "greet"}] if branch else [],
        "fields": [{"label": "Branch", "value": branch}] if branch else [],
    })

def panel():
    rows = [{"id": s["id"], "title": s["title"], "subtitle": s.get("branch") or "no branch", "session": s["id"],
             "actions": [{"action": "greet", "title": "Greet"}]} for s in sessions.values()]
    view = {"type": "list", "sections": [{"title": "Sessions", "rows": rows}]} if rows else \
           {"type": "empty", "title": "No sessions yet", "body": "Start one with ⌘T."}
    notify("panel/set", {"panel": "branches", "view": view})

for line in sys.stdin:
    msg = json.loads(line)
    method, params, mid = msg.get("method"), msg.get("params", {}), msg.get("id")
    if method == "initialize":
        settings = params.get("settings", {})
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
        notify("status", {"state": "ok"})
    elif method == "sessions/changed":
        if params.get("full"):
            sessions.clear()
        for s in params.get("sessions", []):
            sessions[s["id"]] = s
            annotate(s)
        for gone in params.get("removed", []):
            sessions.pop(gone, None)
        panel()
    elif method == "settings/changed":
        settings = params.get("settings", {})
    elif method == "action/run":
        s = sessions.get(params.get("session") or params.get("item") or "", {})
        text = f"{settings.get('greeting', 'Hello')}, {s.get('title', 'nobody')}"
        send({"jsonrpc": "2.0", "id": mid, "result": {"message": text}})
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": mid, "result": None})
        break
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown method {method}"}})
