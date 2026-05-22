#!/bin/bash
# Build AwakeBar and assemble it into a double-clickable .app bundle.
# Quit any running AwakeBar before rebuilding.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="AwakeBar.app"
BIN=".build/release/AwakeBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AwakeBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AwakeBar</string>
    <key>CFBundleDisplayName</key><string>AwakeBar</string>
    <key>CFBundleIdentifier</key><string>io.jp7.awakebar</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>AwakeBar</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a code-signing identity discovered from the local keychain, so
# rebuilds keep a stable signature (login-item registration and granted
# permissions survive). Nothing personal is hardcoded; falls back to ad-hoc
# when no identity is installed.
SIGN_ID=$(security find-identity -v -p codesigning \
    | grep -m1 -E 'Apple Development|Developer ID Application' \
    | grep -o '[0-9A-F]\{40\}' || true)
if [ -n "$SIGN_ID" ]; then
    codesign --force --options runtime --sign "$SIGN_ID" "$APP"
    echo "Built ./$APP (signed with a local identity)"
else
    codesign --force --sign - "$APP"
    echo "Built ./$APP (ad-hoc — no signing identity found)"
fi

# Refresh the LaunchServices registration so Finder / `open` pick up the
# freshly rebuilt bundle instead of a stale cached copy (which can make the
# first launch after a rebuild quit immediately).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$PWD/$APP"

# If a copy is already installed in /Applications, keep it in sync so that a
# rebuild updates the version you actually run.
INSTALLED="/Applications/$APP"
if [ -d "$INSTALLED" ]; then
    pkill -f "$INSTALLED/Contents/MacOS" 2>/dev/null && sleep 1
    rm -rf "$INSTALLED"
    cp -R "$APP" "$INSTALLED"
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$INSTALLED"
    open "$INSTALLED"
    echo "Synced and relaunched $INSTALLED"
fi
