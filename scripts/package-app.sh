#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac
swift build -c "$CONFIGURATION" --disable-sandbox --scratch-path .build/verification
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path --disable-sandbox --scratch-path .build/verification)"
APP_DIR="$PWD/dist/MetalOS.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/MetalOS" "$APP_DIR/Contents/MacOS/MetalOS.new"
mv -f "$APP_DIR/Contents/MacOS/MetalOS.new" "$APP_DIR/Contents/MacOS/MetalOS"
cp "$BIN_DIR/NXProcessRunner" "$APP_DIR/Contents/MacOS/NXProcessRunner"
cp "$PWD/Resources/rockstar-games-logo.png" "$APP_DIR/Contents/Resources/rockstar-games-logo.png"
ditto "$BIN_DIR/MetalOS_MetalOS.bundle" "$APP_DIR/Contents/Resources/MetalOS_MetalOS.bundle"
swift scripts/render-icon.swift "$PWD/dist/MetalOS.iconset" "$APP_DIR/Contents/Resources/MetalOS.icns"
# Keep the original bundle identifier so macOS preferences and permissions survive the rename.
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MetalOS</string>
<key>CFBundleDisplayName</key><string>MetalOS</string>
<key>CFBundleIdentifier</key><string>com.nxstudio.launcher.mac</string>
<key>CFBundleIconFile</key><string>MetalOS</string>
<key>CFBundleExecutable</key><string>MetalOS</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP_DIR"
echo "Built $APP_DIR"
