#!/bin/zsh
# ./build.sh                  Maxwell Dev, build/Maxwell.app (its own app ID: never touches the released app)
# ./build.sh release 0.1.7    the released Maxwell, build/release/Maxwell.app (use ./release.sh)
# ./build.sh test             reducer and logo tests
# ./build.sh ghostty          (re)builds GhosttyKit at the pinned commit
set -euo pipefail
cd "$(dirname "$0")"
GHOSTTY_COMMIT=8046a2360340ec9788e0089da5a9ed0378adf0ea
XCF=vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64
APP=build/Maxwell.app
BUNDLE_ID=dev.maxwell.app.dev NAME="Maxwell Dev" VERSION="0.0.0-dev.$(git rev-parse --short HEAD)"
if [[ ${1:-} == release ]]; then
  VERSION=${2:?usage: ./build.sh release <version>}
  APP=build/release/Maxwell.app BUNDLE_ID=dev.maxwell.app NAME=Maxwell
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

if [[ ${1:-} == ghostty ]]; then ghostty; exit; fi
if [[ ${1:-} == test ]]; then
  mkdir -p build
  swiftc -swift-version 5 -o build/reducer-tests Sources/Model/*.swift Sources/UI/{ProjectLogo,Theme,IconArt}.swift Tests/*.swift
  exec build/reducer-tests fixtures/events
fi

[[ -f $XCF/libghostty-internal.a ]] || ghostty
[[ $(git -C vendor/ghostty rev-parse HEAD) == $GHOSTTY_COMMIT ]] || { echo "vendor/ghostty is not at the pinned commit; run ./build.sh ghostty"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cc -O2 -Wall -o "$APP/Contents/MacOS/maxwell-hook" hook/maxwell-hook.c

swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -I "$XCF/Headers" \
  Sources/**/*.swift \
  "$XCF/libghostty-internal.a" \
  -lc++ \
  -framework AppKit -framework WebKit -framework PDFKit -framework Quartz -framework UserNotifications \
  -framework Metal -framework MetalKit -framework QuartzCore -framework CoreText \
  -framework CoreGraphics -framework IOSurface -framework Carbon -framework UniformTypeIdentifiers \
  -framework GameController \
  -o "$APP/Contents/MacOS/Maxwell"

cp -R Resources/web Resources/themes Resources/fonts "$APP/Contents/Resources/"
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
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT. Ghostty (MIT) and JetBrains Mono (OFL) notices in Resources.</string>
</dict></plist>
PLIST
cp vendor/ghostty/LICENSE "$APP/Contents/Resources/ghostty/LICENSE-ghostty" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null
echo "built $APP ($(du -sh "$APP" | cut -f1))"
