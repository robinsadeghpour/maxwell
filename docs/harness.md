# Checking a change in the real app

Build **Maxwell Dev** with `./build.sh`. It has its own app ID and a "dev" badge, works on your real sessions and config, and never touches the Maxwell you work in.

Scripted runs pass flags to `build/Maxwell.app/Contents/MacOS/Maxwell`. Anything with `--quit-after N` is quiet: no Dock icon, the window stays behind yours and never takes focus. Keys and clicks are injected inside the app (`--keys "2:shift shift;3:esc"`, `--click "4:700,600"`), and `--snap` writes a screenshot. The flags are parsed in `Sources/App/main.swift` (`runTestHooks`) until step 3 of the [clean-up plan](cleanup-plan.md) moves them to `Sources/Harness/`. Don't add new ones there; the standard check refuses them.

For videos and screenshots that leave the Mac, use the invented world in `demo/` (`./build.sh && ./demo/record.sh && ./demo/cut.sh`). Never record real sessions: they show customer names.

## Traps

- `--select` fires at 1.5 s, before `claude agents` is folded in. A session started from the CLI isn't known as background yet, so it never attaches and the pane says "Detached". Add `--reattach-after 3`.
- `--click x,y`: y counts from the bottom of the title bar, not the top of the window. Log a view's `convert(bounds, to: nil)` against `contentLayoutRect.height` to aim.
- `--keys` only reaches the menu for lowercase letters (`cmd+shift+g`). Before Maxwell knows the state, a disabled shortcut falls through and types into the session's prompt.
- ⇧⌘A is swallowed (probably by Select All on ⌘A). Don't bind it.
- A bare `ghostty_surface_key` without characters never reaches Claude. Send keys through `TerminalView.keyDown` with a real NSEvent.
- Test sessions: use `--model haiku`. To keep a test subagent busy (a hook blocks `sleep`, and long foreground commands get moved to the background), repeat `ping -c 90 -i 1 127.0.0.1` six times, about nine minutes.
- The demo's stand-in `demo/bin/claude` must learn every new `claude -p` use, or the demo shows wrong text.
