# Troubleshooting

## The GitHub account chip says gh is missing or signed out

Runner Menu runs the GitHub CLI for every call to GitHub. Install it from
https://cli.github.com, sign in with `gh auth login --scopes repo`, then click
Re-check in Settings ▸ Accounts. If `gh` is installed somewhere unusual, enter
its full path there.

## A repository is missing from the registration form, or says it needs admin

Only private repositories you administer can take a runner from Runner Menu.
Public repositories are shown but cannot be chosen, and a repository where you
lack admin access reports that rather than failing part-way. Use "Enter a
private repository manually" for a repository the list does not show.

## A runner is not found by the scan

Find Runners on This Mac looks at running processes, the usual install
folders and `/Users/Shared`. Choose Folder… in that screen, or Add Folder… in
Settings ▸ Runners, adds a runner from any other location: pick the folder
that holds `config.sh`.

## Start and Stop are unavailable

- A runner owned by another macOS account can be watched but not controlled;
  switch to that account and use `./svc.sh` there.
- A runner that is starting or stopping, or has an operation in progress,
  waits for it to finish.
- In dedicated-account mode, lifecycle controls are disabled for every runner.
- A folder with no registration shows "not configured": register it first.

## Open at login is waiting for approval

macOS asks you to approve new login items. Open System Settings ▸ General ▸
Login Items and allow Runner Menu; the caption in Settings ▸ General updates
when you return. The toggle is unavailable when the app runs straight from the
package build rather than from a built application bundle.

## The launchd service will not start or stop

The Service menu's Show Status reports what `svc.sh status` says, and Open
Service Logs reveals its log files. A service installed by another account
can only be controlled from that account's session.

## A runner update is refused

Runner Menu only installs a runner package whose SHA-256 matches the hash
GitHub published. When the release notes carry no hash, the update waits for
"Allow update without verification"; when the hash does not match, the
download is discarded and nothing changes. A runner that is executing a job
waits for the job to finish.

## The live log is empty or missing

The log view reads the newest file in the runner's `_diag` folder. A runner
that has never run has no Runner log; the Worker log appears once a job has
run; the Service source appears only while a launchd service is installed.
Reveal in Finder opens the folder so you can see what is there.

## The Runner Agent is unavailable

Dedicated-account mode needs a standard macOS account named `runner` and a
Developer ID-signed, notarised Runner Menu in `/Applications`. The setup
screen and Settings ▸ Accounts say which of those is missing; an ad-hoc
development build cannot register the agent. After registering, approve it in
System Settings ▸ General ▸ Login Items and click Refresh.

## Runner Menu cannot check for its own updates

A build without an update signing key cannot verify an update, so it does not
check at all; Settings ▸ Updates says so. Release builds carry the key.

## Reporting a problem

Report an Issue in the About window opens the issue tracker. Do not include
credentials, registration tokens or unredacted runner logs in an issue; the
repository's SECURITY.md explains how to report a vulnerability privately.
