# Getting started

Runner Menu is a menu bar utility for the GitHub Actions self-hosted runners on
this Mac. It is a thin controller around the runner's own scripts (`run.sh`,
`svc.sh` and `config.sh`) and the GitHub CLI, so it stays compatible with a
runner you set up by hand in the usual `actions-runner` folder.

## What you need

- macOS 14 or later.
- The GitHub CLI, `gh`, signed in with `gh auth login` and the `repo` scope.
  Runner Menu never asks for a token: every call to GitHub goes through `gh`,
  so nothing is typed into the app or stored by it.
- A runner folder that already exists, or a private repository you administer
  so Runner Menu can download and register a new one.

## First run

The first time it opens, Runner Menu asks how it should work with runners on
this Mac:

1. **This account** creates and controls runners as the account you are signed
   in to. Start, stop, registration, the launchd service and runner updates
   are all available.
2. **Dedicated runner account** monitors runners owned by a standard macOS
   account named `runner`, through a signed Runner Agent. See
   [Dedicated runner account](05-dedicated-account.md) for what that needs.

It then looks for runners that already exist, in running processes, the usual
install folders and `/Users/Shared`, and lets you tick the ones to watch.
Nothing on disk or on GitHub changes until you finish setup. To go through it
again later, choose Help ▸ Welcome to Runner Menu or Review Setup… in
Settings ▸ Accounts.

## The menu bar item

The glyph in the menu bar shows the state of every watched runner at a glance:
a stop symbol when none is online, a play symbol when a runner is online, a
bolt while a job is running, and a clock while a runner is starting or
stopping. In dedicated-account mode it is a shield, filled when the Runner
Agent is connected. Settings ▸ General chooses between two glyph families.

Click the glyph to open the panel:

- The header shows the app's mark and name, the GitHub CLI account in use, an
  All Actions menu when two or more runners are watched, and Refresh (⌘R).
- The body switches between **All Runners**, the fleet totals, and
  **Selected Runner**, one runner's stats and activity. See
  [Watching runners](03-watching.md).
- Below it, **Add** finds or registers a runner and **Updates** opens the
  runner update screen for the selected runner.
- The footer opens the full window, Settings (⌘,) and quits (⌘Q).

Longer tasks, such as registering a runner or reading a log, open as screens
inside the panel with a Back button; Esc also goes back.

## The window

Open Runner Menu from the panel footer, or choose Window ▸ Runner Menu Window
(⌘0) whenever another window is open. The sidebar lists All Runners, the
Dashboard and every watched runner; the toolbar holds Add Runner, Refresh and
All Actions; a runner's page has Overview, Logs and Updates tabs.

While any of its windows is open, Runner Menu appears in the Dock with a full
menu bar. It returns to the menu bar alone when the last window closes.
