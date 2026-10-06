# Updating runners

This page is about the GitHub Actions runner software inside each runner
folder. Updates to Runner Menu itself come through Settings ▸ Updates and
Check for Updates… in the app menu; see [Settings](06-settings.md).

## Checking

Updates in a runner's detail, the Updates button under the panel, or the
Updates tab in the window compares the installed version, from
`Runner.Listener --version`, with the latest release of `actions/runner`. It
shows the installed and latest versions, when the latest was released, and
whether an update is available.

## Verification

Before anything is installed, the macOS package for this Mac's architecture is
downloaded and its SHA-256 is compared with the hash GitHub publishes in the
release notes. The card shows the hash that will be checked. When the release
notes carry no hash for the package, the update is refused unless you tick
"Allow update without verification", which is not recommended. A download whose
hash does not match is discarded.

## Applying

Update to the latest version, or Reinstall when the runner is already current,
asks for confirmation and then runs through the phases shown in the runner's
detail: downloading, verifying, waiting for the runner to go idle, stopping,
installing, and restarting if the runner was running. A runner that is
executing a job cannot be updated until the job finishes; a runner owned by
another account cannot be updated from here. Opening the screen again during
an update shows its current phase and does not start a second one.

Check & Update All, in All Actions, does the same for every runner that can be
updated.

## Release notes

The screen shows the latest release's notes and links to the release on
GitHub. The full history is at https://github.com/actions/runner/releases.
