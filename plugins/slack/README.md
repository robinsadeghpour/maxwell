# Slack plugin: who is waiting on a reply from you

A Maxwell plugin (protocol v1, `docs/plugins.md`). It reads your DMs, @mentions and the threads you're in, and lists who is waiting on you. It never posts, reacts, drafts or schedules anything.

- **Answer first:** bugs, customers, and anyone who asked again.
- **Questions and requests:** everything else that waits on you, oldest first.
- **You said you'd do it:** you replied "on it" or reacted 👀. Nobody waits on a reply, but the work is open. It comes back on top if they ask again.

Each row shows who, what they asked, how long ago and where, with the same glyph language as the sessions list. The tab shows how many need you ("SLACK 5"). Click a row to open the message in Slack. **Handled** hides it until they write again.

**Start Session** starts a Claude session with the message, its thread and the link, and links the two:
- The row moves to **In a session**, and clicking it opens the session.
- The session row shows **Slack · Mara**, and its Safe to close list gets **Replied on Slack**, which fails until you've answered in that thread. So a session from Slack is never "safe to close" while the person still waits.
- When the session finishes, the row moves to the top as **Session done, reply**, with **Reply in Slack**.
- The session is told not to post, react or draft in Slack itself, and to end with a two-line reply for you.

Snooze 3h and Not for Me come once the host shows more than two buttons per row. **Slack › Check Slack Now** and **Open Next Slack Message Waiting on You** (⇧⌘S) are in the menu and ⌘K.

How it decides is in `Sources/Waiting.swift`: rules worked out from two weeks of real Slack, no model.

## Connect it (once)

1. In Maxwell, ⌘K › **Connect Slack…**. It opens Slack's "create app" page with the manifest filled in: a user token with read-only scopes (`search:read`, `im:history`, `mpim:history`, `channels:history`, `groups:history`, `users:read`), no bot, no events.
2. Click **Create**, then **Install to Workspace**. If your workspace needs an admin to approve apps, the admin approves it there.
3. Copy the **User OAuth Token** (`xoxp-…`) from OAuth & Permissions into **Settings › Plugins › Slack**. Maxwell keeps it in the Keychain.

`build/slack/maxwell-slack manifest` prints the manifest and the link, if you'd rather create the app by hand.

## Read only, by construction

`Sources/SlackAPI.swift` allows five Web API methods: `auth.test`, `search.messages`, `conversations.history`, `conversations.replies`, `users.info`. Any other method throws before a request is made. The tests check that no source file names a write method and that the manifest asks only for read scopes. Handled, snooze and Not for Me live in the plugin's data folder on your Mac, never in Slack.

Token-like strings in messages show as `•••` in previews.

## One check

Every 2 minutes (setting: 1, 2 or 5), three searches find where something happened in the last 14 days (DMs, mentions of you, your own messages). Then only those conversations and threads are read. A quiet workspace costs about 5 calls a check.

## Develop

```sh
./build.sh          # build/slack: plugin.json, maxwell-slack, fixtures.json
./build.sh test     # rules, marks, panel, session loop, read-only client, recorded API replies
build/slack/maxwell-slack list demo.json   # the list as text, for tuning rules
./snap.sh out line graphite paper  # screenshots in Maxwell from demo.json (needs ../../build/Maxwell.app)
```

It ships inside Maxwell (`../../build.sh` copies it to `Resources/plugins/slack`). To try it without Slack, pick **Demo** in Settings › Plugins › Slack (`slack.source = demo`).

| File | What it does |
|---|---|
| `Sources/Waiting.swift` | The rules. Pure: snapshot in, list out. |
| `Sources/Snapshot.swift` | Conversations and messages, the same from fixtures and from Slack |
| `Sources/Sources.swift` | `FixtureSource` and `WebSource` (Slack API) |
| `Sources/SlackAPI.swift` | The read-only client |
| `Sources/Marks.swift` | Handled, snoozed, not for me |
| `Sources/Links.swift` | Which session works on which message, statuses, the Replied on Slack check |
| `Sources/Panel.swift` | The panel as protocol data |
| `Sources/Plugin.swift` | Polling, actions, status |
| `Sources/Wire.swift` | JSON-RPC over stdio. The only file that knows the wire. |

`demo.json` has invented people and messages for screenshots and Demo mode.
