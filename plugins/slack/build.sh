#!/bin/zsh
# ./build.sh        builds the plugin folder into build/slack (plugin.json, icon.svg, maxwell-slack, fixtures.json)
# ./build.sh test   rules, marks, panel and the read-only client, against anonymised fixtures
set -euo pipefail
cd "$(dirname "$0")"
OUT=build/slack
mkdir -p $OUT
if [[ ${1:-} == test ]]; then
  swiftc -swift-version 5 -o build/slack-tests $(ls Sources/*.swift | grep -v main.swift) ../sdk/MaxwellPlugin.swift Tests/*.swift
  exec build/slack-tests Tests/fixtures
fi
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o $OUT/maxwell-slack Sources/*.swift ../sdk/MaxwellPlugin.swift
cp plugin.json icon.svg $OUT/
cp demo.json $OUT/fixtures.json
echo "$PWD/$OUT"
