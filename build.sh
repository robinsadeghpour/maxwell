#!/bin/zsh
# ./build.sh                  Maxwell Dev, build/Maxwell.app (its own app ID: never touches the released app)
# ./build.sh release 0.1.7    the released Maxwell, build/release/Maxwell.app (use ./release.sh)
# ./build.sh test             engineering standard check, then reducer, logo and plugin tests
# ./build.sh ghostty          (re)builds GhosttyKit at the pinned commit
set -euo pipefail
cd "$(dirname "$0")"
GHOSTTY_COMMIT=8046a2360340ec9788e0089da5a9ed0378adf0ea
XCF=vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64
SENTRY_VERSION=9.34.0
SENTRY_SHA256=1ee80dfb1bd94295f419a7a026467ce35a68143fb8da9f5e672264546b8f7c0d
SENTRY=vendor/sentry-$SENTRY_VERSION/Sentry.xcframework/macos-arm64_arm64e_x86_64
APP=build/Maxwell.app DEBUG_INFO=()
BUNDLE_ID=dev.maxwell.app.dev NAME="Maxwell Dev" VERSION="0.0.0-dev.$(git rev-parse --short HEAD)"
if [[ ${1:-} == release ]]; then
  VERSION=${2:?usage: ./build.sh release <version>}
  APP=build/release/Maxwell.app BUNDLE_ID=dev.maxwell.app NAME=Maxwell
  DEBUG_INFO=(-g)   # build/release/Maxwell.dSYM, which release.sh uploads so crash reports have symbols
fi

ghostty() {
  if [[ ! -d vendor/ghostty/.git ]]; then
    git clone https://github.com/ghostty-org/ghostty vendor/ghostty
  fi
  git -C vendor/ghostty fetch --depth 1 origin $GHOSTTY_COMMIT 2>/dev/null || true
  git -C vendor/ghostty checkout -q $GHOSTTY_COMMIT
  (cd vendor/ghostty && zig build -Dsentry=false -Di18n=false -Demit-macos-app=false \
    -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast)
}

# Sentry's static framework (crash reports), at a pinned version and checksum.
sentry() {
  local zip=vendor/sentry-$SENTRY_VERSION.zip
  curl -fsSL -o $zip https://github.com/getsentry/sentry-cocoa/releases/download/$SENTRY_VERSION/Sentry.xcframework.zip
  echo "$SENTRY_SHA256  $zip" | shasum -a 256 -c - >/dev/null || { echo "Sentry.xcframework.zip checksum mismatch"; rm -f $zip; exit 1; }
  rm -rf vendor/sentry-$SENTRY_VERSION && mkdir -p vendor/sentry-$SENTRY_VERSION && unzip -q $zip -d vendor/sentry-$SENTRY_VERSION && rm $zip
}

if [[ ${1:-} == ghostty ]]; then ghostty; exit; fi
if [[ ${1:-} == test ]]; then
  python3 -I scripts/check-standard.py
  mkdir -p build
  plugins/slack/build.sh test
  swiftc -swift-version 5 -o build/linear-plugin plugins/sdk/MaxwellPlugin.swift plugins/linear/*.swift
  swiftc -swift-version 5 -o build/reducer-tests Sources/Model/*.swift Sources/Plugins/*.swift Sources/UI/{ProjectLogo,Theme,IconArt,PanelLayout}.swift Sources/App/TerminalHosts.swift Sources/Install/*.swift \
    plugins/linear/{LinearCore,LinearAPI}.swift Tests/*.swift
  exec build/reducer-tests fixtures/events
fi

[[ -f $XCF/libghostty-internal.a ]] || ghostty
[[ -d $SENTRY/Sentry.framework ]] || sentry
[[ $(git -C vendor/ghostty rev-parse HEAD) == $GHOSTTY_COMMIT ]] || { echo "vendor/ghostty is not at the pinned commit; run ./build.sh ghostty"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cc -O2 -Wall -o "$APP/Contents/MacOS/maxwell-hook" hook/maxwell-hook.c

swiftc -O -swift-version 5 "${DEBUG_INFO[@]}" \
  -target arm64-apple-macos14.0 \
  -I "$XCF/Headers" -F "$SENTRY" \
  Sources/**/*.swift \
  "$XCF/libghostty-internal.a" \
  -lc++ -lz -framework Sentry \
  -framework AppKit -framework WebKit -framework PDFKit -framework Quartz -framework UserNotifications \
  -framework Metal -framework MetalKit -framework QuartzCore -framework CoreText \
  -framework CoreGraphics -framework IOSurface -framework Carbon -framework UniformTypeIdentifiers \
  -framework GameController \
  -o "$APP/Contents/MacOS/Maxwell"
if [[ -d "$APP/Contents/MacOS/Maxwell.dSYM" ]]; then
  rm -rf "${APP:h}/Maxwell.dSYM" && mv "$APP/Contents/MacOS/Maxwell.dSYM" "${APP:h}/Maxwell.dSYM"
fi

cp -R Resources/web Resources/themes Resources/fonts "$APP/Contents/Resources/"
# Plugins that ship with Maxwell: each is a folder with plugin.json and its program.
mkdir -p "$APP/Contents/Resources/plugins/linear"
cp plugins/linear/plugin.json "$APP/Contents/Resources/plugins/linear/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$APP/Contents/Resources/plugins/linear/linear" plugins/sdk/MaxwellPlugin.swift plugins/linear/*.swift
cp -R "$(plugins/slack/build.sh)" "$APP/Contents/Resources/plugins/slack"
# Ghostty finds its shell integration + terminfo next to the binary (Contents/Resources/{ghostty,terminfo}).
cp -R vendor/ghostty/zig-out/share/ghostty "$APP/Contents/Resources/ghostty"
cp -R vendor/ghostty/zig-out/share/terminfo "$APP/Contents/Resources/terminfo"

ICONSET=build/AppIcon.iconset
rm -rf $ICONSET
"$APP/Contents/MacOS/Maxwell" render-iconset dark $ICONSET
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>Maxwell</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>None</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string></array>
  </dict></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Voice mode hears your spoken reply to a session. What you say is turned into text on this Mac. Programs you run in Maxwell's terminals may ask for the microphone too.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Voice mode turns your spoken reply into text on this Mac, to type it into the session that asked.</string>
  <key>NSHumanReadableCopyright</key><string>MIT. Ghostty (MIT) and JetBrains Mono (OFL) notices in Resources.</string>
</dict></plist>
PLIST
cp vendor/ghostty/LICENSE "$APP/Contents/Resources/ghostty/LICENSE-ghostty" 2>/dev/null || true
# Sign with a certificate when this Mac has one, so macOS sees every build as the same app and
# Keychain access allowed once stays allowed. Ad-hoc signing ties the app to its binary's hash,
# which changes with every build and update. MAXWELL_SIGN_ID picks the identity; "-" is ad-hoc.
SIGN_ID=${MAXWELL_SIGN_ID:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
codesign --force --sign "${SIGN_ID:--}" "$APP" >/dev/null
echo "built $APP ($(du -sh "$APP" | cut -f1))"
