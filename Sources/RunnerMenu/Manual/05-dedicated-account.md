# Dedicated runner account

A self-hosted runner executes workflow, pull request and dependency code on
this Mac, and the host is not reset between jobs, so the macOS account the
runner runs under is the real security boundary. Running jobs under a separate
standard account keeps them away from your files, your `gh` token, SSH keys,
signing certificates and browser data, and keeps job code from changing the
system.

## What it needs

- A standard, non-admin macOS account with the short name `runner`. The
  repository's `scripts/setup-macos-ci-account.sh` creates one and checks that
  it came out isolated.
- Runner Menu installed in `/Applications` from a Developer ID-signed and
  notarised build. macOS approves a bundled LaunchDaemon only for such an app;
  an ad-hoc development build verifies packaging and nothing more.

## The Runner Agent

Runner Menu bundles a small LaunchDaemon, the Runner Agent, which runs as the
`runner` account and answers over an authenticated XPC connection. Both ends
check the other's code signature before any message is accepted. In this
phase the agent is read-only: it reports its health (account, home folder,
protocol version and signing identity) and discovers runner installations in
its own home folder, and nothing else. There is no command, file or lifecycle
operation to misuse.

Register the agent during setup or from Settings ▸ Accounts, approve it in
System Settings ▸ General ▸ Login Items, then Refresh to confirm the
connection. Unregister Agent… removes it again; the runners themselves are not
touched.

## What works in this mode

The panel and the window show the agent's status and the runners it found.
Start, stop, registration, updates and logs stay disabled until lifecycle
control moves into the agent; Runner Menu will not fall back to running jobs
as the signed-in account. To create a runner under the dedicated account,
follow the manual registration steps in the repository's
`docs/RUNNER_HARDENING.md`, which the panel links to.

## Switching modes

Review Setup… in Settings ▸ Accounts, or Help ▸ Welcome to Runner Menu,
reopens the first-run setup where the account choice is made.
