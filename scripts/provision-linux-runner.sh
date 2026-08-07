#!/bin/bash

# Provision an Ubuntu VM as an ephemeral self-hosted Actions runner.
#
# The macOS half of this fleet has a problem it cannot solve: a Mac is a
# persistent machine, so a job can read what the last job left behind. Linux
# does not have to accept that. A runner registered with --ephemeral takes
# exactly one job and then deregisters, and this script pairs that with a
# systemd unit that re-registers with a fresh just-in-time token for the next
# one. Every job therefore starts from a runner that has never run anything.
#
# That is the whole reason Linux jobs go to a separate VM rather than onto the
# Mac. It is also why this VM should be exactly a runner and nothing else:
# Docker group membership is root-equivalent, and any pipeline that builds
# container images needs it. Contained in a dedicated VM that is an acceptable
# trade; on a machine with anything else on it, it is not.
#
# Run as root (or with sudo) on a fresh Ubuntu 24.04 VM.
#
# Requires a registration PAT to mint just-in-time tokens. Scope it as tightly
# as GitHub allows: a fine-grained token, only the repositories this runner
# serves, "Administration: read & write" and nothing else. It lives in a
# mode-600 file readable only by root, never by the runner account — a job must
# not be able to read the credential that would let it register more runners.

set -euo pipefail

RUNNER_USER="ci-runner"
RUNNER_HOME="/opt/actions-runner"
REPOSITORY=""
LABELS="repo-ci"
RUNNER_VERSION=""
TOKEN_FILE="/etc/actions-runner/registration-token"
skip_toolchain=false
with_azure_cli=false

usage() {
    cat <<'EOF'
Usage: provision-linux-runner.sh --repository OWNER/REPO [options]

Required:
  --repository OWNER/REPO  Repository this runner serves. Must be private.

Options:
  --user NAME           Account jobs run as (default: ci-runner).
  --home PATH           Runner installation directory (default: /opt/actions-runner).
  --labels CSV          Extra labels (default: repo-ci).
  --runner-version V    Actions runner release (default: latest).
  --token-file PATH     Where the registration PAT is read from
                        (default: /etc/actions-runner/registration-token).
  --skip-toolchain      Don't install Node/Docker/Postgres/Trivy/browser deps.
  --with-azure-cli      Also install the Azure CLI. Off by default: it is a
                        large install, and a job that needs `az` only
                        occasionally is usually cheaper to leave on a hosted
                        runner than to grow this VM for.
  -h, --help            Show this help.

After it finishes, write the PAT to the token file and start the service:

    install -m 600 /dev/null /etc/actions-runner/registration-token
    # paste the PAT into it, then:
    systemctl enable --now actions-runner
EOF
}

log()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\033[31mFAIL\033[0m %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repository)     REPOSITORY="${2:?--repository needs a value}"; shift 2 ;;
        --user)           RUNNER_USER="${2:?--user needs a value}"; shift 2 ;;
        --home)           RUNNER_HOME="${2:?--home needs a value}"; shift 2 ;;
        --labels)         LABELS="${2:?--labels needs a value}"; shift 2 ;;
        --runner-version) RUNNER_VERSION="${2:?--runner-version needs a value}"; shift 2 ;;
        --token-file)     TOKEN_FILE="${2:?--token-file needs a value}"; shift 2 ;;
        --skip-toolchain) skip_toolchain=true; shift ;;
        --with-azure-cli) with_azure_cli=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$REPOSITORY" ] || { usage >&2; die "--repository is required."; }
[[ "$REPOSITORY" =~ ^[^/]+/[^/]+$ ]] || die "--repository must be OWNER/REPO, got '$REPOSITORY'."
[ "$(id -u)" -eq 0 ] || die "Run as root."
command -v apt-get >/dev/null 2>&1 || die "This script targets Debian/Ubuntu."

log "Checking that $REPOSITORY is private"

# Unauthenticated on purpose: GitHub answers 404 rather than 403 for a
# repository the caller cannot see, so a 200 means it is readable by the whole
# internet. Same check the macOS registration script makes, same reason —
# self-hosted runners serve private repositories only. See docs/RUNNER_FLEET.md.
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${REPOSITORY}" || true)"
case "$status" in
    404) info "Not publicly readable. Good." ;;
    200) die "'$REPOSITORY' is PUBLIC. Public repositories get free Actions minutes and accept pull requests from anyone — leave it on a GitHub-hosted runner." ;;
    *)   die "Could not determine visibility of '$REPOSITORY' (HTTP ${status:-no response}). Refusing to guess." ;;
esac

log "Base system"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl ca-certificates git jq unzip tar sudo \
    unattended-upgrades apt-listchanges ufw >/dev/null
info "Base packages installed."

# Security updates without a human in the loop. A runner nobody logs into is a
# runner nobody patches.
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
info "Unattended security upgrades enabled."

log "Firewall"

# A runner makes outbound connections only — it long-polls GitHub. Nothing
# needs to reach it, so nothing may. SSH is allowed because locking yourself
# out of a VM you still have to maintain is its own kind of outage; drop the
# line if you administer this box through a console.
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
ufw --force enable >/dev/null
info "Inbound denied except SSH; outbound allowed."

log "Runner account: $RUNNER_USER"

if id "$RUNNER_USER" >/dev/null 2>&1; then
    info "Account already exists."
else
    # No login shell, no password: this account exists to run jobs, and
    # nothing else should be able to become it.
    useradd --system --create-home --shell /usr/sbin/nologin "$RUNNER_USER"
    info "Created system account with no login shell."
fi

if ! $skip_toolchain; then
    log "Toolchain"

    # Node 22 from NodeSource — the distro's node is too old for the workflows
    # this fleet runs.
    if ! command -v node >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
        apt-get install -y -qq nodejs >/dev/null
    fi
    info "Node: $(node --version 2>/dev/null || echo 'not installed')"

    # Docker from Docker's own repository.
    if ! command -v docker >/dev/null 2>&1; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        # shellcheck source=/dev/null
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
        cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null
    fi
    # Docker group membership is effectively root on this host. That is a real
    # cost, accepted only because this VM is a runner and nothing else, and
    # because each job gets a runner that has never run anything.
    usermod -aG docker "$RUNNER_USER"
    info "Docker: $(docker --version 2>/dev/null || echo 'not installed') (runner account added to the docker group — root-equivalent, see header)"

    # PostgreSQL client tools only. The workflows that need a database bring
    # their own server as a service container.
    apt-get install -y -qq postgresql-client-16 >/dev/null 2>&1 \
        || apt-get install -y -qq postgresql-client >/dev/null
    info "psql: $(psql --version 2>/dev/null || echo 'not installed')"

    # Shared libraries headless Chromium needs. Playwright installs the
    # browser itself per project; these are the OS-level dependencies it
    # cannot install without root.
    apt-get install -y -qq \
        libnss3 libnspr4 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 \
        libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
        libxrandr2 libgbm1 libasound2t64 libpango-1.0-0 libcairo2 \
        fonts-liberation >/dev/null 2>&1 || \
        info "Some browser dependencies were unavailable — check package names for this release."
    info "Headless browser dependencies installed."

    if ! command -v trivy >/dev/null 2>&1; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key \
            | gpg --dearmor -o /etc/apt/keyrings/trivy.gpg 2>/dev/null
        echo "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
            > /etc/apt/sources.list.d/trivy.list
        apt-get update -qq
        apt-get install -y -qq trivy >/dev/null 2>&1 || info "Trivy install failed — install it manually if a workflow needs it."
    fi
    trivy_version="$(trivy --version 2>/dev/null || true)"
    info "Trivy: $(printf '%s\n' "$trivy_version" | awk 'NR==1' || true)"

    if $with_azure_cli && ! command -v az >/dev/null 2>&1; then
        curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash >/dev/null 2>&1 \
            || info "Azure CLI install failed — install it manually if a workflow needs it."
    fi
    if $with_azure_cli; then
        az_version="$(az version --output tsv 2>/dev/null || true)"
        info "Azure CLI: $(printf '%s\n' "$az_version" | awk 'NR==1' || true)"
    fi
fi

log "Installing the Actions runner"

if [ -z "$RUNNER_VERSION" ]; then
    RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | jq -r '.tag_name' | sed 's/^v//')"
fi
[ -n "$RUNNER_VERSION" ] && [ "$RUNNER_VERSION" != "null" ] \
    || die "Could not determine the latest runner version. Pass --runner-version."

case "$(dpkg --print-architecture)" in
    amd64) RUNNER_ARCH="x64" ;;
    arm64) RUNNER_ARCH="arm64" ;;
    *)     die "Unsupported architecture: $(dpkg --print-architecture)" ;;
esac

mkdir -p "$RUNNER_HOME"
tarball="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

if [ ! -x "$RUNNER_HOME/config.sh" ]; then
    info "Downloading runner ${RUNNER_VERSION} (${RUNNER_ARCH})"
    # To disk first, then verify, then extract. Never pipe an archive
    # straight into tar.
    curl -fsSL --retry 3 -o "/tmp/${tarball}" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}"

    # Captured, then parsed. A `| head -1` on the end of this pipeline lets
    # head close the pipe first, curl/jq take SIGPIPE, and the whole script
    # abort with 141 under `set -euo pipefail` — intermittently.
    # The release notes list each asset as:
    #
    #   - actions-runner-linux-x64-X.Y.Z.tar.gz <!-- BEGIN SHA linux-x64 -->04cf...<!-- END SHA linux-x64 -->
    #
    # so the digest follows the filename on the same line, inside an HTML
    # comment — not the `<sha>  <file>` layout sha256sum produces. Match the
    # line by filename, then take the only 64-hex string on it.
    release_body="$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/tags/v${RUNNER_VERSION}" | jq -r '.body' || true)"
    expected_sha="$(printf '%s\n' "$release_body" \
        | grep -F -- "$tarball" \
        | grep -Eo '[a-f0-9]{64}' \
        | awk 'NR==1' || true)"
    if [ -n "$expected_sha" ]; then
        echo "${expected_sha}  /tmp/${tarball}" | sha256sum -c - >/dev/null \
            || { rm -f "/tmp/${tarball}"; die "SHA-256 mismatch on ${tarball}."; }
        info "SHA-256 verified against the published release notes."
    else
        info "WARNING: no SHA-256 found in the release notes; download unverified."
    fi

    tar -xzf "/tmp/${tarball}" -C "$RUNNER_HOME"
    rm -f "/tmp/${tarball}"
fi

"$RUNNER_HOME/bin/installdependencies.sh" >/dev/null 2>&1 || true
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"
info "Runner ${RUNNER_VERSION} installed at $RUNNER_HOME"

log "Ephemeral registration loop"

mkdir -p "$(dirname "$TOKEN_FILE")"
if [ ! -f "$TOKEN_FILE" ]; then
    install -m 600 /dev/null "$TOKEN_FILE"
    info "Created empty $TOKEN_FILE (mode 600, root-owned). Put the PAT in it."
fi
chmod 600 "$TOKEN_FILE"
chown root:root "$TOKEN_FILE"

# This is the piece that makes each job start clean. --ephemeral tells GitHub
# to retire the runner after one job; the loop then registers a new one with a
# fresh just-in-time token. The PAT is read by this script as root and passed
# to config.sh, never left where the runner account (and so a job) could read it.
cat > /usr/local/bin/actions-runner-ephemeral <<EOF
#!/bin/bash
# Registers a fresh ephemeral runner, runs one job, exits. systemd restarts it.
# Generated by provision-linux-runner.sh — edit that instead.
set -euo pipefail

REPOSITORY="${REPOSITORY}"
RUNNER_HOME="${RUNNER_HOME}"
RUNNER_USER="${RUNNER_USER}"
LABELS="${LABELS}"
TOKEN_FILE="${TOKEN_FILE}"
EOF

cat >> /usr/local/bin/actions-runner-ephemeral <<'EOF'

[ -s "$TOKEN_FILE" ] || { echo "No registration PAT in $TOKEN_FILE" >&2; exit 1; }
PAT="$(cat "$TOKEN_FILE")"

reg_token="$(curl -fsSL -X POST \
    -H "Authorization: Bearer ${PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPOSITORY}/actions/runners/registration-token" \
    | jq -r '.token')"
unset PAT

[ -n "$reg_token" ] && [ "$reg_token" != "null" ] \
    || { echo "Could not mint a registration token for ${REPOSITORY}" >&2; exit 1; }

# A stale .runner from a killed job would make config.sh refuse.
rm -f "${RUNNER_HOME}/.runner" "${RUNNER_HOME}/.credentials" \
      "${RUNNER_HOME}/.credentials_rsaparams" 2>/dev/null || true

# Wipe the work directory between jobs. --ephemeral means GitHub gives this
# runner one job, but the disk is still this VM's disk.
rm -rf "${RUNNER_HOME}/_work" 2>/dev/null || true

sudo -u "$RUNNER_USER" -- "${RUNNER_HOME}/config.sh" \
    --url "https://github.com/${REPOSITORY}" \
    --token "$reg_token" \
    --name "linux-ci-$(hostname -s)-$$" \
    --labels "$LABELS" \
    --ephemeral \
    --unattended \
    --replace

exec sudo -u "$RUNNER_USER" -- "${RUNNER_HOME}/run.sh"
EOF

chmod 700 /usr/local/bin/actions-runner-ephemeral
info "Wrote /usr/local/bin/actions-runner-ephemeral"

cat > /etc/systemd/system/actions-runner.service <<EOF
[Unit]
Description=Ephemeral GitHub Actions runner for ${REPOSITORY}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/actions-runner-ephemeral
# The runner exits after each job by design; restarting IS the loop.
Restart=always
RestartSec=5
# Runs as root only to read the PAT and mint a token — every job is handed
# to ${RUNNER_USER} via sudo inside the script.
User=root
KillMode=mixed
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
info "Wrote actions-runner.service (not started)"

log "Done"

cat <<EOF
    Repository : ${REPOSITORY}
    Labels     : self-hosted, Linux, ${RUNNER_ARCH^^}, ${LABELS}
    Account    : ${RUNNER_USER} (no login shell)
    Mode       : ephemeral — one job per runner, fresh registration each time

    Still to do:

      1. Put a fine-grained PAT in ${TOKEN_FILE}
         Scope: this repository only, Administration: read & write, nothing else.

             install -m 600 /dev/null ${TOKEN_FILE}
             # paste the PAT, save

      2. Start it:

             systemctl enable --now actions-runner
             systemctl status actions-runner
             journalctl -u actions-runner -f

      3. Confirm it appears under the repository's
         Settings > Actions > Runners, then push a commit and watch it take
         a job and disappear afterwards. Disappearing is correct.

    Do not install anything else on this VM. The runner account is in the
    docker group, which on Linux is root-equivalent; a dedicated VM is what
    keeps that contained.
EOF
