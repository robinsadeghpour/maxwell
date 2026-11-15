#!/bin/bash
# packaging/homebrew/bump-cask.sh 0.1.28
# Points the Homebrew cask at a published release: `brew install --cask robinsadeghpour/maxwell/maxwell`.
# Run it after the GitHub release exists. It hashes the DMG people will download, rewrites version
# and sha256 in Casks/maxwell.rb of the tap, and pushes. Running it twice changes nothing.
#
# Who runs it: release.sh, right after a release made on a Mac. The tap's own "Follow Maxwell
# releases" workflow also runs it twice an hour with the latest release, so a release made anywhere
# else (GitHub Actions too) reaches Homebrew within 30 minutes with no extra secret.
# Needs push access to the tap through gh (gh auth setup-git in CI). DRY_RUN=1 pushes nothing.
set -euo pipefail
V=${1:?usage: packaging/homebrew/bump-cask.sh <version>}
TAP=robinsadeghpour/homebrew-maxwell
URL=https://github.com/robinsadeghpour/maxwell/releases/download/v$V/Maxwell-v$V.dmg
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL --retry 5 --retry-all-errors -o "$TMP/Maxwell.dmg" "$URL"
SHA=$(shasum -a 256 "$TMP/Maxwell.dmg" | cut -d' ' -f1)
gh repo clone "$TAP" "$TMP/tap" -- -q --depth 1
CASK=$TMP/tap/Casks/maxwell.rb
perl -pi -e "s/^  version \".*\"/  version \"$V\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
grep -q "^  version \"$V\"" "$CASK" && grep -q "^  sha256 \"$SHA\"" "$CASK" || { echo "Couldn't update $CASK."; exit 1; }

cd "$TMP/tap"
if git diff --quiet; then echo "The cask already installs $V."; exit 0; fi
git --no-pager diff
[[ -n ${DRY_RUN:-} ]] && exit 0
git config user.name >/dev/null || git config user.name "github-actions[bot]"
git config user.email >/dev/null || git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git commit -qam "Maxwell $V"
git push -q
echo "The cask now installs $V."
