# Settings

Settings opens with ⌘, from any window, from the gear in the panel footer, or
from Runner Menu ▸ Settings… in the menu bar. Every setting takes effect at
once and is kept across relaunches.

## General

- **Open Runner Menu at login** registers the app as a login item. The line
  beneath reports what macOS says: enabled, waiting for approval in System
  Settings ▸ General ▸ Login Items, or unavailable when the app is not running
  from a built application bundle. This is the app itself; to keep a runner
  alive at login, use the launchd service.
- **Refresh every** sets how often, from 2 to 30 seconds, Runner Menu re-reads
  each runner's process, log and job state.
- **Clicking a recent job** chooses whether a job in the history opens its run
  on GitHub or reveals its local Worker log in Finder.
- **Menu bar ▸ Icon** picks the glyph family for the menu bar item. Both
  families change with the runners' state.
- **About Runner Menu** opens the About window: version, links to the source
  and the issue tracker, the acknowledgements, and this manual.

## Runners

- **Start runners using** chooses between a detached `run.sh` and a launchd
  service; see [Managing runners](02-runners.md).
- **Runners folder** is where new runners are created, each in its own
  `actions-runner-<repo>` folder. When it is not set, `~/actions-runners` is
  used. A location outside Documents, Desktop and Downloads avoids macOS
  privacy prompts.
- **Runner folders** lists every folder being watched. Remove… stops watching
  one after a confirmation; the folder and its registration are not changed.
  Add Folder… watches a folder you choose, and Discover Existing Runners
  scans this Mac and adds anything new it finds.

In dedicated-account mode this tab only shows the start method, since runners
are watched rather than started.

## Accounts

- **gh executable** is the GitHub CLI Runner Menu runs. A bare name is looked
  up on the PATH; give a full path when `gh` lives somewhere unusual. Re-check
  asks `gh` for its sign-in status again, and the line beneath shows the
  account and scopes in use.
- **Runner jobs** shows which macOS account runs jobs. In dedicated-account
  mode the Runner Agent's service state, the account it connected as and its
  protocol version follow, with Register Agent, Open Login Items, Unregister
  Agent… and Refresh as they apply.
- **Review Setup…** reopens the first-run setup in the main window.

## Updates

Updates to Runner Menu itself, delivered with Sparkle.

- **Version** and **Last checked** describe this copy of the app.
- **Check for updates automatically** is off until you turn it on; **Frequency**
  then sets how often the app checks.
- **Check Now** looks for a new version immediately, and **Release Notes** opens
  the releases page.

A build without an update signing key cannot check for updates and says so;
it never installs anything it could not verify. Check for Updates… in the app
menu does the same as Check Now.
