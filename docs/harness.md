# Checking a change in the real app

Build **Maxwell Dev** with `./build.sh`. It has its own app ID and a "dev" badge, works on your real sessions and config, and never touches the Maxwell you work in.

Scripted runs pass flags to `build/Maxwell.app/Contents/MacOS/Maxwell`. Anything with `--quit-after N`, and Maxwell Dev started from a Claude session, is quiet: no Dock icon, no notifications, no focus, and its windows sit past the right edge of every screen, where they still draw and `--snap` still captures them. Start it by running the binary: `open` drops the session's environment, so the app can't tell and comes to the front. The repository's `.claude/settings.json` refuses `open … Maxwell` for that reason. A quiet run ignores being reopened, quits after 10 minutes when it has no `--quit-after`, and skips `--fullscreen` (full screen takes a Space on Robin's screen; ask before checking it). Keys and clicks are injected inside the app (`--keys "2:shift shift;3:esc"`, `--click "4:700,600;6:900,14"`), and `--snap` writes a screenshot. The flags are parsed in `Sources/App/main.swift` (`runTestHooks`) until step 3 of the [clean-up plan](cleanup-plan.md) moves them to `Sources/Harness/`. Don't add new ones there; the standard check refuses them.

For videos and screenshots that leave the Mac, use the invented world in `demo/` (`./build.sh && ./demo/record.sh && ./demo/cut.sh`). Never record real sessions: they show customer names.

## Traps

- `--select` takes the title shown in the list, the generated name or an id prefix, and logs `no such session` when none matches. It fires at 1.5 s, before `claude agents` is folded in. A session started from the CLI isn't known as background yet, so it never attaches and the pane says "Detached". Add `--reattach-after 3`.
- `--click x,y`: y counts from the bottom of the title bar, not the top of the window. Log a view's `convert(bounds, to: nil)` against `contentLayoutRect.height` to aim.
- `--keys` knows `backspace`: `--action panel-sessions@14 --keys "18:cmd+backspace"` is ⌘⌫ in the session list. Run it with `confirm-close = on`, so a cursor on the wrong session only opens the question.
- `--keys` only reaches the menu for lowercase letters (`cmd+shift+g`). Before Maxwell knows the state, a disabled shortcut falls through and types into the session's prompt.
- `--type-shell` types through the terminal itself, so it works even when the terminal lost the keyboard. Its log line says which: `typed in terminal (has keyboard focus)` or `(lost keyboard focus)`. To check that a plain terminal keeps the keyboard while sessions report: `--action new-terminal@3 --type-shell x --type-after 16`.
- ⇧⌘A is swallowed (probably by Select All on ⌘A). Don't bind it.
- A bare `ghostty_surface_key` without characters never reaches Claude. Send keys through `TerminalView.keyDown` with a real NSEvent.
- Test sessions: use `--model haiku`. To keep a test subagent busy (a hook blocks `sleep`, and long foreground commands get moved to the background), repeat `ping -c 90 -i 1 127.0.0.1` six times, about nine minutes.
- The demo's stand-in `demo/bin/claude` must learn every new `claude -p` use, or the demo shows wrong text.
- `--snap` leaves out the window's rim and shadow, so a corner that only goes wrong in the rim looks fine in it. To check the corners, capture the Maxwell Dev window by its process ID with `CGWindowListCreateImage` without `.boundsIgnoreFraming`, next to a plain window for comparison.
