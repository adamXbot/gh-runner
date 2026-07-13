# Runner Menu

A native macOS **menu-bar app** for managing GitHub Actions **self-hosted runners** on your Mac.
Built with SwiftUI (`MenuBarExtra`); see [DESIGN.md](DESIGN.md) for the interaction and
architecture decisions.

It's a thin, respectful controller around GitHub's own runner scripts (`run.sh`, `svc.sh`,
`config.sh`) and the `gh` CLI — so it stays compatible with how the runner already works on your
machine (for example, `~/actions-runner`).

## What it does

- **Set up tokens from your repos, no PAT typing.** Reuses your existing `gh` login. Pick a repo you
  administer, and the app mints a registration token (`…/actions/runners/registration-token`) and
  runs `config.sh` for you. It filters the picker to the repos where you actually have admin.
- **Start / stop the runner.** Either detached `./run.sh` (survives quitting the app) or a launchd
  **service** (`svc.sh`, also starts at login). It even detects a runner you started yourself in a
  terminal and lets you stop it.
- **Stats & observability.** Live state, PID, CPU %, memory, uptime (from `ps`), the currently
  running job and recent job history (parsed from `_diag` logs), plus a live log console.
- **Start the app at login.** One toggle, via `SMAppService`.
- **Check for updates, verify the hash, and update.** Compares your installed
  `Runner.Listener --version` against `actions/runner`'s latest release, downloads the macOS package,
  **verifies its SHA-256** against the value published in the release notes, then stops → extracts →
  restarts the runner. It refuses to apply an unverifiable download unless you explicitly override.
- **See every repo a runner is active on.** Each managed runner shows its bound repo/org; add as many
  runner folders as you like.

## Requirements

- macOS 14+ (developed and tested on macOS 26 / Apple Silicon).
- Swift toolchain (Command Line Tools is enough — **no full Xcode required**).
- [`gh`](https://cli.github.com) installed and authenticated (`gh auth login`) with `repo` scope
  (and `admin:org` if you register org-level runners).
- An existing runner install (the GitHub-provided `actions-runner` folder). The app can also
  download and create a brand-new runner folder for you.

## Build & run

```bash
./build-app.sh            # release build -> build/RunnerMenu.app (ad-hoc signed)
open build/RunnerMenu.app
```

Or during development:

```bash
swift build               # compile
swift test                # run the unit tests
swift run                 # run straight from the package
```

The app has **no Dock icon** — look for its glyph in the menu bar (top-right). Set
`RUNNERMENU_DOCK=1` in the environment to force a Dock icon while debugging.

> Because it's ad-hoc signed, the first launch may need a right-click → Open, and the
> **login item** and **launchd service** features work best once the app lives in a stable location
> (e.g. `/Applications/RunnerMenu.app`).

## Using it

1. **First run** — if `~/actions-runner` exists it's picked up automatically. Otherwise click **Add**
   to point at an existing runner folder, or register a new one.
2. **Register** (Add → *Existing folder* / *New runner*) — pick a repo from your admin list (or type
   `owner/repo`, an org, or a URL under *Advanced*), name the runner, add labels, and hit
   **Register**. *New runner* downloads + hash-verifies the latest runner package into a new folder
   first.
3. **Start / stop** — the big button in the detail area, the play/stop button on each row, or Return.
   Choose the start method (detached `run.sh` vs launchd service) in **Settings**.
4. **Observe** — watch CPU/mem/uptime and the current job; open **Log** for a live tail.
5. **Update** — **Updates** (⌘U) checks the latest release, shows the SHA-256 it will verify, and
   updates in place.
6. **Start at login** — toggle in **Settings** (this is the app; use the launchd service to also keep
   the *runner* alive at login).

## Architecture

```
Sources/RunnerMenu/
  RunnerMenuApp.swift        @main — MenuBarExtra + Settings scenes, AppDelegate (accessory policy)
  Models/
    RunnerConfig.swift       parse .runner (BOM-tolerant); scope repo/org/enterprise
    RunnerInstance.swift     one runner directory
    RunnerStatus.swift       live status (state/pid/cpu/mem/uptime/busy/job)
    GitHubModels.swift       repo / token / release / runner DTOs
  Services/
    Shell.swift              async Process wrapper (concurrent pipe drain, PATH augmentation)
    GitHubClient.swift       gh-CLI wrapper: auth, admin repos, tokens, runners, releases
    ProcessMonitor.swift     ps scan -> PID/CPU/mem/uptime, dir<->PID via executable path
    LogTailer.swift          newest _diag log, job start/complete parsing, tail
    RunnerController.swift    start/stop/register/unregister, launchd service, signals
    Updater.swift            check/download/SHA-256 verify/extract; release-body hash parse
    LoginItem.swift          SMAppService.mainApp wrapper
    RunnerStore.swift        @MainActor @Observable hub: polling, actions, settings
  Views/                     MenuContentView, RunnerRowView, RunnerDetailView,
                             RegisterRunnerView, UpdatesView, LogConsoleView, SettingsView, …
build-app.sh                 assemble + ad-hoc sign the .app bundle
Resources/Info.plist         LSUIElement, bundle id, versions
```

Everything GitHub-related routes through `gh`, so the app never handles your credentials directly.

## Security notes

- **No credential entry.** The app never asks for or stores a token; it delegates auth to `gh`.
- **Verified updates.** Runner updates are SHA-256-checked against GitHub's published hash before being
  applied; an unverifiable package is refused unless you knowingly override.
- **Destructive actions are gated.** Unregister and update are explicit, confirm where it matters, and
  never delete your runner directory.

For a machine that executes this repository's Actions jobs, follow the dedicated-account,
repository-only registration, fork-PR, signing-isolation, and update checklist in
[Hardening the repository runner](docs/RUNNER_HARDENING.md).

Please report suspected vulnerabilities privately as described in [SECURITY.md](SECURITY.md). Do
not include credentials, registration tokens, or unredacted runner logs in a public issue.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for the community standards. For usage questions, see
[SUPPORT.md](SUPPORT.md).

## License

Runner Menu is available under the [MIT License](LICENSE).

## Manual QA checklist

Runtime verification (the app compiles and launches cleanly; exercise the GitHub-mutating flows
against a throwaway repo):

- [ ] Menu-bar glyph reflects idle / online / busy and updates as the runner changes state.
- [ ] Start and stop a runner via button, row control, and Return; confirm `ps` shows it appear/exit.
- [ ] Detached `run.sh` keeps running after you **Quit** the app; launchd service does too and starts at login.
- [ ] Register into an existing folder; re-register (replace) to a different repo.
- [ ] Register a **new** folder (downloads + verifies + configures).
- [ ] Current job + recent job history match the runner's `_diag` logs during a real workflow run.
- [ ] Live log tails both Runner and Worker sources; Copy and Reveal in Finder work.
- [ ] Update check reports correct installed vs latest; SHA-256 card shows the published hash; a
      forced hash mismatch is rejected with the download discarded.
- [ ] Context menu on a row acts on that runner (Open on GitHub, Copy URL/Name, Reveal, Unregister, Remove).
- [ ] Settings persist across relaunch (interval, start method, gh path, folders, login item).
- [ ] Works in dark mode and with increased contrast; VoiceOver reads runner rows and stats.
- [ ] A repo you lack admin on surfaces a clear "needs admin" message rather than a raw error.
