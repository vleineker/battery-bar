#!/bin/bash
# Builds build/BatteryBar.app from source. Usage: ./build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/BatteryBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
swiftc -O "$ROOT/Sources/main.swift" -o "$APP/Contents/MacOS/BatteryBar"
codesign -s - "$APP"

echo "Built: $APP"
