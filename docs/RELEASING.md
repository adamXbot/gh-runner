# Releasing Runner Menu

Push a `v*` tag and the shared pipeline does the rest: test, sign, notarize,
DMG, appcast, GitHub Release, Homebrew cask PR.

Nothing here works until the secrets below exist — **this repository currently
has none**, so a tag pushed today fails at the first signing step.

## One-time setup

### 1. Sparkle keypair

Updates are verified against an EdDSA public key baked into the app. Without
it, `AppUpdater` disables updating entirely and `build-app.sh` refuses to
produce a signed build — an app that installs whatever its feed serves is a
remote-code-execution channel, and this one manages CI hosts.

Generate the pair once:

```bash
curl -fsSL -o /tmp/sparkle.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.5/Sparkle-2.9.5.tar.xz
tar -xJf /tmp/sparkle.tar.xz -C /tmp
/tmp/bin/generate_keys
```

It prints a public key and stores the private key in your login keychain.

- Paste the **public** key into `SUPublicEDKey` in `Resources/Info.plist`.
- Export the **private** key (`generate_keys -x`) and store it as the
  `SPARKLE_PRIVATE_KEY` secret. It never belongs in the repository.

### 2. Signing secrets

Create these on `adamXbot/gh-runner` — unlike the privacykey repos there is no
organisation to inherit them from, so they are per-repository here:

| Secret | What |
|---|---|
| `APPLE_CERTIFICATE` | base64 of the Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | its passphrase |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: NAME (TEAMID)` |
| `APPLE_API_KEY` | contents of the App Store Connect `.p8` |
| `APPLE_API_KEY_ID` | 10-character key ID |
| `APPLE_API_ISSUER` | issuer UUID |
| `SPARKLE_PRIVATE_KEY` | from step 1 |
| `HOMEBREW_TAP_TOKEN` | optional — the cask PR step skips cleanly without it |

Put `SPARKLE_PRIVATE_KEY` in a **`macos-signing` environment** and add a
required-reviewers rule to it, so a release pauses for a human before any
secret is read. Tests run before that gate.

### 3. Appcast branch

Create an empty `gh-pages` branch and enable Pages for it. The workflow pushes
`appcast.xml` there; `SUFeedURL` in `Info.plist` already points at
`https://adamxbot.github.io/gh-runner/appcast.xml`.

## Cutting a release

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Commit, then tag it — the tag must match, or the workflow stops:
   ```bash
   git tag v1.1.0 && git push origin v1.1.0
   ```
3. Approve the `macos-signing` environment when it pauses.

## Dry run

`scripts/release.sh` is runnable by hand, which is the point of keeping the
build in the repository rather than the workflow:

```bash
export APPLE_SIGNING_IDENTITY="Developer ID Application: …"
export APPLE_API_KEY_PATH=~/private_keys/AuthKey_XXXX.p8
export APPLE_API_KEY_ID=XXXXXXXXXX
export APPLE_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
./scripts/release.sh
```

It writes `dist/Runner Menu-<version>.dmg`, signed, notarized and stapled, and
prints its SHA-256.

## Why this repo differs from the other macOS apps

The others are Xcode projects; this is a SwiftPM package that `build-app.sh`
assembles into a bundle. The shared workflow supports that shape — `xcodeproj`
is left empty and `test_script` plus `release_script` take over. Only the steps
that drive `xcodebuild` change; signing, notarization, DMG, appcast, Release and
cask are identical.

Sparkle is embedded by `build-app.sh` rather than by Xcode: SwiftPM links the
XCFramework but assembles no bundle, so the framework is copied into
`Contents/Frameworks` and its nested helpers (the updater app, XPC services,
`Autoupdate`) are signed individually — `codesign --deep` is unreliable for
exactly that shape.
