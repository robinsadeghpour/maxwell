# Clean-up plan

Written 2026-11-15, after a day with 22 releases, a stream of regressions, and a user whose sessions lost the iOS Simulator after a crash. The goal is a Maxwell that stays reliable while many sessions change it at once. The standard it is measured against is [engineering-standard.md](engineering-standard.md). The check `scripts/check-standard.py` already stops each problem below from growing; this plan shrinks them.

Pick up the first step that isn't done. Mark it done here in the same PR that finishes it, with the check or test that proves it. Run `python3 scripts/check-standard.py --update` whenever an exception shrinks.

## What the review found

**Good, keep it:** session state comes from one pure reducer over a log of events, with typed statuses, tested against recorded real hook payloads (`fixtures/events`). Claude Code's internals are read in only two files. The UI uses its own component set; there are almost no hand-made AppKit controls.

**Why it breaks:**

| Finding | Evidence (2026-11-15) |
|---|---|
| Users get code nobody tested together | 22 releases in one day, straight to every user. No beta. |
| Two copies of the code | private `v1` and public `v1` differ in 21 source files; public has a file private doesn't (`Titler.swift`). Every change is ported by hand as a patch. |
| The real app isn't tested | ~1,100 lines of tests for ~16,000 lines of code. They cover the reducer, plugins and logos. Nothing tests starting, attaching, resuming, updating or crash recovery, which is where the day's bugs were. |
| The test harness is timing in the app | `runTestHooks` in `main.swift` is 378 lines, reads 81 flags, and has 37 `asyncAfter` waits. It grew by 73 lines, 7 flags and 6 waits in the half hour this plan was being written. Harness runs pass or fail with the Mac's speed. |
| Claude Code changes under Maxwell | Maxwell parses Claude Code's undocumented files and printed output; Claude Code ships almost daily. Nothing checks the assumptions still hold, and an unknown value is mapped to a guess. |
| Failures outside Maxwell look like Maxwell bugs | A stale background service after a crash broke every session for a user. Maxwell couldn't see it, and Claude misdiagnosed it. |
| Big files get bigger | 9 files over 500 lines (`MainWindow` 1,520, `SettingsWindow` 1,164, `Layout` 883, `Sidebar` 760, `main` 626, `Terminal` 622, `Store` 536, `Probes` 524, `ArtifactView` 518). 7 functions over 80 lines (`Reducer.reduce` 169). Sessions add to the file where similar code already lives. |
| Knowledge was split across accounts | The release recipe, harness traps and Claude Code state files were in per-account memories, each account holding a different subset. Now in `CLAUDE.md` and `docs/` (step 0). |
| Layers leak | 13 file/process/network calls in `Sources/UI`, 15 `UserDefaults` uses across 5 files, 5 process spawns in 4 files outside the one runner, 13 `try!`/`as!`. |

## Steps

### 0. A standard, a check, and one place for knowledge — done 2026-11-15

`docs/engineering-standard.md`, `scripts/check-standard.py` (runs in `./build.sh test`, so in every release), `CLAUDE.md`, and `docs/releasing.md`, `harness.md`, `claude-code-internals.md`, moved out of per-account memories.

### 1. One copy of the code — done 2026-11-15

This public repository is the only home of the code, its docs, CI and decision log. `maxwell-private` keeps only what shouldn't be public: user research with real people, the old decision log and design rounds (full of real project names), launch material until launch, screenshots of real sessions, and real-data fixtures. Its code was removed, and its CI fails any change that adds code back.

Reconciling showed public was already a superset: every private-only line was an older version of code public had since rewritten, or a real name public had replaced with an invented one. The last unported change (three demo tweaks from the launch film) came across with this step.

### 2. Beta and Stable

Issue [#11](https://github.com/robinsadeghpour/maxwell/issues/11).

Releases go to a Beta channel first (Robin and anyone who opts in, in Settings › General). Stable gets a build once it has run 24 hours on Beta without a new crash group in Sentry. The updater reads the channel; the release workflow publishes Beta, and a second workflow promotes a Beta to Stable.

- **Done when** a release doesn't reach Stable users the day it is built, and promotion is one command that checks Sentry first.

### 3. A smoke test of the real app, and the harness out of the app

Issue [#12](https://github.com/robinsadeghpour/maxwell/issues/12).

Move the flags from `main.swift` into `Sources/Harness/`, driven by a small script of steps that each wait for a state, not for seconds ("start session", "until Your turn", "kill Maxwell", "relaunch", "until attached"). Run it against the `demo/` world with its stand-in `claude`, so it needs no account and runs in CI on every release.

- Cases at minimum: start a session, attach, Working → Your turn, Maxwell killed and relaunched (sessions reattach), Bring into Maxwell, resume, close safe, update installs.
- Each bug fixed from now on adds a case (rule 16).
- **Done when** the release workflow fails on a broken smoke case, and `main.swift` has no test flags (`test-flags` and `timers` for it are 0 in the baseline).

### 4. Claude Code behind one adapter, checked against the installed version

Issue [#13](https://github.com/robinsadeghpour/maxwell/issues/13).

Move everything that reads Claude Code into `Sources/ClaudeCode/`: commands and their output (`Run.swift`, `Background.swift`), state files (`SessionFiles.swift`, `JobState.swift`), transcripts (`Transcript.swift`), trust (`Trust.swift`). Parse the `backgrounded` line once (it is parsed twice today). Unknown values become an explicit `unknown` case, shown as unknown.

- Add a contract check: when the installed `claude --version` changes, Maxwell runs a short self-test (start a haiku background session in a temp folder, read its state files, stop it) and shows "Claude Code changed: some states may be wrong" if an assumption fails. The same test runs in the smoke suite.
- Fix the `.claude.json` race: Maxwell writes Claude Code's own file while Claude may be writing it. Write only after the user chooses Trust, read-modify-write in one step, and verify. Look for a Claude Code command that trusts a folder first.
- **Done when** `claude-code-internals` in the baseline is 0 outside `Sources/ClaudeCode/`, and a changed format shows a notice instead of wrong states.

### 5. Health checks that fix what they find

Issue [#14](https://github.com/robinsadeghpour/maxwell/issues/14).

One "Health" section in Settings › General, with a banner in the main window when something is wrong. Each check has a one-click fix:

- background service cut off from macOS after a crash (the hook reports when `getpwuid` fails inside a session; fix: stop the service and resume its sessions under the same ids, reusing Bring into Maxwell's resume);
- `claude` not found or too old; hooks missing or outdated; a folder not trusted on an account; notification permission; Keychain access for plugins.
- Every new "weird thing" a user reports becomes a check here.
- **Done when** that user's case shows a banner and is fixed by one click, in a smoke case that fakes the failing hook report.

### 6. Split the big files

Issue [#15](https://github.com/robinsadeghpour/maxwell/issues/15).

In this order, because sessions touch them most: `MainWindow` (actions, wiring and rendering into their own files; `makeActions` 128 lines, `wire` 98, `render` 83), `SettingsWindow` (one file per section), `Reducer.reduce` (one function per event kind; the fixtures keep it safe), `Layout`, `Sidebar`, `Terminal`, `Store`, `ArtifactView`, `Probes` (most of it moves in step 4).

- Pure moves first, in their own PRs, with no behaviour change, verified by `./build.sh test` and the smoke test.
- **Done when** `file-lines` and `function-lines` in the baseline are empty.

### 7. Layers and small hazards

Issue [#16](https://github.com/robinsadeghpour/maxwell/issues/16).

- `Sources/UI/Remembered.swift` with typed keys for the 15 `UserDefaults` uses.
- The 13 file and process calls in `Sources/UI` move to the Store or an App service (`ProjectLogo` has 5).
- The 5 process spawns outside it go through `ClaudeCLI.run` (or a general runner it becomes).
- The 13 `try!`/`as!` handle their case.
- The 18 `asyncAfter` outside `main.swift` become waits for events, or one debounce helper.
- **Done when** these baseline sections are empty.

## Order and size

Step 2 protects users now; do it first. Step 3 makes every later step safe to do. Steps 4 and 5 handle the failures that come from Claude Code and macOS rather than from Maxwell. Steps 6 and 7 can run alongside feature work: any session touching one of these files leaves it smaller.

Rough size, one session each: step 1 half a day (most of it reconciling files carefully), 2 half a day, 3 a day, 4 a day, 5 half a day, 6 and 7 a few hours per file.
