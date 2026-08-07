# The Linux runner

Ubuntu VM running **ephemeral** self-hosted runners for Linux CI jobs.

Read [RUNNER_FLEET.md](RUNNER_FLEET.md) first — the private-repositories-only
rule applies here identically, and `provision-linux-runner.sh` enforces it
before it does anything else.

## Why this is a separate machine

Two reasons, and the first is the interesting one.

**Linux can be disposable; a Mac cannot.** The macOS runners are persistent
hosts — a job can read whatever the last job left behind, and the macOS account
is the only real boundary. A Linux runner registered with `--ephemeral` takes
exactly one job and then deregisters. Pair that with a systemd unit that
re-registers with a fresh just-in-time token and every job starts on a runner
that has never run anything. That is a materially stronger property than
anything available on the Mac, and it is worth a separate VM to get it.

**Docker group membership is root-equivalent.** A pipeline that builds
container images needs the runner account in the `docker` group, which on Linux
is effectively root on that host. Contained inside a VM
whose only job is running CI, that is an acceptable trade. On a machine with
anything else on it — a personal Mac, say — it is not.

So: this VM is a runner and nothing else. Don't install anything on it that you
would mind a CI job reaching.

## What it runs

The default toolchain targets a heavy Node web-application pipeline: Node 22,
Playwright/Chromium, a Postgres client, Docker image builds, and Trivy scans.
Adjust it in the script for your own workloads.

Be selective about what comes here. Linux Actions minutes bill at 1×, so a job
that takes seconds saves nothing worth the move — and jobs that reach out to
third-party sites (link checkers especially) will do so from your network
rather than GitHub's, which may be a reason on its own to leave them hosted.
Move the pipelines that are actually expensive.

Jobs needing a large, rarely used tool are often better left hosted too. The
Azure CLI is the example the provisioning script accounts for: `--with-azure-cli`
installs it, but if only one infrequent job needs `az`, that job is cheaper to
leave on `ubuntu-latest`.

Expect to change any step that uses `sudo`, because **the runner account has
none** — a job that can install packages can rewrite the host. Two real
examples from migrating a Node pipeline here:

- `npx playwright install --with-deps chromium` → `npx playwright install
  chromium`. The `--with-deps` flag shells out to `apt-get` via sudo. The
  browser's OS-level libraries are installed here once, at provisioning time;
  the browser binary itself needs no privileges.
- `sudo apt-get install postgresql-client-16` → a presence check. On a runner
  that is rebuilt for every job, installing the same package every time is pure
  wall-clock even where it would work.

That pattern generalises: when a workflow moves here, its `sudo` steps become
the host's job, and the workflow checks rather than installs.

## Provisioning

On a fresh Ubuntu 24.04 VM, as root:

```bash
./scripts/provision-linux-runner.sh --repository OWNER/REPO
```

It refuses to continue if the repository is public, installs the toolchain, sets
up a `ci-runner` system account with no login shell, denies all inbound traffic
except SSH, downloads and SHA-256-verifies the runner, and writes the systemd
unit — but does not start it.

Then supply the registration credential and start it:

```bash
install -m 600 /dev/null /etc/actions-runner/registration-token
# paste the PAT into that file
systemctl enable --now actions-runner
```

## The registration PAT

The ephemeral loop needs to mint a new registration token before each job, so
unlike the macOS runners this host holds a standing credential. Scope it as
tightly as GitHub allows:

- **fine-grained** token, not a classic one
- **only** the repositories this runner serves
- **Administration: read & write**, and nothing else
- an expiry you will actually notice

It lives in a mode-600 root-owned file. The runner account cannot read it, and
neither can a job: the systemd unit runs as root purely to read the PAT and mint
a token, then hands the job to `ci-runner` via `sudo`. That asymmetry is the
point — a job that could read this credential could register runners of its own.

## Verifying

```bash
systemctl status actions-runner
journalctl -u actions-runner -f
```

A healthy runner **disappears from the repository's runner list after each job**
and a new one appears. That is the ephemeral mode working, not a fault.

Check, in the repository's Settings → Actions → Runners:

- the runner has labels `self-hosted`, `Linux`, `X64`, `repo-ci`
- it is registered to one repository, not an organisation
- it does not carry `release-signing`

## Maintenance

- Unattended security upgrades are enabled at provisioning time. A runner
  nobody logs into is a runner nobody patches, so leave them on.
- The Actions runner self-updates. Leave that on too.
- Rotate the PAT on whatever schedule its expiry forces, and remember the
  service reads it only at job start — `systemctl restart actions-runner` after
  changing it.
- If a workflow starts failing on a missing tool, the host owes it: add the
  package to the toolchain section of the provisioning script rather than
  installing it by hand, so a rebuilt VM comes back the same.
- Rebuilding this VM from scratch should be boring. If it isn't, something has
  been installed by hand that the script doesn't know about.
