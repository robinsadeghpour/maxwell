# Phone

Maxwell's phone app shows the same sessions as the Mac: every group, the conversation, artifacts signed in to the right account, usage, and starting, closing and moving sessions. The app talks only to Maxwell on your Mac, through the **bridge** (`Sources/Bridge/`). This page is the contract between the bridge, the relay and the app.

Protocol version: **1**.

## How the phone reaches the Mac

```
iPhone app  ⇄  relay (Cloudflare Worker, one room per Mac)  ⇄  bridge in Maxwell.app  ⇄  Store, transcripts, `claude attach`
```

- Both sides connect **out** to the relay over WebSocket, so it works from anywhere: no open ports, no VPN, no Tailscale.
- Every message is encrypted on the Mac or the phone before it leaves. The relay forwards bytes it can't read.
- The relay keeps no messages. When either side is offline, the other side's commands wait in its own outbox and are sent again on reconnect. State is a snapshot, so a missed update never matters: the next one replaces it.
- Pushes go from the Mac straight to Expo's push service with the phone's push token. They do not pass through the relay.

The relay URL is `phone-relay` in the config (`docs/config.md`). Settings › Phone shows the pairing code, the paired phones and a Remove button for each.

## Pairing

1. Settings › Phone › Pair a phone shows a QR code holding a link:

   ```
   maxwell://pair?v=1&relay=<wss url, encoded>&mac=<mac id>&k=<pairing key>&name=<Mac name, encoded>
   ```

   - `mac`: this Mac's room id, 16 random bytes, base64url without padding. Made once and kept in the Keychain.
   - `k`: 32 random bytes, base64url. A new one for each code shown. The code expires after 10 minutes or the first pairing, whichever is first.
2. The phone scans it, makes its own phone id (16 random bytes, base64url), joins the room as that phone and sends `pair` (below), encrypted with `k` like every later message: `phoneToMac` from `k` (see Encryption). The `phone` field must be the id it joined with.
3. The bridge tries `k` of every unexpired code. When one opens the message, `k` becomes that phone's key, stored in the Keychain under the phone id, and the code is spent. It answers `paired`, sealed with `macToPhone` from `k`. A known phone may pair again with a new code; the new key replaces the old.
4. From then on the phone sends `hello` on every connect.

Removing a phone deletes its key. Its messages no longer open, and the bridge ignores them.

## Encryption

Both directions use ChaCha20-Poly1305 (IETF, 12-byte nonce) with keys derived from the phone's key `k`:

```
macToPhone = HKDF-SHA256(ikm: k, salt: "maxwell-phone-1", info: "mac→phone", length: 32)
phoneToMac = HKDF-SHA256(ikm: k, salt: "maxwell-phone-1", info: "phone→mac", length: 32)
```

A box is `base64url(nonce ‖ ciphertext ‖ tag)` with a random 12-byte nonce. The plaintext is one JSON object (UTF-8). On the Mac this is CryptoKit's `ChaChaPoly.SealedBox.combined`; on the phone `@noble/ciphers` `chacha20poly1305`.

## The relay

`wss://<relay>/room/<mac id>?role=mac&token=<mac token>` or `?role=phone&phone=<phone id>`.

- **Mac token**: 32 random bytes the bridge makes once and keeps in the Keychain. The first Mac to connect to a room claims it (the relay stores the token's SHA-256); after that a Mac connection needs the same token.
- **Frames** are JSON text:
  - Mac → relay: `{"to": "<phone id>", "box": "…"}`. Only the phone with that id gets it.
  - Phone → relay: `{"box": "…"}`. The relay delivers `{"from": "<phone id>", "box": "…"}` to the Mac; it sets `from` from the connection, so a phone can't pretend to be another.
  - Relay → anyone: `{"presence": {"mac": true|false}}` to phones, `{"presence": {"phone": "<id>", "online": true|false}}` to the Mac, sent on connect and on every change.
- **Keepalive**: either side sends the exact text `{"ping":1}` every 25 s; the relay answers `{"pong":1}` (Cloudflare answers it without waking the room). No pong for 10 s means the connection is dead: close it and reconnect.
- **Reconnect**: after 0.5 s, then doubling to 15 s at most, with ±20% jitter. On the phone, also at once when the app comes to the foreground or the network changes.
- A frame over 1 MB is refused (the bridge sends large things in parts).

## Messages

Every message is `{"t": "<type>", …}` inside a box.

### Phone → Mac

| `t` | Fields | Answer |
|---|---|---|
| `pair` | `phone` (id), `name` (e.g. "Robin's iPhone"), `app` (version) | `paired` |
| `hello` | `app`, `push` (Expo push token or null), `focus` (session id or null) | `state`, then `transcript` for `focus` |
| `focus` | `session` (id or null), `terminal` (`{cols, rows}` or null) | `transcript` with `reset: true`; with `terminal`, `term` data too. `hello`'s `focus` is a focus without `terminal`. |
| `cmd` | `id` (unique, made by the phone), `op`, op fields (below) | `ack` with the same `id` |
| `input` | `session`, `data` (UTF-8 text typed in the Terminal tab, including control characters) | none |
| `resize` | `session`, `cols`, `rows` | none |

`cmd` ops:

| `op` | Fields | What the Mac does |
|---|---|---|
| `send` | `session`, `text` | Types `text` into the session and presses Return. A session that stopped (idle stop, limit) is attached first, which resumes it. |
| `permission` | `session`, `decision`: `allow`, `allowAlways` or `deny` | Answers the permission prompt the session shows. Fails with `no-prompt` when it isn't showing one any more. |
| `interrupt` | `session` | Presses Esc: Claude stops the current turn. |
| `start` | `cwd`, `prompt`, `account` (id or null for the one with most room), `name` (or null) | Starts a background session, like ⌘N. `result`: `{"session": id}`. |
| `close` | `session` | Same as Close Session on the Mac: closes at once when safe, otherwise fails with `not-safe` and `detail` listing what is still open. |
| `closeSafe` | `sessions` (ids the phone showed as safe) | Close all safe, re-checked on the Mac. `result`: `{"closed": [ids], "skipped": [ids]}`. |
| `forceClose` | `session` | Closes even when not safe (the phone asked "Close anyway?" first). |
| `move` | `session`, `account` (id or null for most room) | Moves a limited session to another account with a handover prompt. `result`: `{"session": new id}`. |
| `resumeAtReset` | `session` | Sends "continue" when the account's limit resets. `result`: `{"at": ISO}`, when it will. |
| `rename` | `session`, `title` | Renames, like the Mac's Rename. |
| `artifactLogin` | `account` | `result`: `{"cookies": [cookie…]}`, the account's claude.ai cookies from the Mac's sign-in, so artifacts open signed in on the phone. Fails with `signed-out` when that account isn't signed in on the Mac. |

The Mac remembers the last 500 command ids. A repeated id gets the first answer again and does nothing twice, so the phone can safely resend anything not yet acknowledged. A resend while the first is still running gets no second answer; the first answer comes when it is done.

Error codes in `ack.error.code`:

| `code` | When |
|---|---|
| `unknown-session` | The Mac doesn't know that session any more. |
| `read-only` | `send`, `permission`, `interrupt`, `close`, `forceClose` or `resumeAtReset` on a session with `reach` `terminal` or `cloud`. |
| `no-prompt` | `permission` while the session shows no permission prompt. |
| `not-safe` | `close` on a session that isn't safe now; `detail` is the checks still open, `[{"name", "ok": false, "detail"}]`. |
| `untrusted` | `start` in a folder Claude Code hasn't been allowed to work in yet. Start one there on the Mac once. |
| `no-room` | `start` or `move` with no account that has room. |
| `signed-out` | `artifactLogin` for an account not signed in to claude.ai on the Mac. |
| `bad-request` | A field is missing or wrong (no text, unknown decision, a folder that isn't on the Mac). |
| `unknown-op` | An op this Maxwell doesn't know (an older Mac). |
| `failed` | Anything else; `message` says what, in words for the user. |

### Mac → Phone

| `t` | Fields |
|---|---|
| `paired` | `mac` (`{"name": "Robin's MacBook Pro"}`) |
| `state` | `rev` (rises by one each time), `mac`, `accounts`, `sessions`, `projects`, `artifacts`, `at` (ISO time). The whole picture, sent after `hello` and after every change (at most every 300 ms). |
| `transcript` | `session`, `reset` (true: replace what you have), `items` (append in order) |
| `term` | `session`, `data` (base64 of the terminal's output bytes, at most 256 KB a message; a long burst comes as several) |
| `ack` | `id`, `ok`, `result` (object) or `error` (`code`, `message`, `detail`) |
| `bye` | `reason` (`removed`: this phone was removed in Settings) |

### Shapes

**Session** is the plugin protocol's session (`docs/plugins.md`, `sessions/changed`) plus:

| Field | Meaning |
|---|---|
| `group` | `needsYou`, `yourTurn`, `working`, `limited`, `safeToClose`, `idle`, `recentlyClosed` |
| `ask` | null, or `{"kind": "permission", "tool": "Bash", "detail": "npm run db:migrate -- --env staging"}`, or `{"kind": "question", "text": "…", "options": ["…"]}` |
| `checks` | For Your turn and Safe to close: `[{"name": "Pushed", "ok": true, "detail": "…"}]`, Maxwell's checks with their evidence |
| `limitResetsAt` | ISO time, for Limited |
| `contextPercent` | Context window used, 0–100, or null |
| `reach` | `background` (Maxwell can type into it), `terminal` (runs in a terminal elsewhere: read-only), `cloud` |
| `pinned` | You pinned it on the Mac (bool). |

`lastMessage` is cut to its first 1500 characters here (the conversation has all of it), and left out (null) when the whole state would come near the relay's 1 MB. `question.options` is empty for now: Claude Code's question dialog doesn't say its options anywhere Maxwell reads yet.

**Account**: `id`, `name`, `email` (or null), `fiveHour` and `week` (`{"percent": 49, "resetsAt": ISO}` or null), `sampledAt`, `limited` (bool), `mostRoom` (bool, exactly one account, the one ⌘T would pick), `webSignedIn` (bool).

**Project**: `name`, `folder`, `pinned`.

**Artifact**: `url`, `title`, `session`, `account`, `at`.

**Transcript item**, one of:

```json
{"k": "you", "text": "Add magic-link sign-in…", "at": "…"}
{"k": "claude", "text": "Tests pass. The migration adds…", "at": "…"}        // Markdown
{"k": "tool", "id": "toolu_…", "tool": "Edit", "summary": "auth/callback.ts", "added": 42, "removed": 8}
{"k": "tool", "id": "toolu_…", "tool": "Bash", "summary": "npm test", "status": "ok"|"failed"|"running"}
{"k": "artifact", "url": "https://claude.ai/artifact/…", "title": "Onboarding copy v3"}
{"k": "note", "text": "Session moved to personal"}
```

Items come from the session's transcript file. The first `focus` sends the last 300; then new ones as they are written. A tool item shows when Claude calls the tool (a command as `running`, an edit without counts) and comes again with the same `id` once its result is in: **replace the item with that `id`**, don't append it. `status` can also be `failed` on other tools whose call failed. `you` and `claude` items are cut at 20,000 characters. A `transcript` too big for one message comes in parts; only the first carries `reset: true`.

**Cookie**: `name`, `value`, `domain`, `path`, `expires` (ISO or null), `secure`, `httpOnly`.

## Pushes

The bridge sends a push for each new Needs you to every paired phone with a push token (Your turn pushes wait for a setting the phone can send), through `https://exp.host/--/api/v2/push/send`. It sends none while the Mac is in use: input in the last 2 minutes and the screen unlocked.

```json
{"to": "<expo token>", "title": "web-auth needs you", "body": "Run npm run db:migrate -- --env staging?",
 "categoryId": "permission", "mutableContent": true, "threadId": "<session id>",
 "data": {"session": "<id>", "counts": {"needsYou": 2, "yourTurn": 2, "working": 3, "limited": 1, "safeToClose": 2}, "at": "…"}}
```

Categories: `permission` (Allow, Allow for this folder, Deny, Reply), `question` (Reply, plus up to three options), `turn` (Reply, Go on). `counts` keeps the phone's widgets current even while the app isn't running.

Note: the title and body pass through Expo and Apple in readable form, like any notification. Everything else stays end-to-end encrypted.

## Checking the bridge

End to end against a local relay (`npx wrangler dev --port 8787` in the relay's folder), with a test phone made from the relay's `tools/protocol.mjs`:

```sh
cp ~/.config/maxwell/config /tmp/mx-phone.config && echo 'phone-relay = ws://127.0.0.1:8787' >> /tmp/mx-phone.config
MAXWELL_CONFIG=/tmp/mx-phone.config MAXWELL_PHONE_PAIR_FILE=/tmp/mx-pair-link build/Maxwell.app/Contents/MacOS/Maxwell --quit-after 300 &
node tools/test-phone.mjs /tmp/mx-pair-link <session name prefix> [message] [--permission]
```

`MAXWELL_PHONE_PAIR_FILE` works only in a quiet run (`Sources/Harness/PhoneHarness.swift`): Maxwell makes a code at launch and writes its link there. Quiet runs keep keys in memory, so each run is a new room.

## Changelog

- **1** (Nov 2026): first version.
