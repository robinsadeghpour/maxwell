# Maxwell

A native macOS app (Swift, AppKit, libghostty) that shows every Claude Code session: which need you, which are working, which are safe to close. How it works and the folder map are in the README ("How it works", "Develop").

This repository is the only home of Maxwell's code. A separate private repository (`maxwell-private`) holds launch material and user research only. Never copy code from it, and never copy anything from it into this one.

## Before you change code

- Work in your own worktree of this repository, branched from `origin/v1`. On Robin's Mac the clone is `~/projects/maxwell-oss`: `git -C ~/projects/maxwell-oss worktree add <path> -b mx/<name> origin/v1`, then symlink `vendor` from `~/projects/maxwell-oss/vendor` so Ghostty isn't rebuilt. Other sessions are changing Maxwell at the same time.
- Read [docs/engineering-standard.md](docs/engineering-standard.md). `./build.sh test` runs its check first: a new file over 500 lines, a function over 80, Claude Code read outside its adapter, a new timer wait, test flag, `try!` or hand-made control all fail. Don't make an existing exception worse; leave what you touch smaller.
- Search before adding: Maxwell probably has the component, parser, runner or state already.
- The clean-up in progress is [docs/cleanup-plan.md](docs/cleanup-plan.md). If your change touches one of its steps, do it the way the plan says.

## This repository is public

Everything you commit, push or put in a branch name, PR or issue is public, including branches that are never merged.

- Never commit real data: no real session names, transcripts, prompts, customer or project names, people's names, screenshots or recordings of real sessions. Fixtures and screenshots come from the invented world in `demo/`.
- Never commit secrets. Signing and notary keys live in the `release` environment's secrets.
- Never merge a pull request you didn't write in this session. Outside contributions get a security review first (anything that runs code, touches the updater, signing, hooks or the release workflow) and are flagged to Robin.

## Checking your change

- `./build.sh test`: the standard check, then reducer, plugin and logo tests from recorded events. CI runs the same and a full build on every pull request.
- `./build.sh` builds **Maxwell Dev** (own app ID, never touches the released app). Check the change in it, scripted: [docs/harness.md](docs/harness.md) has the flags and their traps.
- A bug fix comes with the fixture, test or harness step that would have caught it.

## Claude Code

Maxwell depends on Claude Code's undocumented files and output. [docs/claude-code-internals.md](docs/claude-code-internals.md) lists every assumption with the version it was seen in. Add yours there.

## Shipping

Robin doesn't review PRs, test or release by hand. Get confident, wait for CI, merge your own PR into `v1`, and release: [docs/releasing.md](docs/releasing.md). Record decisions in `docs/decisions.tsv`.
