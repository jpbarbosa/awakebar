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
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Bundle the app icon (shown in Finder / Applications; the app is accessory, so
# it has no Dock icon). icon/AppIcon.icns is prebuilt by icon/build-iconset.sh —
# re-run that to regenerate after editing the artwork.
mkdir -p "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle the notification "buzz" sound. The app plays it with AVAudioPlayer (not
# UNNotificationSound, which has no volume API), so the menu's Notification Volume
# Low/Mid/High can scale playback of this one file.
cp sound/buzz.aiff "$APP/Contents/Resources/buzz.aiff"

# Sign with a code-signing identity discovered from the local keychain, so
# rebuilds keep a stable signature (login-item registration and granted
# permissions survive). Nothing personal is hardcoded; falls back to ad-hoc
# when no identity is installed.
#
# This signature is load-bearing for the Plan Usage feature: macOS pins the
# "Always Allow" grant on the Claude Code-credentials keychain item to the app's
# designated requirement, so a signature that drifts between builds is exactly
# what makes that password prompt come back. Two drift sources are closed here:
#   * Identity is chosen deterministically (Developer ID first, then Apple
#     Development) instead of relying on `find-identity` output order, so a
#     machine with more than one identity can't flip between builds.
#   * The ad-hoc fallback — whose signature changes every build and therefore
#     cannot hold a grant — now warns loudly instead of failing silently.
IDENTITIES=$(security find-identity -v -p codesigning || true)
SIGN_ID=$(printf '%s\n' "$IDENTITIES" | grep -m1 'Developer ID Application' | grep -o '[0-9A-F]\{40\}' || true)
[ -n "$SIGN_ID" ] || SIGN_ID=$(printf '%s\n' "$IDENTITIES" | grep -m1 'Apple Development' | grep -o '[0-9A-F]\{40\}' || true)
if [ -n "$SIGN_ID" ]; then
    codesign --force --options runtime --sign "$SIGN_ID" "$APP"
    echo "Built ./$APP (signed with a stable local identity)"
else
    codesign --force --sign - "$APP"
    cat >&2 <<'WARN'
WARNING: built ad-hoc — no Developer ID / Apple Development identity found.
         An ad-hoc signature changes on every build, so the macOS "Always Allow"
         grant for Plan Usage (the Claude Code-credentials keychain item) will
         NOT persist — the password prompt returns after each rebuild. Install a
         free Apple Development certificate (Xcode ▸ Settings ▸ Accounts) and
         rebuild to make the grant stick.
WARN
fi

# Echo the designated requirement we just signed against — this is precisely
# what the keychain ACL pins "Always Allow" to. Stable across builds ⇒ the Plan
# Usage prompt appears once and never again.
codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => /  designated requirement → /p' || true

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
