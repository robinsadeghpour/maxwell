# What Maxwell assumes about Claude Code

Maxwell reads files and output that Claude Code doesn't document or promise to keep. Claude Code ships almost daily, so each of these can change without notice. This page is the list. When you add an assumption, add it here with the version you saw it in. When one breaks, fix the parser and add the new real file or output to `fixtures/`.

Seen in Claude Code 2.1.3xx (2.1.325 on 2026-11-15). Code: `Sources/App/ClaudeCLI.swift` and `Sources/App/Probes.swift` today, `Sources/ClaudeCode/` after step 4 of the [clean-up plan](cleanup-plan.md).

## Accounts

- An account is a config folder. The default one is `~/.claude` and runs **without** `CLAUDE_CONFIG_DIR`: setting it to `~/.claude` makes Claude look for `~/.claude/.claude.json` and warn. Others run with `CLAUDE_CONFIG_DIR=<folder>`.
- Children must not inherit `CLAUDECODE`, `CLAUDE_CODE_*`, `CLAUDE_PID`, `CLAUDE_EFFORT` or `CLAUDE_CONFIG_DIR`. An inherited `CLAUDE_CODE_CHILD_SESSION` turns transcript saving off. `ClaudeCLI.scrubOwnEnvironment` and `env(for:)` handle this.

## Commands and their output

| Command | What Maxwell reads |
|---|---|
| `claude --bg --name <n> [--model m] [prompt]` | The line containing `backgrounded`: `backgrounded · <shortId> · <name> (…)`. Field 2 is the short id. |
| `claude --bg --resume <id> --name <n>` | Same line. `started a copy` in the output means Claude still saw the old process and made a copy. |
| Either, in an untrusted folder | `Workspace not trusted` |
| `claude agents --json` | The account's sessions. Maps `shell` to `busy`, and drops `needs`, `tempo` and `statusUpdatedAt`, so the state files below win. |
| `claude attach <shortId>` | Run in a terminal pane. Ctrl+Z detaches and the session keeps running. |
| `claude stop <shortId>` | Ends the process, keeps the conversation. Maxwell never runs `claude rm`. |

## Files, per account config folder

- **`sessions/<pid>.json`** (interactive and background): `sessionId`, `kind` (`interactive` …), `pid`, `status` = `busy` | `idle` | `waiting` | `shell` (turn over, only background shells running), `waitingFor` (permission prompt, input needed, worker request, sandbox request, dialog open, goal proposal), `statusUpdatedAt`.
- **`jobs/<shortId>/state.json`** (background only): `state` = `working` | `blocked` | `done` | `failed` | `stopped`, `tempo` = `active` | `idle` | `blocked`, `needs` (what it needs from the user, in its words), `detail`, `block.questions` (AskUserQuestion), `inFlight.tasks` and `kinds`. `artifact_watch` and `session_cron` are passive kinds. `timeline.jsonl` sits beside it.
- **`projects/<cwd with non-alphanumerics as "-">/<sessionId>.jsonl`**: the transcript. Maxwell reads the last reply, running tasks, the first prompt, and links to files and artifacts. Subagent transcripts are under `…/subagents/` and are ignored.
- **`.claude.json`** (`~/.claude.json` for the default account): `projects[<path>].hasTrustDialogAccepted`. Maxwell writes it to trust a folder. Claude Code writes the same file, so Maxwell re-reads and retries; this is a known race (clean-up plan, step 4).
- **`settings.json`**: Maxwell's hook and status-line tap are merged in by `Sources/Install/HookInstaller.swift`, keeping key order.

## Hook payloads

Hooks (session start, stop, notification, prompt submit) and the status-line tap append to `~/.local/state/maxwell/events.jsonl`. Fields used: `session_id`, `transcript_path`, `cwd`, `notification_type`, `last_assistant_message`, `prompt`, `source`, `rate_limits` (`used_percentage`, `resets_at`), `context_window`. Real recorded payloads are in `fixtures/events/`; the reducer tests replay them.

## The background service

`claude --bg` starts one `claude daemon run` per config folder if none is running. It owns every background session on that account (through `bg-pty-host` and pre-warmed `bg-spare` processes) and outlives Maxwell. Restarting Maxwell does not restart it.

Known failure: after a Mac or login crash, the service can stay attached to the dead login session. Every session it runs then loses macOS services: `id -un` prints a number, `launchctl` says "141: Reentrancy avoided", audio and the iOS Simulator fail. The fix is to end that `claude daemon run` process and resume the sessions. Maxwell doesn't detect this yet (clean-up plan, step 5).

Processes a background session starts are their own "responsible process" for macOS privacy. They don't get the permissions you gave Warp or Terminal (Files & Folders, Automation, Accessibility). `osascript` to System Events fails with -1743.
