# Hardening the repository runner

This repository's ordinary CI is designed for a persistent, repository-level macOS runner with the
custom label `repo-ci`. A self-hosted runner executes repository code on the host and is not reset
between jobs, so the macOS account is the main security boundary.

## Security properties enforced here

- `.github/workflows/ci.yml` evaluates pull requests using the trusted base-branch workflow, rejects
  any whose head repository is not this repository before selecting a runner, and only then checks
  out the same-repository PR merge ref.
- Ordinary jobs require all four labels: `self-hosted`, `macOS`, `ARM64`, and `repo-ci`.
- Workflows have read-only repository permissions and checkout does not retain the workflow token in
  the local Git configuration.
- Every external action is pinned to a full commit SHA. Dependabot maintains those references.
- No workflow signs or archives a distribution build. The `repo-ci` runner must not contain a
  distribution certificate or private key.
- A scheduled audit checks the host boundary, repository-scoped registration, runner update policy,
  FileVault, and pending macOS updates.

The fork check protects against fork pull requests. It does not make code from repository
collaborators safe: a collaborator who can push a branch can intentionally execute code in an
ordinary PR job. Keep the account free of credentials and private data even when all collaborators
are trusted. If the repository becomes public, prefer a GitHub-hosted runner or a disposable
ephemeral VM; the fork check does not turn a persistent host into a disposable sandbox.

The use of `pull_request_target` in this one workflow is deliberate: its workflow definition comes
from the base branch, so a fork cannot remove the gate. No fork job is allocated and no fork code is
checked out. Do not add steps that run for fork PRs or weaken the same-repository condition.

## One-time macOS setup

Perform the administrative steps from a separate administrator account.

1. Keep FileVault enabled in **System Settings → Privacy & Security → FileVault**.
2. Create a standard macOS account used only for CI, for example `ci-runner`. Do not make it an
   administrator and do not run the service as `root`.
3. Sign in to that account without signing in to an Apple Account or iCloud. Do not configure Mail,
   Messages, browser sync, a password manager, personal SSH keys, or personal Keychain items.
4. Install the required Xcode or Command Line Tools. Do not copy an existing developer home
   directory, Keychain, or shell configuration into this account.
5. Confirm Keychain Access contains no Apple Distribution, Developer ID Application, Mac App
   Distribution, or equivalent distribution identity.

Register the runner from this repository's **Settings → Actions → Runners → New self-hosted runner**
page. Do not create it under organization or enterprise settings. During configuration, use this
repository's exact URL and add the ordinary-CI label:

```bash
./config.sh \
  --url https://github.com/OWNER/REPOSITORY \
  --token ONE_TIME_REGISTRATION_TOKEN \
  --labels repo-ci
```

Leave the runner's automatic update mechanism enabled. Install and start its service while signed in
as the dedicated standard account; do not use `sudo` or install it from the personal administrator
account.

If Runner Menu is used to register the runner, select this repository from the repository picker
rather than entering an organization under **Advanced**. Runner Menu uses the active GitHub CLI
login to mint the one-time registration token. Log that account out immediately afterward so PR code
cannot steal a long-lived GitHub CLI credential:

```bash
gh auth logout --hostname github.com
```

Reauthenticate only while performing an administrative operation, then log out again. Registration
does not require the GitHub CLI credential to remain present after configuration.

## Verify the host

Run the read-only audit while signed in as the runner account. Use the real runner directory and
repository slug:

```bash
./scripts/audit-runner-host.sh \
  --runner-dir "$HOME/actions-runner" \
  --expected-repository OWNER/REPOSITORY \
  --check-updates
```

The audit fails when the user is an administrator, iCloud is configured, a private SSH key, GitHub
CLI login, or common password-manager data is found, a distribution signing identity is accessible,
FileVault is off, the runner is not repository-scoped, automatic runner updates are disabled, or a
macOS update is pending. It cannot prove that every Keychain item is non-personal, so review
Keychain Access and the account's Internet Accounts manually as well.

The scheduled **Runner host audit** workflow runs the same check weekly. Its failure is a maintenance
alert, not a request to weaken or skip the checks.

## Signing and releases

Continue archiving and signing manually from a separate development account unless a distinct
release boundary is set up. Never import a distribution certificate into the `ci-runner` account.

If release automation is added later, use all of the following:

- A separate standard macOS account and separate runner installation.
- A `release-signing` label that is not present on the `repo-ci` runner. Labels route jobs; they are
  not a security boundary on their own.
- A release-only workflow with no `pull_request` trigger, a protected GitHub environment requiring
  approval, and branch/tag protection that prevents unreviewed workflow changes.
- Distribution certificates and provisioning material only in the release account's Keychain.
- No ordinary build/test jobs on the signing runner.

## Maintenance

- Apply macOS security updates promptly and rerun the audit after each update.
- Keep Xcode or Command Line Tools on a supported, patched version and verify the selected toolchain
  with `xcodebuild -version`.
- Leave the Actions runner auto-update enabled. Runner Menu can verify and apply runner updates, but
  avoid disabling GitHub's updater unless there is a documented maintenance process and owner.
- Review **Settings → Actions → Runners** periodically: the ordinary runner should appear only in
  this repository and have the `repo-ci` label, never `release-signing`.
- Review every Dependabot pull request that changes an action SHA and keep the human-readable version
  comment on the same line.
