# Managing runners

## Finding runners already on this Mac

Add ▸ Find Runners on This Mac… scans running processes and the usual install
folders, including runners owned by other macOS accounts. It contacts nothing
and changes nothing. Tick the runners to watch and click Add; Choose Folder…
adds one from a location the scan does not cover.

A runner owned by another account is watched, not controlled: its launchd
service lives in that account's login session, so start and stop are only
available there, with `./svc.sh`.

## Registering a new runner

Add ▸ Register New Runner… opens the registration form.

1. Pick a private repository you administer. Public repositories are listed
   but cannot be chosen: a self-hosted runner executes pull request code on a
   machine that is not reset between jobs, so public work belongs on
   GitHub-hosted runners. To use a repository that is not listed, expand
   "Enter a private repository manually" and type `owner/repo`; Runner Menu
   checks that it is private and that you administer it before changing
   anything.
2. Name the runner and add labels, comma-separated. GitHub adds the default
   labels (`self-hosted`, `OSX` and the architecture) unless Advanced options
   skips them.
3. Advanced options can disable the runner's own self-update, so Runner Menu
   is its sole updater; make it ephemeral, taking one job and then
   unconfiguring itself; skip the default labels; and set a runner group.
4. Choose where the runner lives. In **New runner** mode Runner Menu downloads
   the latest runner package, verifies its SHA-256 against the hash GitHub
   publishes, and extracts it into a folder named `actions-runner-<repo>`
   under the Runners folder from Settings ▸ Runners. When that parent is a Git
   repository it offers to add the folder to its `.gitignore`. In
   **Existing folder** mode it configures a folder that already holds
   `config.sh`; if that folder already runs a runner for another repository,
   tick Reconfigure to move it.
5. Click Register. Runner Menu checks for a name collision, requests a
   one-time registration token through `gh`, and runs `config.sh`. The draft
   is kept if you close the panel part-way, and a registration in progress
   continues. If the old registration cannot be removed during a
   reconfiguration, a cleanup warning stays on the runner until you confirm
   the cleanup.

## Starting and stopping

Start Runner and Stop Runner are the large button in the runner's detail, the
play and stop button on each row in the window, and Return with a runner
selected in the panel. Settings ▸ Runners chooses how a runner starts:

- **Detached run.sh** runs `./run.sh` with `nohup`. The runner survives
  quitting Runner Menu, but launchd does not manage it.
- **launchd service** installs a LaunchAgent with `svc.sh`. The runner keeps
  going after you quit and starts again when you log in.

A runner you started yourself in a terminal is detected and can be stopped
from the app. Force Stop, in the row's context menu and in All Actions, sends
a stronger signal to a runner that will not stop.

## The launchd service

The Service menu in a runner's detail manages its LaunchAgent: Install & Start,
Install Only, Start Service and Stop Service, Open Service Logs, Show Status,
and Uninstall Service. The service's own log appears as a third source in the
live log while the service is installed.

## Labels

Labels in the runner's detail, or More ▸ Edit Labels… in the window, adds and
removes the runner's custom labels on GitHub. The default labels are fixed by
GitHub. Changes apply without restarting the runner.

## Every runner at once

All Actions, in the panel header and the window toolbar once two or more
runners are watched, offers Start All, Stop All, Force Stop All and
Check & Update All.

## Removing a runner

- **Remove from List**, in the row's context menu and in Settings ▸ Runners,
  stops Runner Menu watching the folder. Nothing on disk or on GitHub changes.
- **Unregister from GitHub…**, in the More menu and the context menu, stops
  the runner, requests a removal token and runs `config.sh remove`. The folder
  is kept.

Runner Menu never deletes a runner folder.
