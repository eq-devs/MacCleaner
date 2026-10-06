#!/bin/bash
# Builds Mac Cleaner.app into ~/Applications (find it in Spotlight or Launchpad).
# Pass a folder to build there instead: ./build.sh dist
set -e
cd "$(dirname "$0")"

APP="${1:-$HOME/Applications}/Mac Cleaner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -parse-as-library -target arm64-apple-macos14 Scanner.swift App.swift -o "$APP/Contents/MacOS/MacCleaner"
codesign --force -s - "$APP"
echo "Built: $APP"
