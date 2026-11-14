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
auto-open = true              # open .md files a session writes or names
file-tree = false
app-icon = auto               # auto | light | dark | paper | graphite | light-eyes | dark-eyes
idle-after = 24h              # stopped sessions quiet this long fold into Idle (24h, 90m, 2d)
safe-after = 2h               # quiet this long before a session can be safe to close
judge = on                    # off: no model read, so nothing is ever safe to close
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

## Project logos

A project's logo is, in order: its `project-logo` line (Settings › Projects › Choose… writes it), then the
first image in the folders its sessions run in: an Xcode `AppIcon.appiconset`, then `apple-touch-icon*`,
then `icon.png`/`icon.svg`/`app-icon*`, then `logo*`, then `favicon*` (not `.ico`), shallower first, then
`.github/logo.svg`; with none, a two-letter monogram. Maxwell's own key is the app icon's demon.

## Keys

Settings › Keys lists every action. Click a shortcut, press the new keys; ⌫ clears it, Esc cancels.
It writes `keybind = <keys>=<action>` lines; `none` removes a default shortcut.
