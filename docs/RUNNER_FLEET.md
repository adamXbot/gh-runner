# The runner fleet

What runs where, and why the boundaries are drawn where they are.

[RUNNER_HARDENING.md](RUNNER_HARDENING.md) covers hardening a single macOS
runner host. This document covers the fleet as a whole: which repositories are
allowed on it, which are deliberately not, and what each label means.

## The rule

**Self-hosted runners serve private repositories only.**

Everything else here follows from that, so it is worth being precise about why.

A self-hosted runner is a persistent machine. It is not reset between jobs, so
a job can read whatever the previous job left behind, plus everything else the
account it runs as can reach. A public repository accepts pull requests from
anyone, and a pull request is a proposal to run the author's code.

The two facts together would be bad enough. What settles it is the third:
**Actions minutes for public repositories are free.** So a public repository on
owned hardware takes on the entire risk in exchange for no saving at all.

Which gives an unusually clean split — the repositories that cost money and the
repositories that strangers can reach are disjoint sets:

| | Public repositories | Private repositories |
|---|---|---|
| Who can start a job | anyone, via a fork pull request | people with push access |
| Actions minutes | free | billed (macOS at 10×) |
| Runner | GitHub-hosted, always | this fleet |

The rule is enforced in four places, deliberately overlapping — any one of them
can be got wrong without the others failing:

1. **At registration.** `scripts/register-fleet-runner.sh` refuses to bind a
   runner to a public repository, before it mints a token.
2. **Before a runner is allocated.** The job-level `if:` in each workflow
   rejects fork pull requests, so fork code never reaches the host.
3. **Before checkout.** `privacykey/gh-workflows/actions/assert-trusted-runner`
   is the first step of every job. It re-checks visibility and fork status on
   the runner itself and fails closed.
4. **On a schedule.** `scripts/audit-runner-host.sh --check-visibility` asks
   github.com whether each bound repository has become publicly readable.
   Install it with `scripts/install-audit-schedule.sh`, run as the CI account.

That last one is a local launchd job rather than a scheduled workflow, and the
reason is this repository itself: auditing a host means running on it, and a
*public* repository must not touch the fleet. The rule applies to this project
before it applies to anyone else's. Running locally is the better fit anyway —
a machine that has drifted out of policy should not need CI to be healthy in
order to say so.

## What the rule does not do

It keeps out strangers. It does not make the host safe for code from people who
already have push access — a collaborator can run whatever they like on this
machine, on purpose, through an ordinary pull request. The account it all runs
as must therefore stay empty of anything worth stealing, even when every
collaborator is trusted.

Nor is it a substitute for the account boundary. Labels route jobs; they do not
isolate them. Two runners sharing a macOS account share everything.

## Labels

The first three are implicit (the runner sets them from the host). The fourth
is the one that matters.

| Label | Meaning |
|---|---|
| `self-hosted`, `macOS`, `ARM64` | Set automatically by the runner. |
| `repo-ci` | Ordinary build and test. **No signing identity, no secrets.** Runs pull request code from collaborators, so it is treated as the least trusted thing on the machine. |
| `release-signing` | Holds a distribution certificate. Its own macOS account, its own runner installation, and **no pull request triggers, ever**. |

A `repo-ci` runner that can reach a distribution certificate is not a `repo-ci`
runner — it is a signing runner with a misleading label. `audit-runner-host.sh`
fails a host where one is visible.

## Your allocation

Which repositories run where is deliberately **not** in this repository. It
lives in a fleet file outside it:

```
~/.config/gh-runner/fleet     # override with $GH_RUNNER_FLEET_FILE
```

One `owner/repo` per line; see [`fleet.example`](../fleet.example) for the
format. `mint-fleet-tokens.sh` reads it.

That is not fussiness. This repository is public, and an inventory of which
private repositories run on which machine is exactly the sort of thing not to
publish — it names private work and points at a specific host. Keep any notes
about your own allocation next to the fleet file, not here.

Typically: macOS jobs on a Mac, Linux jobs on a separate VM
([LINUX_RUNNER.md](LINUX_RUNNER.md)) which can be disposable in a way a Mac
cannot.

**Keep releases on GitHub-hosted runners.** Release jobs are usually
tag-triggered and rare, so they are a rounding error on the bill — while
self-hosting them means putting a distribution certificate on the machine that
also runs pull request code. That trade is bad in both directions. The
companion `gh-workflows` reusable workflows support it (`release_runner` plus
the `release-signing` label) for when the arithmetic genuinely changes; see
[Adding a signing runner](#adding-a-signing-runner) for what that obliges you
to do.

If you already have a repository signing on an ordinary CI runner, write it
down as a known exception rather than leaving it implicit. A rule with a silent
counterexample is worse than no rule: the host holds signing material, whatever
the label says, and anything else you put on it inherits that.

**One runner serves one repository.** A user account (as opposed to an
organisation) supports repository-level runners only, so covering eight
repositories means eight installations side by side, all owned by the same CI
account. They are cheap when idle. `audit-runner-host.sh --all-runners` checks
them together, and Runner Menu shows them in one list.

## Registering runners

Registration straddles two accounts, and the split is deliberate:

- minting a registration token needs a **GitHub credential**, and
- the account that runs jobs must **never hold one**.

So the credential stays on the administrator account, and what crosses over is
a set of short-lived, single-use registration tokens. A leaked registration
token lets someone add a runner for an hour. A leaked `gh` login lets them do
anything you can do, until you notice.

There is a second, duller obstacle: a macOS home directory is mode `700`, so
the CI account cannot read the administrator's copy of these scripts. Since
this repository is public, the CI account just clones its own:

```bash
git clone https://github.com/adamXbot/gh-runner.git ~/gh-runner
```

No credential needed, and `git pull` keeps it current — which a copied file
does not.

Then, **from the administrator account:**

```bash
./scripts/mint-fleet-tokens.sh
```

It checks every repository in your fleet file is private, mints a token for
each, and prints a ready-to-paste block. **Paste that into a Terminal signed in
as the CI account** — it registers one runner per repository, installs each as
a launchd service, and runs the audit.

If the CI account cannot clone (no network, or you would rather not), pass
`--stage-dir` and the script copies itself to `/Users/Shared/fleet-runner`
instead. Use `--script-dir` to tell it which path the printed block should
call.

Tokens expire about an hour after minting, so do both steps in one sitting.
Re-run to mint a fresh set.

Then, back on the administrator account:

```bash
gh auth logout --hostname github.com
```

For a single repository, `register-fleet-runner.sh` takes `--token` directly
and needs no GitHub CLI at all:

```bash
/Users/Shared/fleet-runner/register-fleet-runner.sh \
    --repository OWNER/REPO \
    --token <one-time token> \
    --dir "$HOME/runners/REPO" \
    --labels repo-ci
```

Both scripts refuse public repositories, and that check needs no credential
either — so the private-repositories-only rule holds identically whichever
account you are in.

In the repository's workflow:

```yaml
    runs-on: [self-hosted, macOS, ARM64, repo-ci]
```

or, for a consumer of the shared workflows:

```yaml
    with:
      runner: '["self-hosted", "macOS", "ARM64", "repo-ci"]'
```

## What the host owes the workflows

Self-hosted jobs skip the setup steps that hosted images need, so the host has
to provide them. This is the contract:

- **Xcode**, selected and usable — `xcodebuild -version` must work. Workflows
  no longer run `maxim-lobanov/setup-xcode` on self-hosted runners: it
  re-points the *machine's* selected Xcode, which on a shared host reaches into
  every other repository's builds.
- **xcodegen** on `PATH` (workflows add `/opt/homebrew/bin` themselves).
- Whatever else a repository's workflow assumes it can call. When a workflow
  stops installing a tool per job, the host has to grow it — the failure
  message names the tool.

## Hostname and network exposure

- Runners are named for their role (`mac-ci-1`), never after the machine. The
  runner name appears in every job log; a hostname is a detail those logs do
  not need.
- No public repository is bound to the fleet, so no world-readable log names
  this host at all.
- Package registries (Homebrew, npm, Apple) see this network's IP address
  during builds — the same as they do when you build locally. Job logs do not
  contain the runner's IP address; GitHub does not put it there.
- Workflows should not print network identity. If a step needs to reach
  something unusual, that is worth noticing.

## Adding a signing runner

Not currently done. If it is ever needed, all of the following, not some:

1. A separate standard macOS account — the distribution certificate lives in
   *its* Keychain, not the CI account's.
2. A separate runner installation in that account, labelled `release-signing`.
   The `repo-ci` runner must not carry that label.
3. A release-only workflow with no `pull_request` trigger of any kind.
4. A GitHub environment with required reviewers, so a release pauses for a
   human before any secret is read.
5. Branch and tag protection, so the workflow itself cannot be changed
   unreviewed.
6. No ordinary build or test jobs on that runner.

Pass it through as `release_runner: '["self-hosted", "macOS", "ARM64", "release-signing"]'`.

## Maintenance

- `./scripts/audit-runner-host.sh --all-runners --check-visibility --check-updates`,
  signed in as the CI account. The scheduled **Runner host audit** workflow
  runs the same check weekly; a failure is a maintenance alert, not a prompt to
  relax the check.
- Apply macOS security updates promptly and re-run the audit afterwards.
- Leave Actions runner auto-update enabled.
- Review **Settings → Actions → Runners** on each repository periodically. A
  runner should appear on exactly one repository, with `repo-ci` and never
  `release-signing`.
- When a repository is made public, remove its runner. The workflow gates will
  fail its jobs either way, but a bound runner is a standing invitation.
