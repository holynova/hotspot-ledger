#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/dist/热点账本.app/Contents/Info.plist")
mkdir -p "$ROOT/release"
codesign --verify --deep --strict "$ROOT/dist/热点账本.app"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/热点账本.app" "$ROOT/release/Hotspot-Ledger-$VERSION-arm64.zip"
(cd "$ROOT/release" && shasum -a 256 "Hotspot-Ledger-$VERSION-arm64.zip" > SHA256SUMS.txt)
