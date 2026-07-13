#!/bin/bash
#
# Build RunnerMenu and assemble a signed .app bundle.
# Usage: ./build-app.sh [debug|release]   (default: release)
# Set RUNNERMENU_SIGN_IDENTITY to a Developer ID Application identity for a
# production-signable bundle. The default '-' performs ad-hoc development signing.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-release}"
APP_NAME="RunnerMenu"
BUNDLE_ID="com.kostarelas.RunnerMenu"
AGENT_NAME="RunnerAgent"
AGENT_ID="com.kostarelas.RunnerMenu.agent"
AGENT_PLIST="com.kostarelas.RunnerMenu.agent.plist"
SIGN_IDENTITY="${RUNNERMENU_SIGN_IDENTITY:--}"

echo "==> swift build -c $CONFIG --product $APP_NAME"
swift build -c "$CONFIG" --product "$APP_NAME"
echo "==> swift build -c $CONFIG --product $AGENT_NAME"
swift build -c "$CONFIG" --product "$AGENT_NAME"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
AGENT_BIN="$BIN_DIR/$AGENT_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi
if [[ ! -f "$AGENT_BIN" ]]; then
    echo "error: built agent not found at $AGENT_BIN" >&2
    exit 1
fi

APP="$ROOT/build/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$AGENT_BIN" "$APP/Contents/Resources/$AGENT_NAME"
cp "$ROOT/Resources/$AGENT_PLIST" "$APP/Contents/Library/LaunchDaemons/$AGENT_PLIST"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

plutil -lint "$APP/Contents/Library/LaunchDaemons/$AGENT_PLIST" >/dev/null

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi

echo "==> Signing Runner Agent"
codesign "${SIGN_ARGS[@]}" --identifier "$AGENT_ID" "$APP/Contents/Resources/$AGENT_NAME"
echo "==> Signing app bundle"
codesign "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo ""
echo "Built: $APP"
echo "Run with:  open \"$APP\""
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Note: the bundled LaunchDaemon requires a Developer ID-signed and notarized app before macOS will approve it."
fi
