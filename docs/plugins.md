# Plugins

A plugin adds a tool to Maxwell: Linear, Slack, your own. It runs as its own process, in any
language, and talks to Maxwell with JSON lines over stdin and stdout. A plugin that crashes or
hangs is shown as stopped, with a Restart button. It can't take Maxwell down.

Protocol version: **1**. Status: the first two plugins (Linear, Slack) are being built against it.
Changes are listed in the changelog at the end.

## What a plugin is

A folder with a manifest and a program:

```
~/.config/maxwell/plugins/linear/
  plugin.json        the manifest
  linear             the program (any executable: a binary, a script with a #! line)
```

Maxwell looks in two places, user plugins first:

1. `~/.config/maxwell/plugins/<id>/` (`MAXWELL_PLUGINS_DIR` overrides this, for tests)
2. `Maxwell.app/Contents/Resources/plugins/<id>/` (the plugins that ship with Maxwell)

A user plugin with the same id replaces the bundled one. Installing is copying the folder in.
Maxwell picks it up without a restart.

### The manifest

```json
{
  "id": "linear",
  "name": "Linear",
  "version": "0.1.0",
  "description": "Shows the ticket each session works on and keeps its status current.",
  "protocol": 1,
  "run": ["./linear"],
  "settings": [
    { "key": "api-key", "title": "API key", "type": "secret",
      "help": "Linear › Settings › Security & access › Personal API keys" },
    { "key": "team", "title": "Team key", "type": "string", "default": "", "placeholder": "ACME" },
    { "key": "sync", "title": "Status changes", "type": "choice", "choices": ["suggest", "off"], "default": "suggest" }
  ],
  "actions": [
    { "id": "open-ticket", "title": "Open Ticket in Linear", "scope": "session", "shortcut": "cmd+shift+o" },
    { "id": "refresh", "title": "Refresh Linear", "scope": "global" }
  ],
  "panels": [
    { "id": "tickets", "title": "Linear", "key": "l" }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | Lowercase letters, digits and `-`. Unique. Namespaces everything the plugin contributes. |
| `protocol` | The protocol version it speaks. Maxwell refuses a higher one and says so. |
| `run` | The command, relative to the folder. Runs with the folder as its working directory. |
| `settings` | Fields Maxwell draws in Settings › Plugins. Types: `string`, `bool`, `choice`, `secret`. |
| `actions` | Commands. Each gets a menu item, a search entry in ⌘K and an optional default shortcut. |
| `panels` | Panels Maxwell draws with its own components. They dock like any other panel. |

Everything a plugin can show is declared here, so Maxwell can list it in Settings, the menu and
⌘K before the program has started, and can keep it listed (as unavailable) while it's stopped.

## What a plugin can add

| Where | What | How |
|---|---|---|
| Session row | Badges, like `ACME-56 · In Progress` | `session/annotate` |
| Badge tooltip | Fields (label, value, link) | `session/annotate` |
| Safe to close | Checks, shown with the built-in ones | `session/annotate` |
| Menus, ⌘K, keys | Actions, global or per session | manifest `actions`, run by `action/run` |
| Panels | Lists and empty states drawn natively | manifest `panels`, filled by `panel/set` |
| Notifications | A macOS notification | `notify` |
| Settings | Fields and secrets | manifest `settings` |

Plugin panels share one panel, **Plugins** (⌥⌘6), with a tab each. It docks, collapses and moves
like the other panels, and only exists while a plugin contributes one.

There is no HTML and no custom drawing. A panel is data (sections of rows) and Maxwell draws it
with the same rows, badges and buttons as the rest of the window, in every theme. That keeps
plugins looking native and fast, and it's the main lesson from VS Code (below).

## The wire

Newline-delimited JSON-RPC 2.0, one message per line, UTF-8, on the program's stdin (from
Maxwell) and stdout (to Maxwell). Anything the program writes to stderr goes to
`~/.local/state/maxwell/plugins/<id>.log`, and its last line is shown when the plugin stops.

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}
← {"jsonrpc":"2.0","id":1,"result":{}}
→ {"jsonrpc":"2.0","method":"sessions/changed","params":{...}}
← {"jsonrpc":"2.0","method":"session/annotate","params":{...}}
```

Requests have an `id` and get exactly one response. Notifications have no `id`. Both sides send
both. Unknown notifications are ignored; unknown requests get error `-32601`. Lines over 4 MB are
dropped.

### Maxwell → plugin

**`initialize`** (request), sent once, first.

```json
{ "protocol": 1,
  "maxwell": { "version": "0.1.9" },
  "plugin": { "id": "linear", "dir": "/…/plugins/linear", "dataDir": "~/.local/state/maxwell/plugins/linear" },
  "settings": { "team": "ACME", "sync": "suggest" },
  "appearance": "dark" }
```

Answer `{}` within 10 s, or the plugin is marked failed. `dataDir` exists and is the plugin's to
keep caches in. Secrets are not in `settings`; ask for them with `secrets/get`.

**`sessions/changed`** (notification). The first one after `initialize` has `"full": true` and
every session; later ones carry only the sessions that changed and the ids that are gone.

```json
{ "full": false,
  "sessions": [ {
      "id": "1f0c…", "name": "acme-75", "title": "Billing page totals",
      "project": "Acme", "account": { "id": "work", "name": "work" },
      "cwd": "/Users/…/acme", "branch": "robin/acme-56-billing-totals",
      "group": "yourTurn", "phase": "yourTurn", "question": null,
      "lastMessage": "Done. PR #212 is open.", "lastEventAt": "2026-11-14T15:02:11Z",
      "startedAt": "2026-11-14T13:40:00Z", "transcriptPath": "/Users/…/1f0c….jsonl",
      "pr": { "state": "open", "number": 212 }, "repo": { "dirty": 0, "unpushed": 0 } } ],
  "removed": [] }
```

`group` is the sidebar group: `needsYou`, `yourTurn`, `working`, `limited`, `safeToClose`,
`idle`, `recentlyClosed`. `pr.state` is `none`, `open`, `merged`, `closed` or `unknown`; `pr`
and `repo` are null until the first git check. Read the transcript yourself if you need more;
it's a JSON-lines file Claude Code writes.

**`settings/changed`** (notification): `{ "settings": {…} }`, after the user edits a field.

**`secrets/changed`** (notification): `{ "key": "api-key" }`, after the user saves or clears one.

**`action/run`** (request): the user ran one of the plugin's actions.

```json
{ "action": "open-ticket", "session": "1f0c…", "item": null }
```

`session` is set for `scope: "session"` actions (the selected session, or the row the menu was
opened on). `item` is set when the action came from a panel row (the row's `id`). Answer within
10 s with `{}` or `{ "message": "Moved ACME-56 to In Progress" }`, which Maxwell shows as a toast.
An error response's `message` is shown as a failed toast. Long work: answer first, report later
with `panel/set` or `notify`.

**`shutdown`** (request): answer `null` and exit. Maxwell closes stdin after the answer and sends
SIGTERM 2 s later if the process is still there.

### Plugin → Maxwell

**`session/annotate`** (notification). Everything the plugin says about one session. Each call
replaces the plugin's previous annotation of that session, so sending the same thing twice is
harmless. Send an empty one to clear.

```json
{ "session": "1f0c…",
  "badges": [ { "text": "ACME-56 · In Progress", "tone": "info", "tooltip": "Billing page totals", "action": "open-ticket" } ],
  "fields": [ { "label": "Ticket", "value": "ACME-56 Billing page totals", "url": "https://linear.app/…/ACME-56" } ],
  "checks": [ { "id": "ticket-done", "title": "Linear ticket done", "outcome": "fail",
                "detail": "ACME-56 is In Review", "source": "Linear API 15:04" } ],
  "actions": [ "open-ticket", "move-done" ] }
```

- `tone`: `neutral`, `info`, `good`, `warn`, `bad`. Maxwell maps them to the theme's colours.
- `badges[].action`: clicking the badge runs that action for this session.
- `checks[].outcome`: `pass`, `fail`, `unknown`. See Safe to close below.
- `actions`: which of the plugin's `session` actions apply to this session right now. Only these
  are enabled in its menu and ⌘K while it's selected. Omitted: all of them. A session the plugin
  never annotated has none of its session actions.

**`panel/set`** (notification): what one panel shows.

```json
{ "panel": "tickets",
  "view": { "type": "list", "sections": [ { "title": "Suggested", "rows": [
      { "id": "ACME-56", "title": "ACME-56 Billing page totals", "subtitle": "PR #212 merged · acme-75",
        "badge": { "text": "In Review", "tone": "info" }, "session": "1f0c…",
        "actions": [ { "action": "move-done", "title": "Move to Done" } ] } ] } ] } }
```

View types:

| `type` | Fields |
|---|---|
| `list` | `sections`: `[{ title, rows }]`. A row: `id`, `title`, `key?` (a short id drawn dim before the title, in a column of its own), `subtitle?`, `badge?`, `session?` (click selects it), `url?` (click opens it), `actions?` (buttons; the first is the row's main action), `status?` (below) |
| `empty` | `title`, `body?`, `action?` (`{ action, title }`, a button) |
| `loading` | `title?` |

Until the first `panel/set`, Maxwell shows the panel as loading.

**`status`** (notification): how the plugin is doing, shown in Settings › Plugins and on its panels.

```json
{ "state": "setup", "message": "Add a Linear API key to connect." }
```

`state` is `ok`, `loading`, `setup` (needs a setting or secret), `offline` or `error`.

**`notify`** (notification): `{ "title": "…", "body": "…", "session": "1f0c…" }`. Shown as a
macOS notification if notifications are on; clicking it selects the session.

**`secrets/get`** (request): `{ "key": "api-key" }` → `{ "value": "lin_api_…" }`, or
`{ "value": null }` when it's not set. Only keys the manifest declares as `secret` are readable,
and only by that plugin.

A row's `status` says where the item stands, in words every plugin shares, and Maxwell draws it with
the session glyphs: `needsYou` ●, `inSession` (the working spinner), `readyToClose` ◐ (its session is
done, something is left for you), `owed` ◇ (you said you'd do it), `done` ✓. Plugins never pick colours.
`panel/set` may carry `"count": 3`: how many items need you, shown on the panel's tab.

**`session/start`** (request): `{ "prompt": "…", "name": "slack-mara", "cwd": null, "model": null }` →
`{ "session": "1f0c…" }`. Starts a background session the way ⌘T does (the current project's folder,
the account with the most room), with the prompt, and selects it. `cwd` and `model` override. An
error's `message` says why (no folder, folder not trusted). Answer `action/run` first and call this
after: starting can take longer than 10 s.

**`open`** (request): `{ "url": "https://linear.app/…" }` → `{}`. Opens the link the way Maxwell
opens links. Use it instead of running `open` yourself.

**`log`** (notification): `{ "level": "info", "message": "…" }`, written to the plugin's log.

## Safe to close

A plugin's checks join the built-in ones. The rules are Maxwell's, not the plugin's:

1. **Unknown is never safe.** A plugin check that is `unknown` or `fail` keeps the session out of Safe to close.
2. **A plugin that isn't running can't vouch.** When a plugin stops, crashes or fails to start,
   every check it had reported turns `unknown` ("Linear isn't running"), until it reports again.
3. **Old evidence doesn't count.** A check reported before the session's last activity is
   `unknown` ("checked before the last activity"). Re-annotate when `sessions/changed` brings
   the session.
4. **Checked again at the moment of closing.** Close asks every plugin that has a check on the
   session for a fresh annotation (it sends that session in `sessions/changed`) and waits up to
   5 s. No answer: unknown, skipped.
5. **The plugin chooses which sessions it checks.** A session it never annotated with a check has
   no check from it. Linear only checks sessions it linked to a ticket, and only once a key is set;
   from then on its check is there even while Linear can't be reached (as unknown).
6. **Turning a plugin off removes its checks.** That's the user saying they don't want them.

## Settings and secrets

Settings live in the Maxwell config file, namespaced by plugin id, Ghostty style:

```
linear.team = TIN
linear.sync = suggest
linear.enabled = false     # turn a plugin off (default: on)
```

Settings › Plugins draws the manifest's fields and writes these lines.

Secrets never go in the config. A `secret` field shows a password box. Maxwell stores the value in
the macOS Keychain (service `Maxwell plugin <id>`, account `<key>`) and hands it only to that
plugin, through `secrets/get`. A plugin never reads the Keychain or other plugins' secrets.

## Running, failing, restarting

- Maxwell starts every enabled plugin after its window is on screen, so plugins never slow launch.
- Each plugin gets the environment of a login shell, minus `CLAUDE_*` variables, plus
  `MAXWELL_PLUGIN_ID`, `MAXWELL_PLUGIN_DATA` and `MAXWELL_PROTOCOL=1`.
- If it exits or stops answering, Maxwell marks it stopped, turns its checks unknown, keeps its
  badges dimmed, and restarts it after 1 s, then 5 s, then 30 s. After three failures in five
  minutes it stays stopped: Settings › Plugins and its panels show **Linear stopped: \<last line
  of stderr\>** with **Restart** and **Open Log**.
- A plugin that floods (over 200 messages a second) is stopped the same way.
- Turning a plugin off sends `shutdown`. Turning it on starts it.

## Writing one

The smallest plugin is a script. `examples/plugins/hello/` in the repo is a complete one in
Python, under 80 lines: it badges every session with its branch and adds a panel and an action.
Copy the folder to `~/.config/maxwell/plugins/hello/` to try it.

Swift plugins can use `plugins/sdk/MaxwellPlugin.swift`, one file that does the wire for you.

Debug with **Open Log** in Settings › Plugins, or run the program by hand and type the JSON lines.

## Prior art: what we took and what we left

**VS Code extensions.** Took: a manifest that declares contributions (commands, keybindings,
settings, views) so the host can show them before the code runs; ids namespaced by extension;
settings in the user's normal config file. Left: running extensions inside the host's JS runtime
(one slow extension stalls the others), webviews (heavy, and they never look native), and
activation events (we start plugins after launch instead; there are few of them).

**Raycast extensions.** Took: the UI is described as data (List, Detail, Action) and drawn by
the host, so every extension looks like Raycast. That's the reason panels here are lists of rows
and not HTML. Left: the React and Node runtime, which ties plugins to one language.

**Zed extensions.** Took: plugins are sandboxed from the host and declare what they need. Left:
WebAssembly as the only target, which makes small scripts hard to write.

**LSP and MCP.** Took: JSON-RPC 2.0 over stdio with an initialize handshake, a separate process
per server, requests and notifications in both directions, any language. From MCP's stdio
transport: newline-delimited JSON instead of LSP's Content-Length headers, so a plugin can be a
twenty-line script.

**Ghostty's config.** Took: one plain-text file of `key = value` lines, the Settings window
writes the same lines, comments survive. Plugin settings are just more lines.

**Kept out on purpose:** plugins can't run code in Maxwell, draw their own pixels, read other
plugins' secrets, or decide a session is safe to close on their own. They can only add evidence,
and evidence they stop giving turns into unknown.

## Changelog

- **1** (14 Nov 2026): first version.
- **1, additions** (15 Nov 2026): `session/start`; row `status`; `panel/set` `count`. Optional; older
  plugins are unaffected.
- **1, clarified** (14 Nov 2026): session actions are off for sessions the plugin never annotated.
  Plugin panels are tabs of one Plugins panel (⌥⌘6). A plugin's default shortcut is dropped when a
  built-in action already uses it. A plugin that is restarted counts as not running until it
  answers `initialize` again. No wire change.
