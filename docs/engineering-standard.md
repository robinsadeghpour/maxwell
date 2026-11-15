# Engineering standard

How Maxwell's code is organised, sized, named and typed. It applies to every change, by a person or by Claude.

Rules marked **checked** are enforced by `python3 scripts/check-standard.py`, which runs first in `./build.sh test`, so it runs before every merge you verify and in every release. It is a ratchet: code that already breaks a rule may stay as it is, but a new violation, or an existing one getting worse, fails. The recorded state is `scripts/standard-baseline.json`, and its numbers only go down.

The measurements behind this page, and the order the existing exceptions get fixed in, are in [cleanup-plan.md](cleanup-plan.md).

## Who this is for

The next reader of any file is a Claude session that knows nothing about Maxwell. It finds things by searching. It copies the file next to the one it is changing. It only knows the states and components it can see. Judge every change by that reader:

- Would it find this by searching for the product's word for it?
- Is there exactly one place this could live?
- Is the nearest example the one it should copy?
- Could it get this wrong without a check or the compiler saying so?

To stop a mistake, prefer in this order: a check that fails, a type, one obvious place, a good example nearby. A written rule comes last, because every session pays to read it.

## Organisation

1. **Code is grouped by area.** `Sources/Model`, `App`, `UI`, `Install` and `Plugins` are described in the README's folder table. Two areas are being created by the clean-up: `Sources/ClaudeCode/` (everything Maxwell assumes about Claude Code) and `Sources/Harness/` (test flags and scripted runs). A new area gets its own folder; it never goes into the biggest neighbouring file.
2. **Each layer keeps its job.**
   - `Model` holds data, parsing, the reducer and verdicts. It never imports AppKit. **Checked.**
   - `App` does the effects (files, processes, network, timers) and wires them to the window.
   - `UI` draws state and sends actions. Views don't read files, run commands or call the network. **Checked** (ratchet: 13 existing calls, listed in the plan).
   - Session state changes only through `reduce(State, Event)`. A view or probe that sets a session's state directly is a bug, even when it looks right.
3. **A file has one job.** If its name needs "and", it is two files. **Checked:** no new file over 500 lines, and a file already over may grow by at most 10%.

## Functions

4. **A function does one thing and fits on a screen.** **Checked:** no new function over 80 lines, none nested deeper than 5 levels. Return early instead of nesting.
5. **Decisions are pure; effects happen at the edge.** `Reducer.swift`, `Verdict.swift` and `Live.swift` are the model to copy: data in, decision out, tested against recorded events. A long function becomes steps that return data, with the side effects left in one short function at the end.

## Names

6. **A name says what the thing is in Maxwell's words:** session, account, project, turn, Needs you, Your turn, Working, Safe to close, background session, terminal session. Not `data`, `info`, `handle`, `manager` or `helper`. No abbreviation a new reader would have to look up. A file is named for the main type it holds.

## One way to do each thing

7. **Claude Code is reached through one adapter.** Its file layout (`sessions/<pid>.json`, `jobs/<id>/state.json`, transcripts), its commands (`claude --bg`, `attach`, `agents --json`, `stop`) and its printed output are read in `Sources/ClaudeCode/` only. Until that folder exists, they live in `ClaudeCLI.swift` and `Probes.swift`. **Checked.** Each assumption is written down in [claude-code-internals.md](claude-code-internals.md) with the Claude Code version it was seen in. When an assumption stops holding, Maxwell says so in the UI and the log. It never guesses.
8. **Processes start through `ClaudeCLI.run`**, which handles timeouts, the clean environment and reading both pipes without deadlocking. **Checked.**
9. **Controls come from `Sources/UI/Components.swift`** (`MXButton`, `IconButton`, `Label`, `Text`, `Glyph`, `CheckLine`). **Checked:** no new hand-made `NSButton`, `NSTextField`, `NSPopUpButton`, `NSSegmentedControl`, `NSSwitch` or `NSSlider` outside it. A missing control is added there, once.
10. **Settings the user picks live in `Config`** (and `docs/config.md`). What Maxwell remembers between launches (window frames, the last project, panel sizes) goes through one file, `Sources/UI/Remembered.swift`, with typed keys. **Checked:** no new `UserDefaults.standard` elsewhere.
11. **Nothing crashes on a surprise.** **Checked:** no `try!` or `as!`. `try?` is right only for "parse it, otherwise nothing". Wherever a real call can fail (a process, a file Maxwell needs, the network), log what kind of failure it was, and show it if the user would otherwise see something wrong.
12. **Wait for the event, not for a number of seconds.** **Checked:** no new `asyncAfter` outside `Motion.swift` and the harness. Waiting for seconds is how a check passes on one Mac and fails on a slower one. Watch the file, the process exit or the state change instead. Debounces go through one helper.
13. **Test flags live in `Sources/Harness/`, not in the app.** **Checked:** no new `CommandLine.arguments` or `arg("--…")` outside it (and `CLI.swift`, the `maxwell` command). A scripted run waits for states ("session X is Your turn"), not for seconds.

## Types

14. **A status is one case of an enum, never a `String`.** A value that can take several shapes is an enum with associated values, not a struct of optionals. When Claude Code adds a value Maxwell doesn't know, it is parsed into an explicit `unknown(String)` case and shown as unknown, not mapped to the nearest known one.
15. **Ids that mean different things have different types** when you touch them: a session id, a background short id and a pid are not interchangeable.

## Tests

16. **A fix comes with what would have caught it.** A state bug gets a recorded event fixture in `fixtures/events`. A Claude Code parsing bug gets the real file or output in `fixtures/`, with the version it came from. A UI bug gets a harness step. "I checked it by hand" stops this bug once; a fixture stops it for good.
17. **Before merging:** `./build.sh test`, then check the change in Maxwell Dev (see [harness.md](harness.md)). Before a release, run the smoke test once it exists (step 3 of the plan).

## Comments

18. **A comment says why, never what.** If a comment explains what the next lines do, give those lines a name instead. Doc comments on types and properties that say what they mean to the user are good; Maxwell has many and they help.
19. **No ticket, PR or version numbers in code comments.** Git history and `docs/decisions.tsv` carry that.

## When you touch code that breaks these rules

Leave it better than you found it, in the same change, as far as the change's risk allows. Never make it worse. If you shrink an exception, run `python3 scripts/check-standard.py --update` so the lower number is locked in.

When the check fails on something deliberate, run it with `--update`. The baseline's rise then shows in the diff, so say why in the pull request description.

## What review looks for

The script checks sizes and counts. Review, including a session reviewing its own diff before merging, reads for what a script can't see. Each point is a way the next session would be misled:

- **A second one of something that exists.** A new component, parser, process runner, status, empty state or error state when Maxwell already has one for that job. Search before adding one, and name the existing one.
- **A new place for an old kind of thing.** A file that doesn't sit with its neighbours of the same kind, or a new pattern beside an existing one for the same job.
- **A name that needs the diff to be understood.**
- **A state the types don't know.** A status as `String`, a case added in one place and not in the enum, a screen or row without its loading, empty, unknown and failed states.
- **The wrong layer.** A view reading a file, a probe setting session state, Claude Code's output parsed outside the adapter.
- **A timing guess.** A delay standing in for an event.
- **A rise in the baseline** that the description doesn't explain.
