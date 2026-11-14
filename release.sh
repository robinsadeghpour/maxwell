#!/bin/zsh
# ./release.sh 0.1.7 "What changed, in plain words"
# Tests, builds the released Maxwell at this version, pushes v1 and main, and publishes the
# GitHub release. Installed copies offer it as "Restart to update"; this never installs or
# restarts anything on this Mac.
set -euo pipefail
cd "$(dirname "$0")"
V=${1:?usage: ./release.sh <version> "<notes>"}
NOTES=${2:?release notes, in plain words}
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash first."; exit 1; }
[[ $(git rev-parse --abbrev-ref HEAD) == v1 ]] || { echo "Release from v1."; exit 1; }
./build.sh test
./build.sh release "$V"
ZIP=build/release/Maxwell-v$V.zip
rm -f "$ZIP"
ditto -c -k --keepParent build/release/Maxwell.app "$ZIP"
git push -q origin v1 v1:main
gh release create "v$V" "$ZIP" --target main --title "v$V" --notes "$NOTES"
