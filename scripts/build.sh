#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
mkdir -p "$BUILD"
SDK="$(xcrun --show-sdk-path)"
FLAGS=()
# This host has an older duplicate module map. Hide it only for this compilation.
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap && -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ]]; then
  python3 - "$BUILD" <<'PY'
import pathlib,json,sys
p=pathlib.Path(sys.argv[1]);(p/'empty.modulemap').write_text('// Build-local duplicate module workaround\n')
(p/'swift-overlay.json').write_text(json.dumps({'version':0,'roots':[{'type':'file','name':'/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap','external-contents':str(p/'empty.modulemap')}]}))
PY
  FLAGS+=(-vfsoverlay "$BUILD/swift-overlay.json")
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk ]]; then SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk; fi
fi
FLAGS+=(-sdk "$SDK" -target arm64-apple-macosx14.0)
if [[ "${1:-}" == provenance-test ]]; then
  swiftc "${FLAGS[@]}" "$ROOT/Sources/Core.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Sampler.swift" "$ROOT/Sources/Provenance.swift" "$ROOT/Tests/ProvenanceTests.swift" -o "$BUILD/provenance-tests"
  "$BUILD/provenance-tests"
  exit
fi
if [[ "${1:-}" == test ]]; then
  swiftc "${FLAGS[@]}" "$ROOT/Sources/Core.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Tests/CoreTests.swift" -o "$BUILD/core-tests"
  "$BUILD/core-tests"
  exit
fi
APP="$ROOT/dist/热点账本.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" -O "$ROOT/Sources/Core.swift" "$ROOT/Sources/Localization.swift" "$ROOT/Sources/Sampler.swift" "$ROOT/Sources/Provenance.swift" "$ROOT/Sources/Store.swift" "$ROOT/Sources/Model.swift" "$ROOT/Sources/WebDashboard.swift" "$ROOT/Sources/App.swift" -o "$APP/Contents/MacOS/HotspotLedger"
cp "$ROOT/Resources/dashboard.html" "$APP/Contents/Resources/dashboard.html"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>cc.xiaosang.hotspot-ledger</string>
<key>CFBundleName</key><string>热点账本</string>
<key>CFBundleDisplayName</key><string>热点账本</string>
<key>CFBundleExecutable</key><string>HotspotLedger</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocationUsageDescription</key><string>读取 Wi-Fi 名称以识别你标记的计费网络，不保存地理位置。</string>
<key>NSLocationWhenInUseUsageDescription</key><string>读取 Wi-Fi 名称以识别计费网络。</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "$APP"
