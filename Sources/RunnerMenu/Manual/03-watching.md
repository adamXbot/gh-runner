# Watching runners

## All Runners

The panel and the window both open on All Runners: six totals for the watched
fleet, with the combined CPU and memory of every runner process beneath them.

- **Runners**: every watched runner.
- **Active**: running or starting.
- **Running jobs**: executing a job right now.
- **Idle**: online and ready for the next job.
- **Stopped**: not running.
- **Needs attention**: an error, an unknown state, or setup still to do.

Click a total to open its activity preview: each matching runner with its
state, the job it is running or the last job it ran, any error, and the
progress of a runner update. Open Runner shows that runner's detail and View
Log opens its live log. Esc or the close button returns to the totals.

## One runner

Selected Runner in the panel, or a runner's Overview tab in the window, shows:

- State, PID, CPU, memory and uptime, read from `ps` on every refresh.
- The installed runner version, the repository or organisation the runner is
  registered to, and its folder.
- The job in progress, with a Cancel button that asks GitHub to cancel the
  workflow run and so stop the job on this runner.
- The launchd service's state and its Service menu.
- Recent jobs, parsed from the runner's `_diag` logs: result, duration and
  how long ago each ran. Clicking a job opens it on GitHub or reveals its
  local Worker log in Finder, as chosen in Settings ▸ General; the job's
  context menu offers both.

## Dashboard

The Dashboard in the window combines every runner: totals for runners,
running, busy, CPU and memory; a table with one row per runner; and one merged
log in which each runner's lines take their own colour. Pause freezes the log
and Live resumes it.

## The live log

Log in a runner's detail, or the Logs tab in the window, tails the newest
`_diag` log. Switch between the Runner and Worker logs, and the Service log
while a launchd service is installed; Follow newest lines keeps the view at the
end; Copy puts the whole log on the clipboard and Reveal in Finder opens the
`_diag` folder. A missing, empty or unreadable log says so rather than showing
nothing. In the window, switching runners keeps the chosen source and follow
setting.

## Refreshing

Runner Menu re-reads every runner on the interval set in Settings ▸ General,
and whenever you click Refresh or press ⌘R.
