#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
app_pid=""
dev_app_bundle="$PWD/.build/dev-app/MetalOS Dev.app"

source_fingerprint() {
    find Sources -type f -name '*.swift' -exec stat -f '%m:%N' {} \; | sort | shasum -a 256 | awk '{print $1}'
}

stop_preview() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    app_pid=""
}

cleanup() {
    stop_preview
}
trap cleanup EXIT INT TERM

build_and_launch() {
    echo "Building MetalOS preview…"
    swift build
    stop_preview
    mkdir -p "$dev_app_bundle/Contents/MacOS" "$dev_app_bundle/Contents/Resources"
    cp .build/debug/MetalOS "$dev_app_bundle/Contents/MacOS/MetalOS"
    ditto .build/debug/MetalOS_MetalOS.bundle "$dev_app_bundle/Contents/Resources/MetalOS_MetalOS.bundle"
    cat > "$dev_app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MetalOS Dev</string>
<key>CFBundleDisplayName</key><string>MetalOS Dev</string>
<key>CFBundleIdentifier</key><string>com.nxstudio.launcher.mac.dev</string>
<key>CFBundleExecutable</key><string>MetalOS</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    /usr/bin/codesign --force --sign - "$dev_app_bundle"
    "$dev_app_bundle/Contents/MacOS/MetalOS" &
    app_pid=$!
    echo "MetalOS Dev preview running (PID $app_pid). Watching Sources/**/*.swift for changes."
}

build_and_launch
last_fingerprint=$(source_fingerprint)

while true; do
    sleep 1
    current_fingerprint=$(source_fingerprint)
    if [[ "$current_fingerprint" != "$last_fingerprint" ]]; then
        # Let editors finish atomic saves before compiling.
        sleep 0.5
        last_fingerprint=$(source_fingerprint)
        build_and_launch
        last_fingerprint=$(source_fingerprint)
    fi
done
