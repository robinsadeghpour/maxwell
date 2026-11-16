# Releasing

Robin doesn't review PRs, test or release by hand. Get confident yourself (`./build.sh test`, a check in Maxwell Dev), wait for CI on your pull request, merge it into `v1`, then release. Don't leave a PR waiting.

`v1` is where work lands, only through pull requests whose CI (`test-and-build`) passed; direct pushes and force pushes are refused, for admins too. `main` is the last released commit; the release workflow moves it, and pushing it deploys runmaxwell.com (Vercel).

## Steps

1. Before picking a version, check `gh release list -R robinsadeghpour/maxwell`, `gh run list -R robinsadeghpour/maxwell -w release.yml` and the changelog. Several sessions release in parallel; an already-tagged version is refused.
2. Add the changelog entry in `site/src/changelog.mjs`: Maxwell is the subject, present tense; fixes start "Fixed …" or "X now Y", no trailing period; invented data only. Update any docs page the change touches, and `site/index.html` when behaviour it shows changes. Run `node site/src/build.mjs` and commit with your change.
3. `gh workflow run release.yml -R robinsadeghpour/maxwell --ref v1 -f version=<v> -f notes="..."`, then `gh run watch`. It runs `release.sh` on the Xcode 27 runner: tests, build, Developer ID signing, notarization and stapling of the app and DMG, moves `main` to the built commit, publishes the release, and checks it the way the updater gets it. `dry_run=true` only tests and builds.
4. A newer dispatch cancels your pending one (one pending run per concurrency group). Check `gh run list` before and after. If another release already shipped your commits, fold your changelog entry into that version's entry; don't leave a version that was never published.
5. When the UI changed visibly, re-record the demo on invented data (`./build.sh && ./demo/record.sh && ./demo/cut.sh`, needs an unlocked screen) and replace `site/assets/demo.mp4`.
6. Say what shipped and its version in one line.

## Signing

GhosttyKit is cached in Actions by its pin; zig only runs (~7 min) when `GHOSTTY_COMMIT` in `build.sh` changes. The Developer ID certificate and notary key are secrets of the `release` environment, usable only from `v1` and `main`. If the certificate is replaced, Robin runs `packaging/ci/set-release-secrets.sh cert` once. Never go back to unsigned DMGs (Gatekeeper blocks them for every new user) or ad-hoc signing (every update would ask for the Keychain again). Only the Account Holder can create a new Developer ID certificate.

Crash reports go to the Sentry project `maxwell` (org `bunlo`, EU region). `release.sh` uploads each release's debug symbols with `SENTRY_AUTH_TOKEN`, an org token with the `org:ci` scope, kept as a secret of the `release` environment. Without it the release still ships, but its crash reports show addresses instead of function names.

**If CI is down:** `./release.sh <v> "<notes>"` from an up-to-date `v1` in `~/projects/maxwell-oss` (release from a commit that is already on `v1`; `release.sh` can't push `v1` past its protection), which has `vendor` and `.release.env` (`MAXWELL_ASC_PROFILE`). The login keychain holds the certificate.
