#!/usr/bin/env python3
"""A scripted terminal screen for one invented demo session, shaped like a Claude Code session.
It follows the session's status in its account's agents.json (busy, waiting, idle), and answers
the permission prompt with 1 or 2: the session goes back to work and Maxwell sees it busy."""
import json, os, select, shutil, sys, termios, time, tty

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SESSIONS = json.load(open(os.path.join(ROOT, ".sessions.json")))
s = next(v for v in SESSIONS.values() if v["short"] == sys.argv[1])
AGENTS = os.path.join(ROOT, ".accounts", s["acct"], "agents.json")

ORANGE, DIM, BOLD, GREEN, RED, BLUE, RESET = "\x1b[38;5;173m", "\x1b[2m", "\x1b[1m", "\x1b[32m", "\x1b[31m", "\x1b[38;5;111m", "\x1b[0m"
SPIN = "·✢✳✶✻✽✻✶✳✢"

TOOLS = {
    "passkeys": [("Read", "src/auth/session.ts", "Read 182 lines"), ("Write", "src/auth/passkeys.ts", "Wrote 96 lines"),
                 ("Write", "db/migrations/0042_credentials.sql", "Wrote 18 lines")],
    "ratelimit": [("Read", "api/limits.go", "Read 64 lines"), ("Bash", "go test ./api/...", "ok  example.com/orbit/api  2.41s")],
    "offline": [("Read", "Sources/Sync/Merge.swift", "Read 210 lines"), ("Update", "Sources/Sync/Merge.swift", "Updated with 34 additions")],
    "flaky": [("Bash", "npx playwright test checkout --repeat-each 50", "50 passed (3.2m)")],
    "darkmode": [("Read", "src/settings/theme.css", "Read 88 lines"), ("Update", "src/settings/theme.css", "Updated with 41 additions")],
    "postgres": [("Bash", "docker compose up -d db", "Container orbit-db-1  Started"), ("Bash", "go test ./store/...", "running…")],
    "widget": [("Write", "Widgets/TodayWidget.swift", "Wrote 120 lines")],
    "importer": [("Bash", "go run ./cmd/loadtest --file big.csv", "1.2 GB of 2 GB imported")],
    "deps": [("Bash", "npm outdated", "41 packages"), ("Bash", "npm test", "312 passed")],
    "crash": [("Update", "Sources/Notebook/List.swift", "Updated with 6 additions")],
    "webhooks": [("Write", "docs/webhooks.md", "Wrote 240 lines")],
}
AFTER = {"passkeys": [("Bash", "npm run db:migrate", "Applied 0042_credentials (12 ms)"), ("Bash", "npm test -- auth", "48 passed")]}
VERBS = {"passkeys": "Migrating", "darkmode": "Theming", "postgres": "Upgrading", "widget": "Building", "importer": "Importing"}


def status():
    try:
        return next((e.get("status", "idle") for e in json.load(open(AGENTS)) if e["id"] == s["short"]), "idle")
    except (OSError, ValueError):
        return "idle"


def set_busy():
    entries = json.load(open(AGENTS))
    for e in entries:
        if e["id"] == s["short"]:
            e["status"] = "busy"
            e.pop("waitingFor", None)
    json.dump(entries, open(AGENTS, "w"), indent=1)
    open(os.path.join(ROOT, ".accounts", s["acct"], "sessions", ".touch"), "w").write(str(time.time()))


def wrap(text, width):
    out = []
    for para in text.split("\n"):
        line = ""
        for w in para.split(" "):
            if line and len(line) + 1 + len(w) > width:
                out.append(line); line = w
            else:
                line = f"{line} {w}" if line else w
        out.append(line)
    return out


def box(lines, width, color=DIM):
    out = [f"{color}╭{'─' * (width - 2)}╮{RESET}"]
    for text, plain in lines:
        out.append(f"{color}│{RESET} {text}{' ' * max(0, width - 4 - len(plain))} {color}│{RESET}")
    out.append(f"{color}╰{'─' * (width - 2)}╯{RESET}")
    return out


GREY_BG, GREY = "\x1b[48;5;236m", "\x1b[38;5;244m"
MODEL = {"work": "Opus", "personal": "Sonnet", "team": "Opus"}


def header(w, where):
    """Claude Code's welcome box: its name and version set into the top border."""
    title = " Claude Code v2.1 "
    top = f"{ORANGE}╭───{title}{'─' * max(0, w - 5 - len(title))}╮{RESET}"
    rows = [("", ""), (f"   {BOLD}Welcome back!{RESET}", "   Welcome back!"), ("", ""),
            (f"   {ORANGE}✻{RESET}  {MODEL.get(s['acct'], 'Opus')} · {s['acct']}", f"   ✻  {MODEL.get(s['acct'], 'Opus')} · {s['acct']}"),
            (f"   {GREY}{where}{RESET}", f"   {where}"), ("", "")]
    out = [top]
    for text, plain in rows:
        out.append(f"{ORANGE}│{RESET}{text}{' ' * max(0, w - 2 - len(plain))}{ORANGE}│{RESET}")
    out.append(f"{ORANGE}╰{'─' * (w - 2)}╯{RESET}")
    return out


def screen(state, tick, approved):
    cols, rows = shutil.get_terminal_size((100, 32))
    w = min(cols - 2, 110)
    home = os.path.expanduser("~")
    where = s["cwd"].replace(home, "~")
    out = header(min(w, 72), where) + [""]
    prompt = f"> {s['prompt']}"
    out += [f"{GREY_BG}{prompt}{' ' * max(0, w - len(prompt))}{RESET}", ""]
    tools = TOOLS.get(s["key"], []) + (AFTER.get(s["key"], [])[:approved] if approved else [])
    for name, arg, result in tools:
        tail = f" {GREY}(ctrl+o to expand){RESET}" if name != "Bash" else ""
        out += [f"{GREEN}⏺{RESET} {BOLD}{name}{RESET}({arg})", f"  {GREY}⎿  {result}{RESET}{tail}", ""]
    if s.get("reply") and s["state"] != "busy" and not (s["state"] == "permission" and approved):
        for i, line in enumerate(wrap(s["reply"].replace("**", "\x00"), w - 2)):
            parts = line.split("\x00")
            line = "".join(p if j % 2 == 0 else f"{BOLD}{p}{RESET}" for j, p in enumerate(parts))
            out.append(f"{'⏺ ' if i == 0 else '  '}{line}")
        out.append("")
    rule = f"{GREY}{'─' * w}{RESET}"
    if state == "waiting":
        cmd = s.get("wait", "").split(": ", 1)[-1]
        words = cmd.split(" ")
        out += [rule, f" {BOLD}Bash command{RESET}", "", f"   {cmd}", f"   {GREY}Apply the credentials table migration{RESET}", "",
                " Do you want to proceed?", f" {BLUE}❯ 1. Yes{RESET}",
                f"   2. Yes, and don't ask again for {' '.join(words[:3])} commands in {where}",
                f"   3. No, and tell Claude what to do differently {GREY}(esc){RESET}"]
    else:
        if state == "busy":
            verb = VERBS.get(s["key"], "Working")
            secs = 12 + tick // 8
            out += [f"{ORANGE}{SPIN[tick % len(SPIN)]} {verb}…{RESET} {GREY}(esc to interrupt · {secs}s · ↓ {1.1 + secs / 40:.1f}k tokens){RESET}", ""]
        out += [rule, f"{GREY}>{RESET} ", rule, f"  {GREY}? for shortcuts{RESET}"]
    out = out[-(rows - 1):]
    return "\x1b[H\x1b[2J" + "\r\n".join(out)


def main():
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    sys.stdout.write("\x1b[?25l")
    tick, approved, last = 0, 0, None
    try:
        while True:
            st = status()
            if s["state"] == "permission" and approved and st != "waiting":
                st = "busy"
            frame = screen(st, tick, approved)
            if frame != last:
                sys.stdout.write(frame); sys.stdout.flush(); last = frame
            r, _, _ = select.select([fd], [], [], 0.12)
            if r:
                ch = os.read(fd, 16)
                if ch in (b"\x03",):
                    break
                if st == "waiting" and ch[:1] in (b"1", b"2", b"\r"):
                    approved = 1
                    set_busy()
            tick += 1
            if approved and approved < len(AFTER.get(s["key"], [])) and tick % 25 == 0:
                approved += 1
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\x1b[?25h")


main()
