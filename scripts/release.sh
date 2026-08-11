#!/bin/bash

# Build, sign, notarize and package Runner Menu as a DMG.
#
# Implements the release-script contract from privacykey/gh-workflows
# (docs/macos-release.md): the workflow owns orchestration, this script owns the
# build. Runnable by hand for a dry run, which is the point of the split.
#
#   reads (env)  APPLE_SIGNING_IDENTITY  Developer ID Application identity
#                APPLE_API_KEY_PATH      App Store Connect .p8 on disk
#                APPLE_API_KEY_ID        10-character key ID
#                APPLE_API_ISSUER        issuer UUID
#                KEYCHAIN_PATH           keychain holding the identity
#                SCHEME                  unused — there is no Xcode scheme here
#
#   writes       dist/Runner Menu-<version>.dmg   signed, notarized, stapled
#
# Unlike the Xcode consumers this repo has no .xcodeproj: build-app.sh assembles
# the bundle from a SwiftPM build. Everything downstream of that — signing,
# notarizing, stapling, packaging — is the same work in the same order.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Runner Menu"
BUNDLE_NAME="RunnerMenu"
BUILT_APP="$ROOT/build/$BUNDLE_NAME.app"
DIST="$ROOT/dist"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf 'error: %s\n' "$1" >&2; exit 1; }

: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY is required}"
: "${APPLE_API_KEY_PATH:?APPLE_API_KEY_PATH is required}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER:?APPLE_API_ISSUER is required}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
[[ -n "$VERSION" ]] || die "could not read CFBundleShortVersionString from Resources/Info.plist"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"

log "Building $APP_NAME $VERSION"
# build-app.sh signs the bundle (including the embedded Sparkle framework and
# its helpers) with this identity, and refuses to produce a signed build with an
# empty SUPublicEDKey.
RUNNERMENU_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" "$ROOT/build-app.sh" release
[[ -d "$BUILT_APP" ]] || die "build-app.sh did not produce $BUILT_APP"

log "Verifying the signature before notarizing"
# Catch a broken nested signature here rather than after a notarization round
# trip, which is slow and reports errors less clearly.
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
info "signature OK"

log "Notarizing the app"
APP_ZIP="$(mktemp -d)/${BUNDLE_NAME}.zip"
# ditto --keepParent preserves the bundle structure notarytool expects.
/usr/bin/ditto -c -k --keepParent "$BUILT_APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" \
    --wait
rm -f "$APP_ZIP"

log "Stapling the app"
# Staple so the app validates offline; without it Gatekeeper needs the network
# on first launch and fails closed when it cannot reach Apple.
xcrun stapler staple "$BUILT_APP"

log "Building the DMG"
mkdir -p "$DIST"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$BUILT_APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$STAGE"
info "$(basename "$DMG")"

log "Signing, notarizing and stapling the DMG"
# The DMG is signed and notarized in its own right: it is the artifact a user
# downloads, and Gatekeeper checks it before anything inside is opened.
codesign --force --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" \
    --wait
xcrun stapler staple "$DMG"

log "Done"
info "$DMG"
info "$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print $1}')"
