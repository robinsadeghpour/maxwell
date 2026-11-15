# Contributing to Maxwell

Thanks for helping. Maxwell is built mostly by Claude Code sessions, so the docs below are written for a reader who knows nothing about the code yet. They work just as well for people.

## Set up

You need macOS, Xcode 27 with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) and Zig 0.17 (`brew install zig`).

```sh
./build.sh          # builds Maxwell Dev; the first run also builds Ghostty (~3 min)
./build.sh test     # the engineering standard check, then the tests
```

Maxwell Dev has its own app ID, so it never touches an installed Maxwell.

## Make a change

1. Read [docs/engineering-standard.md](docs/engineering-standard.md). `./build.sh test` enforces the measurable parts; a new file over 500 lines, a function over 80, or a new `try!` fails it.
2. Search before adding. Maxwell probably has the component, parser or state already.
3. A bug fix comes with the fixture, test or harness step that would have caught it ([docs/harness.md](docs/harness.md)).
4. Use invented data only. Fixtures, screenshots and recordings come from the demo world in `demo/`, never from real sessions.
5. Open a pull request against `v1`. CI runs the check, the tests and a full build.

Maxwell reads Claude Code's own files and output, which aren't documented and change often. If your change relies on one, add it to [docs/claude-code-internals.md](docs/claude-code-internals.md) with the Claude Code version you saw it in.

## Security

Please don't open public issues for security problems. See [SECURITY.md](SECURITY.md).
