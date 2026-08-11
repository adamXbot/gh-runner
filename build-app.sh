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

# --- Sparkle -----------------------------------------------------------------
# SwiftPM links the XCFramework but assembles no bundle, so the framework has to
# be embedded here or the app dies at launch with a dyld "image not found".
echo "==> Embedding Sparkle"
SPARKLE_FRAMEWORK="$(/usr/bin/find "$ROOT/.build/artifacts" -type d -name "Sparkle.framework" -path "*macos*" 2>/dev/null | /usr/bin/head -1)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "error: Sparkle.framework not found under .build/artifacts — run 'swift build' first" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
echo "    $(basename "$(dirname "$SPARKLE_FRAMEWORK")")/Sparkle.framework"

# An update Sparkle cannot verify is an update anyone can supply. Refuse to cut
# a *signed* build without the public key: ad-hoc builds are for development and
# disable updating at runtime instead (see AppUpdater), but a Developer ID build
# is the one that ships.
ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$SIGN_IDENTITY" != "-" && -z "$ED_KEY" ]]; then
    echo "error: SUPublicEDKey is empty in Resources/Info.plist." >&2
    echo "       A release build must be able to verify its own updates." >&2
    echo "       Generate a keypair with Sparkle's generate_keys, paste the public" >&2
    echo "       key into Info.plist, and store the private key as SPARKLE_PRIVATE_KEY." >&2
    echo "       See docs/RELEASING.md." >&2
    exit 1
fi
if [[ -z "$ED_KEY" ]]; then
    echo "    note: SUPublicEDKey is empty — self-update stays disabled in this build."
fi

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi

# Sign inside out. Sparkle ships its own helpers (an updater app, XPC services,
# the Autoupdate tool); codesign --deep is documented as unreliable for exactly
# this shape, so each nested executable is signed explicitly before the
# framework that contains it.
echo "==> Signing Sparkle helpers"
SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
while IFS= read -r helper; do
    [[ -e "$helper" ]] || continue
    codesign "${SIGN_ARGS[@]}" "$helper"
    echo "    $(basename "$helper")"
done < <(
    /usr/bin/find "$SPARKLE_IN_APP" \
        \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) \
        -maxdepth 4 2>/dev/null
)
codesign "${SIGN_ARGS[@]}" "$SPARKLE_IN_APP"

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
