# Cross-user runner architecture

## Goal

Allow Runner Menu to stay open in an administrator's GUI session while every GitHub Actions runner
process, job, worktree, diagnostic log, and runner credential belongs to a separate standard macOS
account named `runner`.

The administrator's GitHub CLI login remains in the administrator's home directory and Keychain.
Runner jobs never execute with that user's UID and cannot read those credentials through normal
macOS file and Keychain isolation.

## Chosen system shape

```text
Administrator session                         System launchd domain

RunnerMenu.app  ── authenticated XPC ──>  Runner Agent LaunchDaemon
     │                                           UserName = runner
     │ GitHub API / temporary token              no GUI, no GitHub CLI login
     │                                           owns runner folders and jobs
     └── status and semantic commands <──────────┘
```

The agent will be an app-bundled LaunchDaemon registered with `SMAppService`. Its signed launchd
property list will use `UserName=runner`, so launchd starts it in the system domain under the
standard account even when that account has no interactive login session. The administrator must
approve the daemon once in System Settings.

The menu app will connect using `NSXPCConnection(machServiceName:options: .privileged)`. The daemon
will validate the connecting process's code-signing identity before accepting the connection. An
ad-hoc signed development build can exercise the local backend, but cross-user activation requires
a consistently signed app and helper.

The initial implementation intentionally supports the fixed short account name `runner`. A launchd
`UserName` is part of the signed, bundled property list; supporting an arbitrary account later needs
a separately reviewed enrollment design instead of rewriting that property list at runtime.

First-launch onboarding records whether the operator wants current-account or dedicated-account
execution. Current-account mode remains fully supported. Dedicated mode is fail-closed until the
agent is installed and healthy: selecting it never falls back to executing jobs as the administrator.
The current-account discovery pass searches only locations readable without elevation; future
dedicated-account discovery is performed by the agent inside its own managed root.

## Current implementation status

Phase 2 is implemented as a deliberately read-only vertical slice:

- `RunnerAgent` is a separate executable embedded at `Contents/Resources/RunnerAgent`.
- Its `SMAppService` property list lives at `Contents/Library/LaunchDaemons` and declares
  `UserName=runner`, a fixed Mach service, and a bundle-relative `BundleProgram`.
- The app reports `not registered`, `requires approval`, `enabled`, and `not found` states and links
  to Login Items settings.
- The shared protocol negotiates version 1 and exposes only `health` and `discoverRunners`.
- Both XPC peers call `setCodeSigningRequirement` before activation. Developer ID builds bind the
  peer requirement to the fixed identifier and signing Team ID; ad-hoc builds are clearly marked as
  development-only.
- The app verifies that the agent reports account `runner`, has a nonzero UID, uses the expected
  protocol, and returns only records owned by that UID beneath its reported home directory.
- Dedicated-mode dashboards contain no lifecycle controls, and local controller mutations reject
  requests while that mode is selected.

Activation requires a standard account with short name `runner`. Apple requires an app containing
a LaunchDaemon to be properly signed and notarized; it should be installed in `/Applications` so
the daemon is available before login. The repository's default ad-hoc build validates layout and
signatures but is not a production-installable LaunchDaemon distribution.

## Responsibility boundary

### Runner Menu UI

- Authenticates to GitHub as the interactive administrator.
- Requests repository-scoped registration and removal tokens.
- Displays runner status, jobs, logs, and maintenance state returned by the agent.
- Sends semantic commands such as `start`, `stop`, `register`, and `unregister`.
- Registers and reports the `SMAppService` daemon's approval state.

### Runner Agent

- Runs with the `runner` UID and primary group, never as the interactive administrator.
- Owns a fixed managed root under the runner account's home directory.
- Downloads, verifies, configures, starts, stops, monitors, and updates runner installations.
- Supervises runner processes directly from the system-domain daemon; it does not depend on a
  per-login LaunchAgent.
- Parses diagnostic logs and returns bounded, structured results to the UI.
- Keeps desired runner state in the runner account's Application Support directory.

### GitHub Actions runner

- Runs as a child of the agent with a minimal environment and the `runner` UID.
- Receives only its repository-scoped runner credential and per-job `GITHUB_TOKEN`.
- Has no access to the administrator's home, GitHub CLI login, SSH keys, password manager, or
  signing Keychain.

## XPC contract

The public agent API is an allowlist of domain operations. It must never expose an arbitrary shell,
executable path, environment dictionary, signal number, file read, or file write primitive.

Planned operations:

- `health` and protocol-version negotiation.
- `listRunners` and `observeRunners`.
- `startRunner`, `stopRunner`, and `restartRunner` by enrolled runner identifier.
- `registerRepositoryRunner` using a short-lived registration token.
- `unregisterRunner` using a short-lived removal token.
- `tailLog` with server-side line and byte limits.
- `checkUpdate` and `applyVerifiedUpdate`.

Every runner identifier is resolved through the agent's own registry. Caller-supplied paths are not
trusted. Registration and removal tokens are held only for the duration of one request and are never
logged, persisted, or returned.

## Security invariants

1. The daemon accepts connections only from the signed Runner Menu client requirement.
2. The app also requires the expected signed daemon, preventing connection to an impersonating
   Mach service.
3. Runner directories must resolve beneath the fixed managed root, be owned by `runner`, and contain
   no path component writable by another non-root account.
4. Symlinks are resolved and revalidated before every destructive operation.
5. XPC inputs have explicit size limits; logs and errors are scrubbed for registration/removal
   tokens before crossing the process boundary.
6. The agent launches only known runner scripts from an enrolled directory and supplies a fixed,
   minimal environment.
7. The agent has no distribution-signing identities and no API for invoking `codesign`, `security`,
   `ssh`, or an arbitrary subprocess.
8. Repository scope and required labels are validated after registration and during health checks.
9. Agent updates are delivered only as part of the signed application bundle and require
   re-registration when Service Management requires it.

## Rollout

### Phase 1 — backend seam

Move runner observation and commands behind `RunnerExecutionBackend`. Keep the existing behavior in
`LocalRunnerExecutionBackend`. Implemented; this preserves all existing same-user behavior.

### Phase 2 — read-only agent

Add the signed helper executable, launchd property list, Service Management UI, XPC protocol version,
connection validation, health check, runner discovery, status, and bounded log reads. Current-account
mode continues to use the local backend; dedicated mode never falls back to it.

Implemented for health and discovery. Bounded diagnostic-log reads remain deferred until the
agent-owned runner dashboard needs them; no local fallback occurs after dedicated mode is selected.

### Phase 3 — lifecycle control

Move start, stop, process monitoring, and desired-state supervision into the agent. Remove the
cross-user dependency on each runner's `svc.sh` LaunchAgent.

### Phase 4 — enrollment and maintenance

Move runner download, hash verification, repository registration, removal, and updates into the
agent. Tokens cross XPC for one operation only. Add migration from an existing same-user runner into
the fixed managed root.

### Phase 5 — hardened default

Make agent mode the recommended setup, clearly label local mode as same-user, add upgrade/recovery
flows, and complete adversarial tests for paths, XPC callers, token redaction, and process ownership.
