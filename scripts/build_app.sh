#!/bin/bash
# Build AgentLimits and wrap the executable into a menu-bar-only .app bundle.
# Usage: scripts/build_app.sh [--run]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/AgentLimits.app"
CONTENTS="$APP/Contents"

echo "Building release binary..."
swift build -c release

BIN="$(swift build -c release --show-bin-path)/AgentLimits"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"
cp "$BIN" "$CONTENTS/MacOS/AgentLimits"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentLimits</string>
    <key>CFBundleDisplayName</key><string>Agent Limits</string>
    <key>CFBundleIdentifier</key><string>com.agentlimits.app</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>AgentLimits</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so the Keychain item and network access work without Gatekeeper griping.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    echo "Launching..."
    open "$APP"
fi
