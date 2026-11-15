#!/bin/zsh
# ./release.sh 0.1.13 "What changed, in plain words"
# Tests, builds the released Maxwell at this version, signs it with your Developer ID, has Apple
# notarize the app and the DMG, pushes v1 and main, and publishes the GitHub release.
# Installed copies offer it as "Restart to update"; this never installs or restarts anything here.
#
# GitHub Actions runs this same script (.github/workflows/release.yml): that is the usual way to
# release. Run it here only when CI can't (README › Develop › Releasing).
#
# Needs, once per Mac:
#   - a "Developer ID Application" certificate in the login keychain (Xcode › Settings › Accounts ›
#     Manage Certificates › + › Developer ID Application; only the team's Account Holder can make one)
#   - an asc profile with an App Store Connect API key of the same team: `asc auth login …`
#   - .release.env (gitignored) with MAXWELL_ASC_PROFILE=<that profile>; optional MAXWELL_SIGN_ID
#     to pick a certificate when there are several
#   - uv, for the DMG (brew install uv)
# In CI, MAXWELL_NOTARY_KEY (a .p8 path), MAXWELL_NOTARY_KEY_ID and MAXWELL_NOTARY_ISSUER stand in
# for the asc profile and notarize with xcrun notarytool.
set -euo pipefail
cd "$(dirname "$0")"
V=${1:?usage: ./release.sh <version> "<notes>"}
NOTES=${2:?release notes, in plain words}
[[ -f .release.env ]] && source .release.env
if [[ -n ${MAXWELL_NOTARY_KEY:-} ]]; then
  NOTARY=(--key "$MAXWELL_NOTARY_KEY" --key-id "${MAXWELL_NOTARY_KEY_ID:?}" --issuer "${MAXWELL_NOTARY_ISSUER:?}")
else
  PROFILE=${MAXWELL_ASC_PROFILE:?Set MAXWELL_ASC_PROFILE in .release.env to the asc profile used for notarization.}
fi
ID=${MAXWELL_SIGN_ID:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)}
[[ -n $ID ]] || { echo "No Developer ID Application certificate in the keychain (see the top of release.sh)."; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash first."; exit 1; }
[[ $(git rev-parse --abbrev-ref HEAD) == v1 ]] || { echo "Release from v1."; exit 1; }
# Another release may have taken this version already. CI runs one release at a time, so checking
# here is enough there; `gh release create` would refuse a taken tag anyway, but only after the build.
git fetch -q origin v1
git merge-base --is-ancestor origin/v1 HEAD || { echo "origin's v1 has commits this v1 doesn't: pull first."; exit 1; }
if git ls-remote --exit-code --tags origin "refs/tags/v$V" >/dev/null; then echo "v$V is already released: pick the next version."; exit 1; fi
# The website changelog names every release. Its pages are committed, so they must be built already.
node site/src/build.mjs --check "$V"
node site/src/build.mjs >/dev/null
[[ -z $(git status --porcelain) ]] || { echo "The site pages were stale: run node site/src/build.mjs, commit, and release again."; git checkout -q -- site; exit 1; }

OUT=build/release APP=build/release/Maxwell.app
ZIP=$OUT/Maxwell-v$V.zip DMG=$OUT/Maxwell-v$V.dmg

# Apple's notary service; stops the release with Apple's log when it says no.
notarize() {
  local file=$1 out sid
  echo "notarizing $file (usually a few minutes)"
  if [[ -n ${MAXWELL_NOTARY_KEY:-} ]]; then
    out=$(xcrun notarytool submit "$file" "${NOTARY[@]}" --wait --timeout 1h --output-format json) || true
  else
    out=$(asc --profile "$PROFILE" notarization submit --file "$file" --wait --timeout 1h --output json) || true
  fi
  if ! grep -q '"Accepted"' <<<"$out"; then
    echo "$out"
    sid=$(grep -oE '"id" *: *"[^"]+"' <<<"$out" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    if [[ -n $sid && -n ${MAXWELL_NOTARY_KEY:-} ]]; then xcrun notarytool log "$sid" "${NOTARY[@]}" || true
    elif [[ -n $sid ]]; then asc --profile "$PROFILE" notarization log --id "$sid" || true; fi
    echo "Notarization failed for $file."; exit 1
  fi
}

./build.sh test
./build.sh release "$V"

# Sign inside out: the hook helper, then the app. Hardened runtime and a secure timestamp are
# what notarization requires; Maxwell needs no extra entitlements.
# Every executable in the bundle needs this, plugins included, so find them instead of listing them.
find "$APP/Contents" -type f -perm +111 ! -path "$APP/Contents/MacOS/Maxwell" -print0 |
  while IFS= read -r -d '' bin; do
    file -b "$bin" | grep -q Mach-O && codesign --force --timestamp --options runtime --sign "$ID" "$bin"
  done
codesign --force --timestamp --options runtime --sign "$ID" "$APP"
codesign --verify --strict --deep "$APP"

# Notarize the app and staple the ticket to it, so it opens offline too.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
# The zip the in-app updater fetches, rebuilt around the stapled app.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# The DMG is what people download (drag to Applications). Signed and notarized on its own, so
# macOS opens it without a warning. Maxwell.dmg is the same file under a fixed name, so
# releases/latest/download/Maxwell.dmg always works.
rm -f "$DMG"
uvx dmgbuild -s packaging/dmg/settings.py -D app="$APP" Maxwell "$DMG"
codesign --force --timestamp --sign "$ID" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v "$APP"
cp "$DMG" "$OUT/Maxwell.dmg"

git push -q --atomic origin v1 v1:main
gh release create "v$V" "$DMG" "$OUT/Maxwell.dmg" "$ZIP" --target main --title "v$V" --notes "$NOTES"
