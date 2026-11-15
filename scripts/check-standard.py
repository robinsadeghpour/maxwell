#!/usr/bin/env python3
"""The engineering standard's ratchet (docs/engineering-standard.md).

Counts what the standard limits and compares it with the recorded baseline
(scripts/standard-baseline.json). Code that already breaks a limit may stay as
it is; a new violation, or an existing one getting worse, fails. The numbers
only go down.

    python3 scripts/check-standard.py            check against the baseline
    python3 scripts/check-standard.py --update   rewrite the baseline

A baseline that rises shows in the pull request's diff; say why in its
description.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "scripts", "standard-baseline.json")
SOURCE_DIRS = ["Sources", "plugins"]
NOT_SOURCE = re.compile(r"(^|/)(Tests|build|\.build)/")

FILE_LINES = 500
FUNCTION_LINES = 80
NESTING = 5
GROWTH = 1.1  # how far a file or function already over its limit may still grow

# Each counted pattern: the rule it breaks, the files where it is the job, and (optionally)
# the only folder it is counted in.
COUNTS = {
    "claude-code-internals": (
        r'appendingPathComponent\("(sessions|jobs|projects)\b|"jobs/|state\.json|"agents"|backgrounded|bg-spare|bg-pty-host|daemon run',
        "Claude Code's files, commands and output are read only in Sources/ClaudeCode/ (rule 7)",
        ("Sources/ClaudeCode/",),
    ),
    "process-spawn": (
        r"\bProcess\(\)",
        "start processes through ClaudeCLI.run (rule 8)",
        ("Sources/ClaudeCode/Run.swift", "plugins/"),
    ),
    "timers": (
        r"\basyncAfter\b",
        "wait for the event, not for a number of seconds (rule 12)",
        ("Sources/UI/Motion.swift", "Sources/Harness/"),
    ),
    "test-flags": (
        r'CommandLine\.arguments|\barg\("--',
        "test flags live in Sources/Harness/, not in the app (rule 13)",
        ("Sources/Harness/", "Sources/App/CLI.swift", "plugins/"),
    ),
    "crash-on-surprise": (
        r"\btry!|\bas!",
        "no try! or as!: handle the case (rule 11)",
        (),
    ),
    "hand-made-controls": (
        r"\bNS(Button|PopUpButton|TextField|SegmentedControl|Switch|Slider)\(",
        "controls come from Sources/UI/Components.swift (rule 9)",
        ("Sources/UI/Components.swift",),
    ),
    "remembered-state": (
        r"UserDefaults\.standard",
        "what Maxwell remembers between launches goes through Sources/UI/Remembered.swift; settings the user picks go in Config (rule 10)",
        ("Sources/UI/Remembered.swift",),
    ),
    "effects-in-ui": (
        r"FileManager\.default|\bClaudeCLI\.|URLSession|\bProcess\(",
        "views don't read files, run commands or call the network; ask the Store or an App service (rule 2)",
        (),
        "Sources/UI/",
    ),
    "ui-in-model": (
        r"^import (AppKit|Cocoa|SwiftUI)",
        "Sources/Model/ never imports AppKit (rule 2)",
        (),
        "Sources/Model/",
    ),
}

FUNC_START = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|open|static|class|final|override|mutating|nonisolated|convenience|required|@objc|@discardableResult)\s+)*(func\s+([A-Za-z_]\w*|[^\s(]+)|init[?!]?|deinit)\b")


def source_files():
    for top in SOURCE_DIRS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, top)):
            dirnames.sort()
            for name in sorted(filenames):
                path = os.path.relpath(os.path.join(dirpath, name), ROOT)
                if name.endswith(".swift") and not NOT_SOURCE.search(path):
                    yield path


def code_only(lines, keep_strings=False):
    """Lines without comments. String contents are blanked too, so braces in them don't count,
    unless keep_strings (patterns like file paths and flag names live in strings)."""
    out, in_block, in_multiline = [], False, False
    for line in lines:
        s, i, buf = line, 0, []
        while i < len(s):
            if in_block:
                end = s.find("*/", i)
                if end < 0:
                    i = len(s)
                    continue
                in_block, i = False, end + 2
            elif in_multiline:
                end = s.find('"""', i)
                if end < 0:
                    i = len(s)
                    continue
                in_multiline, i = False, end + 3
                buf.append('""')
            elif s.startswith("//", i):
                break
            elif s.startswith("/*", i):
                in_block, i = True, i + 2
            elif s.startswith('"""', i):
                in_multiline, i = True, i + 3
            elif s[i] == '"':
                j = i + 1
                while j < len(s) and s[j] != '"':
                    j += 2 if s[j] == "\\" else 1
                buf.append(s[i:j + 1] if keep_strings else '"' + "_" * max(0, j - i - 1) + '"')
                i = j + 1
            else:
                buf.append(s[i])
                i += 1
        out.append("".join(buf))
    return out


def measure_functions(path, code):
    """{name: (lines, deepest nesting)} for each function, init and deinit, the worst one per name."""
    found = {}
    i = 0
    while i < len(code):
        m = FUNC_START.match(code[i])
        if not m:
            i += 1
            continue
        name = m.group(2) or m.group(1).split("(")[0]
        # find the opening brace (signatures can span lines); protocol requirements have none
        j, depth, opened, deepest = i, 0, False, 0
        while j < len(code):
            for ch in code[j]:
                if ch == "{":
                    depth += 1
                    opened = True
                    deepest = max(deepest, depth)
                elif ch == "}":
                    depth -= 1
            if opened and depth <= 0:
                break
            if not opened and (j > i + 12 or (j > i and FUNC_START.match(code[j]))):
                j = -1
                break
            j += 1
        if j < 0 or not opened:
            i += 1
            continue
        lines = j - i + 1
        nesting = max(0, deepest - 1)
        key = f"{path}::{name}"
        old = found.get(key, (0, 0))
        found[key] = (max(old[0], lines), max(old[1], nesting))
        i += 1  # nested functions are measured too
    return found


def measure():
    result = {"file-lines": {}, "function-lines": {}, "nesting": {}}
    for name in COUNTS:
        result[name] = {}
    for path in source_files():
        with open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as f:
            raw = f.read().split("\n")
        code = code_only(raw)
        if len(raw) > FILE_LINES:
            result["file-lines"][path] = len(raw)
        for key, (lines, nesting) in measure_functions(path, code).items():
            if lines > FUNCTION_LINES:
                result["function-lines"][key] = lines
            if nesting > NESTING:
                result["nesting"][key] = nesting
        text = "\n".join(code_only(raw, keep_strings=True))
        for name, (pattern, _, allowed, *scope) in COUNTS.items():
            if any(path.startswith(a) for a in allowed) or (scope and not path.startswith(scope[0])):
                continue
            n = len(re.findall(pattern, text, re.M))
            if n:
                result[name][path] = n
    return result


def check(now, base):
    problems = []
    limits = {"file-lines": FILE_LINES, "function-lines": FUNCTION_LINES, "nesting": NESTING}
    for metric, limit in limits.items():
        for key, value in sorted(now[metric].items()):
            was = base.get(metric, {}).get(key)
            if was is None:
                problems.append(f"{metric}: {key} is {value} (limit {limit}). Split it.")
            elif value > max(was * GROWTH, was + 1):
                problems.append(f"{metric}: {key} grew from {was} to {value}. It is already over {limit}: split it instead of adding to it.")
    for metric, (_, rule, *_) in COUNTS.items():
        for key, value in sorted(now[metric].items()):
            was = base.get(metric, {}).get(key, 0)
            if value > was:
                problems.append(f"{metric}: {key} has {value} (was {was}). {rule}.")
    return problems


def main():
    now = measure()
    if "--update" in sys.argv:
        with open(BASELINE, "w") as f:
            json.dump(now, f, indent=1, sort_keys=True)
            f.write("\n")
        total = sum(len(v) for v in now.values())
        print(f"standard: baseline rewritten, {total} known exceptions")
        return 0
    try:
        with open(BASELINE) as f:
            base = json.load(f)
    except FileNotFoundError:
        base = {}
    problems = check(now, base)
    improved = sum(1 for m in base for k, v in base[m].items() if now.get(m, {}).get(k, 0) < v)
    if problems:
        print("standard: failed (docs/engineering-standard.md)")
        for p in problems:
            print("  - " + p)
        print("If a rise is deliberate, run python3 scripts/check-standard.py --update and say why in the PR.")
        return 1
    note = f"; {improved} exceptions shrank, run --update to lock them in" if improved else ""
    print(f"standard: ok{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
