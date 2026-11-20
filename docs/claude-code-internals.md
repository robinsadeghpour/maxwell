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
| Waking a stopped background session whose folder was deleted | `claude attach <short>` and `claude --bg --resume <id>` (no flags) always wake it in its saved folder and fail: `Couldn't wake <short> — Workspace not trusted. <folder> could not be resolved on disk.` Any flag (`--name`) makes `--bg --resume` start a copy in the current folder instead, with the whole conversation (2.1.328). `GoneFolder` picks the folder; Maxwell continues the copy there and closes the old record. |
| `/resume` in a session, picking a conversation from another folder | Claude Code doesn't switch folders. It prints `This session is from a different directory.`, `To resume, run:` and `cd <folder> && claude --resume <session id>` on the session's screen, and copies the command (2.1.327). `ResumeElsewhere.parse` reads it off the screen; a narrow pane breaks the line. |
| Either, in an untrusted folder | `Workspace not trusted` |
| `claude agents --json --all` | The account's sessions. Maps `shell` to `busy`, and drops `needs`, `tempo` and `statusUpdatedAt`, so the state files below win. `--all` adds background sessions with no process (no `pid`): `done` after the idle stop below, `stopped` after `claude stop`, `failed` after a crash. A waiting session the idle stop ended stays in the plain listing without a `pid`. |
| `claude attach <shortId>` | Run in a terminal pane. Ctrl+Z detaches and the session keeps running. |
| `claude attach <shortId>`, twice at once | Several attaches share one background session; what one types shows in the others (2.1.327, 18 Nov 2026). The phone bridge relies on it: its windowless attach (`Sources/ClaudeCode/AttachTerminal.swift`) runs beside the Mac's pane. Hanging up the terminal (SIGHUP, closing the pty) ends the attach and leaves the session running, like closing a pane. |
| Typing into an attached session | Text and Return in one write arrive as a paste and are not sent: the bridge writes the text, waits for it to echo, then writes `\r` (2.1.327). Several lines go in one bracketed paste (`ESC[200~ … ESC[201~`). Esc ends the turn; one pressed before Claude wrote anything puts the prompt back in the input, and what is typed next is added to it (2.1.328). Ctrl-U deletes to the line start, at a line start joins the line above, and does nothing on an empty prompt; a write of 64 bytes or more reads as a paste and the Ctrl-Us in it are dropped (60 still work). So the bridge empties the prompt with 30 Ctrl-Us in their own write before it types (`PromptInput`, checked 19 Nov 2026 in a pty and with `test-phone-ops.mjs`). |
| A permission prompt | Answered by its number keys without Return: `1` allows, `2` allows from now on (for the folder or command), Esc denies (2.1.327, checked with a Bash `mkdir` in `--permission-mode default`). Auto mode (an account's default) runs many commands without asking, so a test needs `--permission-mode default`. |
| `claude stop <shortId>` | Ends the process, keeps the conversation. Maxwell never runs `claude rm`. |

## Files, per account config folder

- **`sessions/<pid>.json`** (interactive and background): `sessionId`, `kind` (`interactive` …), `pid`, `status` = `busy` | `idle` | `waiting` | `shell` (turn over, only background shells running), `waitingFor` (permission prompt, input needed, worker request, sandbox request, dialog open, goal proposal), `statusUpdatedAt`. Also `name` and `nameSource`: `user` after `/rename` or `claude --name` (2.1.327), `derived` for a generated name, `peer` for one a launcher passed with `--bg --name`; `claude agents --json` shows the same `name` but not its source.
- **`jobs/<shortId>/state.json`** (background only): `state` = `working` | `blocked` | `done` | `failed` | `stopped`, `tempo` = `active` | `idle` | `blocked`, `needs` (what it needs from the user, in its words), `detail`, `block.questions` (AskUserQuestion), `inFlight.tasks`, `kinds` (each kind once, not once per task) and `drainableMonitors` (file watchers such as `artifact_watch`), `fan` (one entry per shell, agent, workflow or monitor, with `doneAt` once finished; watchers are not in it), and `updatedAt`. Real background work is the `fan` entries without `doneAt`; without `fan`, `tasks − drainableMonitors`. The verdict is written a moment after the turn ends (seen within the same 0.25 s poll in 2.1.325, Nov 2026); until then `tempo` stays `active`. A record older than the current turn is the previous turn's. `timeline.jsonl` sits beside it.
- **`projects/<cwd with non-alphanumerics as "-">/<sessionId>.jsonl`**: the transcript. Maxwell reads the last reply, running tasks, the first prompt, and links to files and artifacts. Subagent transcripts are under `…/subagents/` and are ignored. Running tasks (`Sources/Model/TaskLedger.swift`): a shell starts with `toolUseResult.backgroundTaskId`, an agent with `toolUseResult.isAsync` + `agentId` + `description`. A `<task-notification>` with `<task-id>` and a `<status>` other than `running` ends it, and so does a TaskStop result ("Successfully stopped task", `task_id`). Exception: an agent that ends its turn with background work of its own reports `completed` with the note "This agent stopped with background work of its own still running", then notifies again under the same id ("… finished") when it is really done.
- **`.claude.json`** (`~/.claude.json` for the default account): `projects[<path>].hasTrustDialogAccepted`. Maxwell writes it to trust a folder. Claude Code writes the same file, so Maxwell re-reads and retries; this is a known race (clean-up plan, step 4).
- **`settings.json`**: Maxwell's hook and status-line tap are merged in by `Sources/Install/HookInstaller.swift`, keeping key order.

**Transcript lines the phone's conversation reads** (`Sources/Model/ChatItems.swift`, 2.1.327): `type` `user` with `message.content` a string (what you typed; `<command-name>/x</command-name>` and `<command-args>` for a slash command; `[Request interrupted by user…]` after Esc) or blocks (`tool_result` with `tool_use_id` and `is_error`, plus a top-level `toolUseResult`); `type` `assistant` with `text`, `thinking` and `tool_use` (`id`, `name`, `input`) blocks, one block per line; `type` `system` with `subtype` `compact_boundary`. `isMeta` and `isSidechain` lines are left out. An Edit's or Write's `toolUseResult.structuredPatch[].lines` start with `+`, `-` or a space; a new file's is `{"type": "create", "content": …}`. A Bash result has `interrupted`.

## Hook payloads

Hooks (session start, stop, notification, prompt submit) and the status-line tap append to `~/.local/state/maxwell/events.jsonl`. Fields used: `session_id`, `transcript_path`, `cwd`, `notification_type`, `last_assistant_message`, `prompt`, `source`, `rate_limits` (`used_percentage`, `resets_at`), `context_window` (`total_input_tokens`, and `used_percentage` of `context_window_size`, which is 1,000,000 on 1M-context models; 2.1.327). Real recorded payloads are in `fixtures/events/`; the reducer tests replay them.

`rate_limits` reaches only the `statusLine` command in `settings.json`, never a hook, and is missing from its payload until the session's first reply (2.1.329). An account with no `statusLine` therefore reports no usage, so install-hooks gives it `maxwell-hook --statusline` as its status line. A status-line command that prints nothing draws nothing in the terminal (2.1.329).

## The background service

`claude --bg` starts one `claude daemon run` per config folder if none is running. It owns every background session on that account (through `bg-pty-host` and pre-warmed `bg-spare` processes) and outlives Maxwell. Restarting Maxwell does not restart it.

Known failure: after a Mac or login crash, the service can stay attached to the dead login session. Every session it runs then loses macOS services: `id -un` prints a number, `launchctl` says "141: Reentrancy avoided", audio and the iOS Simulator fail. The fix is to end that `claude daemon run` process and resume the sessions. Maxwell doesn't detect this yet (clean-up plan, step 5).

The service stops an idle background session to free memory: one that is finished or waiting for your reply, has nothing running, and has had nothing attached for about an hour (sooner when memory runs low). Its log says `bg retire <shortId>: idle-prompt, idle 116m` or `settled`. A stopped session leaves `claude agents --json` and is listed only by `--all`, as `done`. `claude attach` resumes it, and `claude stop` on it exits 0. A session with a `claude attach` running is never stopped, so Maxwell lets go of terminals that have been off screen for 10 minutes (`TerminalRelease`), and keeps a session that leaves the listing while it waits on you where it was, parked, instead of ending it. Seen in 2.1.325.

Processes a background session starts are their own "responsible process" for macOS privacy. They don't get the permissions you gave Warp or Terminal (Files & Folders, Automation, Accessibility). `osascript` to System Events fails with -1743.

## Timing seen in a soak test (2.1.325, 15 Nov 2026)

- `sessions/<pid>.json` changes status within about 0.1 s of the event. The Stop hook runs a moment after `status` turns idle.
- The `permission_prompt` Notification hook arrives about 6 s after `status` turns `waiting`, with vaguer text ("Claude needs your permission") than `jobs/<id>/state.json`'s `needs` ("approve Bash: curl …").
- Esc ends a turn with no Stop hook; only `status` changes.
- A hook's stdout on `SessionStart` and on `UserPromptSubmit` (exit 0) is added to the session's context (2.1, 2026-11-15). The hook prints the status-line rule on SessionStart, or on the first prompt of a session that started without it, and records that in `<state dir>/briefed/<session id>`.
- Stop fires while a background subagent or shell still runs; `status` stays `busy` (subagent) or becomes `shell`.

## Cloud sessions

Seen in 2.1.325. Read in `Sources/ClaudeCode/CloudSessions.swift`, parsed in `Sources/Model/Cloud.swift`.

| What | What Maxwell assumes |
|---|---|
| `claude --cloud "<task>"` | Interactive only (with `-p` it refuses), so Maxwell runs it under `/usr/bin/script` for a terminal. Prints `Created cloud session: <title>`, `View: <url>`, `Resume with: claude --teleport <id>`, then exits. In a folder the account hasn't trusted, it stops at the trust dialog: Maxwell asks first. |
| `claude -p "<text>" --cloud <id>` | Queues a message for the session, prints `Sent to cloud session.`, exits 0. |
| `claude --cloud <id>` | Attaching a terminal to a cloud session: "not enabled for your account" here, so Maxwell shows the claude.ai/code page instead. |
| `claude --teleport <id>` | Fetches the session and continues it locally; checks out its branch, so Maxwell runs it in a new worktree under `.claude/worktrees/cloud-<id suffix>`. |
| Login | Keychain generic password `Claude Code-credentials` for `~/.claude`, `Claude Code-credentials-<first 8 hex of SHA-256 of the config folder>` for others; JSON `claudeAiOauth.accessToken` and `expiresAt` (ms). Read with `/usr/bin/security find-generic-password -s <name> -w`. Maxwell never refreshes it. |
| `GET https://api.anthropic.com/v1/sessions?beta=true&limit=100` | Headers `Authorization: Bearer`, `anthropic-version: 2023-06-01`, `anthropic-beta: ccr-byoc-2025-07-29`. `data[]`: `environment_kind` (`anthropic_cloud` for cloud sessions, `bridge` for Remote Control ones), `session_status` (`pending`, `running`, `idle`, `needs_answer`, `requires_action`, `paused`, `failed`, `archived`), `post_turn_summary` (`status_category`: `working`, `completed`, `review_ready`, `needs_action`, `blocked`, `failed`; `status_detail`; `needs_action`), `external_metadata.current_branches`, `session_context.sources[].url`, `title`, `created_at`/`updated_at` with microseconds. `session_url` is empty in the list; the page is `https://claude.ai/code/<id>`. |
| `POST /v1/sessions/<id>/archive?beta=true` | Body `{}`. Archives it; `session_status` becomes `archived`. |
