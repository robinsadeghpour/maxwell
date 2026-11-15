# Linear plugin

Shows which Linear ticket each session works on, with its status, right on the session row.
"Ticket done" counts toward Safe to close. When the work moves, it suggests the matching
ticket move, one click each.

## Connect

One step: create a personal API key in Linear (**Settings › Security & access › New API key**),
then paste it in Maxwell under **Settings › Plugins › Linear › API key**. It's stored in the macOS
Keychain and only this plugin can read it. Without a key the plugin still shows ticket ids from
branch names, and adds no check.

## How a session links to a ticket

1. **The branch.** `robin/acme-56-billing-totals` is ACME-56. Linear's own branch format, or any
   branch segment that starts with one of your team keys. The plugin reads the branch with git when
   Maxwell hasn't yet.
2. **The transcript**, when the branch says nothing. Votes per ticket: a Linear call that changes it
   (status, comment, attachment) 3, Robin naming it in a prompt 2, reading it 1, creating it 1. A
   ticket links with at least 3 votes and twice the runner-up. Text Claude Code injects (CLAUDE.md,
   system reminders) never counts, because it names example tickets.
3. **The PR** adds nothing the branch doesn't: a PR's branch is the session's branch.

## What it shows

- **Row badge:** `ACME-56 · In Progress`. Green when done, amber when a move is suggested. Click
  opens the ticket.
- **Safe to close:** "Linear ticket done" passes when the ticket is Done, Canceled or Duplicate,
  fails otherwise, and is unknown when Linear couldn't be read in the last 10 minutes. Sessions
  without a ticket, or while not connected, get no check.
- **Linear panel** (⌥⌘6, docked right; move it to the bottom from its ⋯ menu): suggested moves
  first, then all your tickets by status (In progress, Todo, Backlog, Done this week), plus any
  ticket a session is on. Each line says how its sessions stand ("2 sessions · 1 needs you"); a
  click opens the most urgent session, or the ticket when it has none.

## Status moves

| When | Suggests |
|---|---|
| A session works on a ticket in Backlog or Todo | Move to In Progress |
| The session's PR is open | Comment "PR #212 is open: <link>" |
| The PR merged and the ticket isn't done | Move to Done |

"In Progress" and "Done" are the team's first started and completed states, so renamed workflows
work. **Not now** hides a suggestion for good. `linear.sync = auto` makes the moves without asking;
`off` shows status only. `linear.writes = dry-run` logs every move and comment to
`~/.local/state/maxwell/plugins/linear/dry-run.jsonl` instead of sending it.

## Develop

`./build.sh test` builds the plugin and runs it under the real host on the fixtures in
`fixtures/linear` (anonymised; team ENG), with every write in dry run.
`MAXWELL_LINEAR_FIXTURES=<dir>` makes the plugin read fixtures instead of the API.
