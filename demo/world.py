#!/usr/bin/env python3
"""Builds an invented world for Maxwell to run on: three made-up projects, three accounts and a
dozen sessions in every state. Nothing here is real. Maxwell reads it through its own overrides
(MAXWELL_CONFIG, MAXWELL_STATE_DIR, MAXWELL_CLAUDE, MAXWELL_GH), so real sessions never show.

    python3 demo/world.py [root] [--live]   default root: ~/demo (it is deleted and rebuilt)
    python3 demo/world.py ask <session key> [root]

--live starts the permission session working; `ask` then turns it into a permission prompt
while Maxwell runs, the way a real hook and listing would.

Then `demo/record.sh` runs the app on it, or run it by hand:
    env $(cat ~/demo/.env) build/Maxwell.app/Contents/MacOS/Maxwell
"""
import hashlib, json, os, shutil, subprocess, sys, time, uuid
from datetime import datetime, timezone

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
ASK = ARGS[1] if ARGS[:1] == ["ask"] else None
if ASK: ARGS = ARGS[2:]
LIVE = "--live" in sys.argv
ROOT = os.path.abspath(os.path.expanduser(ARGS[0] if ARGS else "~/demo"))
HERE = os.path.dirname(os.path.abspath(__file__))
NOW = time.time()
H = 3600

ACCOUNTS = {  # name: (5-hour %, 5-hour resets in, weekly %, weekly resets in)
    "work":     (62, 2.1 * H, 41, 3.2 * 24 * H),
    "personal": (18, 4.4 * H, 22, 5.1 * 24 * H),
    "team":     (100, 0.7 * H, 77, 1.4 * 24 * H),
}

PROJECTS = {  # folder: (logo svg, files)
    "lumen": ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><circle cx="16" cy="16" r="13" fill="#f5b83d"/><circle cx="21" cy="11" r="9" fill="#fff"/></svg>',
              {"package.json": '{ "name": "lumen", "private": true }\n', "src/auth/passkeys.ts": "export const passkeys = true\n",
               "docs/passkeys.md": "# Passkeys\n\nSign in with a passkey instead of a password.\n"}),
    "orbit": ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><circle cx="16" cy="16" r="6" fill="#7c6cf2"/><ellipse cx="16" cy="16" rx="14" ry="6" fill="none" stroke="#7c6cf2" stroke-width="3"/></svg>',
              {"go.mod": "module example.com/orbit\n", "api/limits.go": "package api\n"}),
    "fieldnotes": ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path d="M6 4h16l4 4v20H6z" fill="#3fb37f"/><path d="M10 12h12M10 17h12M10 22h8" stroke="#fff" stroke-width="2"/></svg>',
                   {"Package.swift": "// swift-tools-version:5.9\n", "Sources/Sync/Merge.swift": "struct Merge {}\n"}),
}

# Each session: account, project, branch (None: main), title, state, minutes since its last reply, last reply.
SESSIONS = [
    # Needs you
    dict(key="passkeys", acct="work", proj="lumen", branch="passkeys", title="Migrate sign-in to passkeys", state="permission",
         ago=1, wait="Bash: npm run db:migrate", prompt="Move sign-in to passkeys, keep passwords as a fallback for a month",
         reply="I've added the WebAuthn routes and the credentials table. Running the migration next."),
    dict(key="ratelimit", acct="work", proj="orbit", branch="v2-limits", title="Rate limits for the v2 API", state="question", ago=4,
         prompt="Add rate limits to the v2 API",
         reply="The token bucket is in place and tested at 1,000 requests a minute.\n\nShould the limit apply per API key or per IP address?\n\n**Needs you** · per key or per IP?"),
    # Your turn
    dict(key="offline", acct="personal", proj="fieldnotes", branch="offline-sync", title="Offline sync conflicts", state="stopped", ago=12,
         prompt="Fix the duplicate notes after offline edits",
         reply="Edits made offline now merge by field instead of overwriting the whole note. I can add a test for two devices editing the same note next.\n\n**Not done** · two-device test left"),
    dict(key="flaky", acct="work", proj="lumen", branch="flaky-checkout", title="Fix the flaky checkout test", state="stopped", ago=25,
         prompt="The checkout e2e test fails one run in five, find out why",
         reply="The test waited for a fixed 500 ms instead of the payment iframe. It now waits for the iframe's ready event; 50 runs passed.\n\n**Not done** · fix is local, not committed yet"),
    # Working
    dict(key="darkmode", acct="personal", proj="lumen", branch="settings-dark", title="Dark mode for settings", state="busy", ago=0,
         prompt="Settings should follow the system appearance", reply=None),
    dict(key="postgres", acct="work", proj="orbit", branch="pg17", title="Upgrade to Postgres 17", state="busy", ago=0,
         prompt="Upgrade the database to Postgres 17", reply=None),
    dict(key="widget", acct="personal", proj="fieldnotes", branch="today-widget", title="Widget for today's notes", state="busy", ago=0,
         prompt="Add a home screen widget that shows today's notes", reply=None),
    # Limited
    dict(key="importer", acct="team", proj="orbit", branch="importer-load", title="Load test the CSV importer", state="limited", ago=18,
         prompt="Load test the CSV importer with a 2 GB file", reply="You've hit your session limit · resets 7:40pm"),
    # Safe to close: quiet for hours, clean, pushed, PR merged, read as finished
    dict(key="deps", acct="work", proj="lumen", branch="bump-deps", title="Bump dependencies", state="done", ago=190, pr=212,
         prompt="Update dependencies and fix whatever breaks",
         reply="All 41 packages are on their latest minor versions. Two type errors from the router update are fixed. PR #212 is merged.\n\n**Safe to close** · PR #212 merged"),
    dict(key="crash", acct="personal", proj="fieldnotes", branch="empty-notebook", title="Crash on an empty notebook", state="done", ago=300, pr=88,
         prompt="The app crashes when you open a notebook with no notes",
         reply="Fixed: the list read the first note before checking the count. Added a regression test. PR #88 is merged and in today's TestFlight build.\n\n**Safe to close** · in TestFlight"),
    dict(key="webhooks", acct="work", proj="orbit", branch="webhook-docs", title="Docs for webhooks", state="done", ago=240, pr=157,
         prompt="Write the docs page for webhooks",
         reply="The webhooks page is live with examples for every event and the signature check in Go and Node. PR #157 is merged.\n\n**Safe to close** · docs live"),
]

ACCT_DIR = lambda a: f"{ROOT}/.accounts/{a}"
sid = lambda k: str(uuid.uuid5(uuid.NAMESPACE_URL, "maxwell-demo/" + k))
short = lambda k: sid(k)[:8]
iso = lambda t: datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   env={**os.environ, "GIT_AUTHOR_NAME": "Demo", "GIT_AUTHOR_EMAIL": "demo@example.com",
                        "GIT_COMMITTER_NAME": "Demo", "GIT_COMMITTER_EMAIL": "demo@example.com"})


def cwd_of(s):
    return f"{ROOT}/{s['proj']}" if not s.get("branch") else f"{ROOT}/{s['proj']}/.worktrees/{s['branch']}"


def build_repos():
    for proj, (logo, files) in PROJECTS.items():
        repo, remote = f"{ROOT}/{proj}", f"{ROOT}/.remotes/{proj}.git"
        os.makedirs(f"{repo}/.github", exist_ok=True)
        open(f"{repo}/.github/logo.svg", "w").write(logo)
        open(f"{repo}/.gitignore", "w").write(".worktrees/\n")
        for path, text in files.items():
            os.makedirs(os.path.dirname(f"{repo}/{path}") or repo, exist_ok=True)
            open(f"{repo}/{path}", "w").write(text)
        run("git", "init", "-q", "-b", "main", repo)
        run("git", "add", "-A", cwd=repo)
        run("git", "commit", "-q", "-m", "Start", cwd=repo)
        run("git", "init", "-q", "--bare", remote)
        run("git", "remote", "add", "origin", remote, cwd=repo)
        run("git", "push", "-q", "-u", "origin", "main", cwd=repo)
    for s in SESSIONS:
        if s.get("branch"):
            repo = f"{ROOT}/{s['proj']}"
            run("git", "worktree", "add", "-q", "-b", s["branch"], cwd_of(s), cwd=repo)
            run("git", "push", "-q", "origin", s["branch"], cwd=cwd_of(s))


def transcript(s):
    a, cwd = ACCT_DIR(s["acct"]), cwd_of(s)
    slug = "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd)
    os.makedirs(f"{a}/projects/{slug}", exist_ok=True)
    t_reply = NOW - s["ago"] * 60
    lines = [{"type": "user", "timestamp": iso(t_reply - 600), "cwd": cwd, "sessionId": sid(s["key"]),
              "message": {"role": "user", "content": s["prompt"]}}]
    if s["reply"]:
        lines.append({"type": "assistant", "timestamp": iso(t_reply), "sessionId": sid(s["key"]),
                      "message": {"role": "assistant", "content": [{"type": "text", "text": s["reply"]}]}})
    with open(f"{a}/projects/{slug}/{sid(s['key'])}.jsonl", "w") as f:
        f.writelines(json.dumps(l) + "\n" for l in lines)


def hook(s, at, name, **extra):
    h = {"session_id": sid(s["key"]), "hook_event_name": name, "cwd": cwd_of(s)}
    h.update(extra)
    return {"ts": int(at * 1000), "configDir": ACCT_DIR(s["acct"]), "hook": h}


def events():
    out = []
    for a, (p5, r5, pw, rw) in ACCOUNTS.items():
        out.append({"ts": int((NOW - 60) * 1000), "configDir": ACCT_DIR(a), "usage": {"rate_limits": {
            "five_hour": {"used_percentage": p5, "resets_at": int(NOW + r5)},
            "seven_day": {"used_percentage": pw, "resets_at": int(NOW + rw)}}}})
    for s in SESSIONS:
        t = NOW - s["ago"] * 60
        out.append(hook(s, t - 900, "SessionStart", source="startup"))
        out.append(hook(s, t - 600, "UserPromptSubmit", prompt=s["prompt"], session_title=s["title"]))
        if s["state"] in ("question", "stopped", "done"):
            out.append(hook(s, t, "Stop", last_assistant_message=s["reply"]))
        elif s["state"] == "permission" and not LIVE:
            out.append(hook(s, t, "Notification", notification_type="permission_prompt", message="Claude needs your permission to use Bash"))
        elif s["state"] == "limited":
            out.append(hook(s, t, "StopFailure", error="rate_limit"))
        if s["state"] == "done":
            digest = hashlib.sha256(s["reply"].encode()).digest()[:8].hex()
            out.append({"ts": int((t + 7200 + 60) * 1000), "maxwell": {"type": "judged", "hash": digest, "session": sid(s["key"]),
                        "verdict": "finished", "account": "personal", "ms": 840, "model": "haiku", "costUsd": 0.0002}})
    out.sort(key=lambda e: e["ts"])
    return out


def agents():
    by = {a: [] for a in ACCOUNTS}
    for s in SESSIONS:
        status = {"busy": "busy", "permission": "busy" if LIVE else "waiting"}.get(s["state"], "idle")
        e = {"sessionId": sid(s["key"]), "id": short(s["key"]), "kind": "background", "cwd": cwd_of(s), "name": s["title"],
             "status": status, "startedAt": int((NOW - s["ago"] * 60 - 900) * 1000)}
        if status == "waiting":
            e["waitingFor"] = s["wait"]
        by[s["acct"]].append(e)
    return by


def main():
    if os.path.exists(ROOT):
        if not os.path.exists(f"{ROOT}/.maxwell-demo"):
            sys.exit(f"{ROOT} exists and is not a Maxwell demo world; pick another root")
        shutil.rmtree(ROOT)
    os.makedirs(f"{ROOT}/.state")
    open(f"{ROOT}/.maxwell-demo", "w").write("Invented data for Maxwell's demo. Safe to delete.\n")
    for a in ACCOUNTS:
        for d in ("sessions", "jobs", "projects"):
            os.makedirs(f"{ACCT_DIR(a)}/{d}", exist_ok=True)
    build_repos()
    for s in SESSIONS:
        transcript(s)
    with open(f"{ROOT}/.state/events.jsonl", "w") as f:
        f.writelines(json.dumps(e) + "\n" for e in events())
    for a, entries in agents().items():
        json.dump(entries, open(f"{ACCT_DIR(a)}/agents.json", "w"), indent=1)
    json.dump({s["key"]: dict(s, id=sid(s["key"]), short=short(s["key"]), cwd=cwd_of(s)) for s in SESSIONS},
              open(f"{ROOT}/.sessions.json", "w"), indent=1)
    shutil.copytree(f"{HERE}/bin", f"{ROOT}/.bin")
    pins = "\n".join(f"project-pin = {p.capitalize()}" for p in PROJECTS)
    accts = "\n".join(f"account = {a} {ACCT_DIR(a)}" for a in ACCOUNTS)
    open(f"{ROOT}/.config", "w").write(f"""# Maxwell demo world (invented)
{accts}

{pins}
rail = shown
font-size = 13
terminal-font-size = 11
project-logo-style = engraved
theme-dark = graphite
appearance = dark
background-opacity = 1
notify = false
auto-open = false
file-tree = false
idle-after = 24h
""")
    open(f"{ROOT}/.env", "w").write(" ".join([
        f"MAXWELL_CONFIG={ROOT}/.config", f"MAXWELL_STATE_DIR={ROOT}/.state",
        f"MAXWELL_CLAUDE={ROOT}/.bin/claude", f"MAXWELL_GH={ROOT}/.bin/gh", f"MAXWELL_DEMO_ROOT={ROOT}"]) + "\n")
    print(ROOT)


def ask(key):
    s = SESSIONS_BY_KEY[key]
    at = time.time()
    with open(f"{ROOT}/.state/events.jsonl", "a") as f:
        f.write(json.dumps(hook(s, at, "Notification", notification_type="permission_prompt",
                                message="Claude needs your permission to use Bash")) + "\n")
    path = f"{ACCT_DIR(s['acct'])}/agents.json"
    entries = json.load(open(path))
    for e in entries:
        if e["sessionId"] == sid(key):
            e["status"], e["waitingFor"] = "waiting", s["wait"]
    json.dump(entries, open(path, "w"), indent=1)
    open(f"{ACCT_DIR(s['acct'])}/sessions/.touch", "w").write(str(at))


SESSIONS_BY_KEY = {s["key"]: s for s in SESSIONS}

if __name__ == "__main__":
    ask(ASK) if ASK else main()
