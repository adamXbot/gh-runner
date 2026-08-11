#!/bin/bash

# Run this from your ADMINISTRATOR account. It prints a block of commands to
# paste into a Terminal signed in as the CI account, which registers every
# fleet runner in one go.
#
# It exists because of an awkward, and deliberate, split:
#
#   - minting a registration token needs a GitHub credential, and
#   - the account that runs jobs must never hold one.
#
# So the credential stays here, and what crosses to the CI account is a set of
# short-lived, single-use registration tokens. A leaked one lets someone
# register a runner for an hour; a leaked `gh` login lets them do anything you
# can do, forever.
#
# It also copies the scripts somewhere the CI account can actually read them.
# A macOS home directory is mode 700, so the CI account cannot see anything
# under yours — which makes "just run ./scripts/register-fleet-runner.sh" from
# that account impossible until the scripts are staged somewhere shared.

set -uo pipefail

CLONE_URL="https://github.com/adamXbot/gh-runner.git"
# Left unexpanded on purpose: these strings are pasted into a shell running as
# the CI account, where $HOME is that account's home, not this one's.
CLONE_DIR="\$HOME/gh-runner"
SCRIPT_PATH="\$HOME/gh-runner/scripts"
RUNNERS_ROOT="\$HOME/runners"
STAGE_DIR=""
FLEET_FILE="${GH_RUNNER_FLEET_FILE:-$HOME/.config/gh-runner/fleet}"
labels="repo-ci"
repositories=()

usage() {
    /bin/cat <<'EOF'
Usage: mint-fleet-tokens.sh [OWNER/REPO ...] [options]

With no repositories given, reads them from a fleet file — one OWNER/REPO per
line, blank lines and # comments ignored:

    ~/.config/gh-runner/fleet     (override with $GH_RUNNER_FLEET_FILE)

That list lives outside this repository on purpose. This repository is public,
and an inventory of which private repositories run on which machine is exactly
the sort of thing not to publish. See fleet.example for the format.

Options:
  --fleet-file PATH  Read repositories from PATH instead of the default.
  --labels CSV       Labels for every runner registered by the printed block
                     (default: repo-ci).
  --script-dir PATH  Where the printed block should call the scripts from
                     (default: $HOME/gh-runner/scripts — i.e. the CI account's
                     own clone).
  --stage-dir PATH   Copy the scripts to PATH and have the printed block call
                     them from there, for a CI account that cannot clone. Off
                     by default: a clone stays current, a copy goes stale.
  --runners-root P   Where the printed commands put runner installations.
                     Default "$HOME/runners", which resolves inside the CI
                     account's home when the block is pasted there.
  -h, --help         Show this help.

The CI account gets the scripts by cloning this repository — it is public, so
that needs no credential:

    git clone https://github.com/adamXbot/gh-runner.git ~/gh-runner

Registration tokens are single-use and expire about an hour after minting, so
paste the block promptly. Re-run this to mint a fresh set.
EOF
}

read_fleet_file() {
    local file="$1"
    [ -r "$file" ] || return 1
    /usr/bin/sed -e 's/#.*//' -e 's/[[:space:]]//g' "$file" | /usr/bin/grep -v '^$'
}

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
info() { printf '  %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --fleet-file)   FLEET_FILE="${2:?--fleet-file needs a value}"; shift 2 ;;
        --labels)       labels="${2:?--labels needs a value}"; shift 2 ;;
        --script-dir)   SCRIPT_PATH="${2:?--script-dir needs a value}"; shift 2 ;;
        --stage-dir)    STAGE_DIR="${2:?--stage-dir needs a value}"; SCRIPT_PATH="$STAGE_DIR"; shift 2 ;;
        --runners-root) RUNNERS_ROOT="${2:?--runners-root needs a value}"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        -*)             printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        *)              repositories+=("$1"); shift ;;
    esac
done

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${#repositories[@]}" -eq 0 ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && repositories+=("$line")
    done < <(read_fleet_file "$FLEET_FILE" || true)

    if [ "${#repositories[@]}" -eq 0 ]; then
        bad "No repositories given, and no fleet file at $FLEET_FILE"
        info ""
        info "Either pass them as arguments:"
        info "    $(/usr/bin/basename "${BASH_SOURCE[0]}") owner/repo owner/other-repo"
        info ""
        info "or create the fleet file (see ${script_dir%/scripts}/fleet.example):"
        info "    mkdir -p \"\$(dirname \"$FLEET_FILE\")\""
        info "    \$EDITOR \"$FLEET_FILE\""
        exit 2
    fi
    info "Read ${#repositories[@]} repositories from $FLEET_FILE"
fi

step "Prerequisites"

if ! command -v gh >/dev/null 2>&1; then
    bad "The GitHub CLI ('gh') is required to mint registration tokens."
    exit 1
fi
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    bad "'gh' is not authenticated. Run: gh auth login"
    exit 1
fi
ok "GitHub CLI is authenticated as $(gh api user --jq '.login' 2>/dev/null || echo 'unknown')."

if [ -n "$STAGE_DIR" ]; then
    step "Staging the scripts where the CI account can read them"

    if ! /bin/mkdir -p "$STAGE_DIR"; then
        bad "Could not create $STAGE_DIR"
        exit 1
    fi
    for f in register-fleet-runner.sh audit-runner-host.sh; do
        if [ -f "$script_dir/$f" ]; then
            /bin/cp "$script_dir/$f" "$STAGE_DIR/$f" && /bin/chmod 755 "$STAGE_DIR/$f"
        else
            warn "$f not found next to this script; skipped."
        fi
    done
    # World-readable on purpose: these scripts contain no secrets, and the
    # whole problem being solved is that the CI account cannot read your home
    # directory.
    /bin/chmod 755 "$STAGE_DIR"
    ok "Staged to $STAGE_DIR"
    info "$(/bin/ls "$STAGE_DIR" | /usr/bin/tr '\n' ' ')"
fi

step "Checking visibility and minting tokens"

declare -a rows=()
failures=0

for repo in "${repositories[@]}"; do
    if [[ ! "$repo" =~ ^[^/]+/[^/]+$ ]]; then
        bad "$repo is not OWNER/REPO — skipped."
        failures=$((failures + 1))
        continue
    fi

    # Unauthenticated: GitHub answers 404 for a repository the caller cannot
    # see, so a 200 means it is readable by the whole internet. The fleet's
    # rule is private repositories only, and this is where it is cheapest to
    # catch a mistake — before a token exists at all.
    status="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}" 2>/dev/null || true)"

    case "$status" in
        404) ;;
        200)
            bad "$repo is PUBLIC — no token minted. Public repositories accept pull requests from anyone and get free minutes; leave them GitHub-hosted."
            failures=$((failures + 1))
            continue
            ;;
        *)
            bad "$repo — could not determine visibility (HTTP ${status:-no response}). Skipped."
            failures=$((failures + 1))
            continue
            ;;
    esac

    # Validate the shape, do not merely check for emptiness. On an error `gh
    # api --jq` hands back the whole error body on stdout — a 404 arrives as
    # 162 characters of JSON, which is non-empty, so an emptiness check calls
    # it a success and emits `--token {"message":"Not Found"...}` into the
    # block below. Registration tokens are a run of uppercase alphanumerics.
    token="$(gh api --method POST "repos/${repo}/actions/runners/registration-token" --jq '.token' 2>/dev/null)"
    if ! printf '%s' "$token" | /usr/bin/grep -Eq '^[A-Za-z0-9_-]{20,}$'; then
        if [ "$(gh api "repos/${repo}" --jq '.permissions.admin' 2>/dev/null)" = "false" ]; then
            bad "$repo — you do not administer this repository, so you cannot mint a registration token."
            info "         Minting needs admin. Run this script from an account that"
            info "         administers ${repo%%/*}, or ask its owner to send you the token."
        else
            bad "$repo — could not mint a token (unexpected response)."
        fi
        failures=$((failures + 1))
        continue
    fi

    ok "$repo"
    rows+=("${repo}|${token}")
done

if [ "${#rows[@]}" -eq 0 ]; then
    printf '\nNo tokens minted.\n'
    exit 1
fi

step "Paste this into a Terminal signed in as the CI account"

printf '\n'
if [ -z "$STAGE_DIR" ]; then
    printf '# Get the scripts (public repository, so no credential is needed):\n'
    printf 'git clone %s %s 2>/dev/null || git -C %s pull\n\n' "$CLONE_URL" "$CLONE_DIR" "$CLONE_DIR"
fi
printf '# Registers %d runner(s). Tokens are single-use and expire in about an hour.\n' "${#rows[@]}"
printf '# Each runner serves exactly one repository, hence one installation each.\n\n'

for row in "${rows[@]}"; do
    repo="${row%%|*}"
    token="${row#*|}"
    name="$(printf '%s' "${repo##*/}" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    printf '%s/register-fleet-runner.sh \\\n' "$SCRIPT_PATH"
    printf '    --repository %s \\\n' "$repo"
    printf '    --token %s \\\n' "$token"
    printf '    --dir "%s/%s" \\\n' "$RUNNERS_ROOT" "$name"
    printf '    --name mac-ci-%s \\\n' "$name"
    printf '    --labels %s\n\n' "$labels"
done

/bin/cat <<EOF
# Then start each one as a launchd service, so they survive a reboot:
# 'svc.sh install' fails with "exists" if the agent is already installed, so it
# must not gate 'start' behind && — re-running this should be safe, and the
# common case after a half-finished attempt is exactly "installed, not started".
for d in ${RUNNERS_ROOT}/*/; do (cd "\$d" && { ./svc.sh install >/dev/null 2>&1 || true; } && ./svc.sh start); done

# And check the host:
${SCRIPT_PATH}/audit-runner-host.sh --all-runners --check-visibility --check-updates

# Then schedule that audit weekly:
${SCRIPT_PATH}/install-audit-schedule.sh
EOF

step "Back on THIS account, once the block above has run"

/bin/cat <<'EOF'
  Remove the credential a CI job could otherwise steal:

      gh auth logout --hostname github.com

  The audit FAILs a host where a job can reach a GitHub CLI login. Log back
  in only for administrative work like this, then log out again.
EOF

if [ "$failures" -gt 0 ]; then
    printf '\n%d repository/repositories were skipped — see above.\n' "$failures"
    exit 1
fi
