# Maxwell config

`~/.config/maxwell/config`, Ghostty style: one `key = value` per line. Maxwell reloads it when you save. The Settings window (⌘,) writes the same file.

```
appearance = system           # system (follow macOS) | light | dark; ⇧⌘L switches
theme-light = paper           # paper | silver-light | <your theme file>
theme-dark = graphite         # graphite | silver | <your theme file>
# theme = silver              # one fixed theme; wins over appearance until you use the switch
background-opacity = 0.74     # glass tint 0.3 … 1; unset uses the theme's. Panes with text never go below 0.72
background-blur = 20          # frost radius 0 (clear) … 64; unset uses the macOS frosted material
motion = on                   # off: no slides or fades (also off under Reduce Motion)
font-size = 13                # lists, panels and the viewer
terminal-font-size = 12       # ⌘− and ⌘= change this one
notify = true                 # macOS notification when a session needs you
notify-sound = Funk           # none | Basso Blow Bottle Frog Funk Glass Hero Morse Ping Pop Purr Sosumi Submarine Tink
notify-done = false           # true: also one when a session finishes its turn
notify-done-sound = Submarine # same choices as notify-sound
auto-open = true              # open .md files a session writes or names, and artifacts it publishes
artifacts = viewer            # viewer: artifacts open beside the session, signed in to its account | browser
browser = work2 zen container Claude Tinkers 2   # <account> <browser> [profile|container <name>]
file-tree = false
app-icon = auto               # auto | light | dark | paper | graphite | light-eyes | dark-eyes
idle-after = 24h              # stopped sessions quiet this long fold into Idle (24h, 90m, 2d)
judge = on                    # off: no model read, so nothing is ever safe to close
crash-reports = on            # off: never send crash reports (runmaxwell.com/docs/privacy#crash-reports)
phone-relay = wss://maxwell-relay.maxwell-relay.workers.dev   # the default; your own relay, or off
account = work ~/.claude      # <name> <CLAUDE_CONFIG_DIR>, one line per account
project = Orbit ~/projects/orbit*     # <name> <path glob>; default: the git repo, worktrees included
project-pin = Acme            # one line per project kept on the rail, in order; none = all
project-logo-style = engraved # engraved | pixel | monogram
project-logo = Acme ~/projects/acme/apps/web/app/icon.png
rail = auto                   # auto (slides in at the left edge) | shown
rail-delay = 0.18             # seconds at the edge before it slides in
keybind = cmd+shift+n=new-session
```

⌘J for the bottom panel, VS Code style:

```
keybind = cmd+j=toggle-bottom
keybind = cmd+shift+j=next-needs-you
```

## Appearance

Themes come as a pair, one light and one dark, and follow macOS unless `appearance` pins a side.
The quick switch is ⇧⌘L or View › Appearance. Settings › Appearance has the same choices plus the
glass sliders, which preview live and write `background-opacity` and `background-blur` on release.

A theme file (`Resources/themes/<name>`, or your own in `~/.config/maxwell/themes/<name>`) can set
its own `background-opacity` and `background-blur`; the config keys override every theme.

`theme = <name>` still works and shows that one theme whatever the appearance. The first time you use
the switch, Maxwell moves it into `theme-light` or `theme-dark` (by the theme's own `appearance`) and
removes the `theme` line, so the switch takes effect.

Contrast: the tint under panes with text never drops below 72%, and the unfocused-pane dim is 18%
white on the light themes and 23% black on the dark ones, so body text stays above 4.5:1 with the
glass at its extremes (see `docs/design-rounds.md`, round 7).

## Artifacts

A claude.ai artifact a session publishes (or opens, or names in its reply) opens in the viewer like a
Markdown file, signed in to claude.ai as that session's account. Publishing it again reloads it in place,
even when it is pinned. Click an artifact link in the terminal to open it the same way. A plain click
is enough: Maxwell takes it before Claude Code would hand it to the system browser. A plain click on a
file path in a session's terminal opens that file in the viewer too, when it exists.

Each account has its own WebKit data store inside Maxwell, so logins never mix. Sign in once per
account, in the viewer or in Settings › Accounts; it is claude.ai's own page (Google and email work;
Sign in with Apple does not load in an embedded view). An emailed sign-in link can be pasted with
**Paste link** above the page. Sign out removes everything that account stored.

`browser = <account> <browser> [profile|container <name>]` picks where **Open in browser** (⇧⌘O) sends
that account's links, and where artifacts go with `artifacts = browser`. Browsers: `default`, `zen`,
`firefox`, `chrome`, `brave`, `edge`, `vivaldi`, `arc`, `safari`. Firefox-family profiles go by name
(profiles.ini), Chromium profiles by folder (`Default`, `Profile 1`). Containers need the
[Open external links in a container](https://addons.mozilla.org/firefox/addon/open-url-in-container/)
add-on, which handles the `ext+container:` links Maxwell sends. Settings › Accounts lists what is installed.

Only one artifact page is live at a time (each costs a 200+ MB WebKit process); showing another
account's artifact closes the previous one, and a hidden one closes after a minute.

## Project logos

A project's logo is, in order: its `project-logo` line (Settings › Projects › Choose… writes it), then the
first image in the folders its sessions run in: an Xcode `AppIcon.appiconset`, then `apple-touch-icon*`,
then `icon.png`/`icon.svg`/`app-icon*`, then `logo*`, then `favicon*` (not `.ico`), shallower first, then
`.github/logo.svg`; with none, a two-letter monogram. Maxwell's own key is the app icon's demon.

## Plugins

Each plugin's settings are lines named after it. Settings › Plugins writes them; secrets such as
API keys go in the Keychain, never here. See [`plugins.md`](plugins.md).

```
linear.enabled = true         # false turns a plugin off (default: on)
linear.sync = suggest         # suggest | auto | off: ticket status moves
linear.writes = live          # live | dry-run: dry run logs moves and comments instead of sending
```

## Keys

Settings › Keys lists every action. Click a shortcut, press the new keys; ⌫ clears it, Esc cancels.
It writes `keybind = <keys>=<action>` lines; `none` removes a default shortcut.

## Phone

The phone bridge to Maxwell's iPhone app ([phone.md](phone.md)) connects to Maxwell's relay,
`wss://maxwell-relay.maxwell-relay.workers.dev`, unless `phone-relay` names another
(`ws://127.0.0.1:8787` for `wrangler dev`). `phone-relay = off` turns the bridge off, and Settings › Phone
says how to turn it on again. A quiet test run connects only to a relay its config names, so scripted
runs never make rooms on the real relay. Changing it reconnects at once. Pair a phone in Settings › Phone;
the Mac's room id, its token and each phone's key live in the Keychain (service `Maxwell phone <bundle id>`,
so Maxwell Dev has its own room).
