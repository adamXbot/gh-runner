#!/bin/bash

# Create the dedicated macOS account that self-hosted Actions jobs run as.
#
# The account — not the label, not the workflow `if:` — is the security
# boundary. A self-hosted runner executes repository code on a machine that is
# not reset between jobs, so whatever that account can read, a job can read:
# its Keychain, its SSH keys, its GitHub CLI login, its home directory. Running
# jobs as a personal administrator account hands all of that to anyone who can
# push a branch.
#
# This script does one thing well: it creates a standard (non-administrator)
# account and proves it came out isolated. Everything that needs a human
# decision — FileVault's recovery key above all — is printed as an instruction
# rather than executed, because a recovery key that scrolls past in a terminal
# is a recovery key that is already lost.
#
# Run it from your ADMINISTRATOR account. It refuses to do anything without
# --apply.

set -uo pipefail

# `runner`, not `ci-runner`, and the name is load-bearing twice over:
#
#   1. Runner Menu's dedicated-account mode hardcodes it —
#      RunnerAgentProtocol.accountName == "runner", and the bundled
#      LaunchDaemon plist declares UserName=runner. A signed plist cannot be
#      rewritten at runtime, so an account by any other name is invisible to
#      the app that manages this fleet.
#   2. It makes the home directory /Users/runner, which is what GitHub's
#      hosted macOS images use. Actions that bake in the hosted layout then
#      just work — ruby/setup-ruby's prebuilt macOS Rubies, for instance, are
#      compiled with /Users/runner/hostedtoolcache hardcoded and fail with
#      EACCES under any other account name.
ACCOUNT="runner"
FULL_NAME="CI Runner"
apply=false

usage() {
    /bin/cat <<'EOF'
Usage: setup-macos-ci-account.sh [options]

Options:
  --account NAME    Short name of the account to create (default: runner).
                    Changing it breaks Runner Menu's dedicated-account mode,
                    which hardcodes "runner", and forfeits the /Users/runner
                    home path that hosted-layout actions expect. See the
                    comment at the top of this script.
  --full-name NAME  Display name (default: "CI Runner").
  --apply           Actually create the account. Without it, this is a dry run.
  -h, --help        Show this help.

Run from an administrator account. You will be prompted for a password for the
new account; it is never echoed and never stored by this script.
EOF
}

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --account)   ACCOUNT="${2:?--account needs a value}"; shift 2 ;;
        --full-name) FULL_NAME="${2:?--full-name needs a value}"; shift 2 ;;
        --apply)     apply=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$(/usr/bin/uname -s)" != "Darwin" ]; then
    bad "This script is macOS-only."
    exit 1
fi

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_FILE="${GH_RUNNER_FLEET_FILE:-$HOME/.config/gh-runner/fleet}"

step "Preflight"

if ! /usr/bin/id -Gn "$(/usr/bin/id -un)" | /usr/bin/grep -qw admin; then
    bad "Run this from an administrator account — creating a user needs admin rights."
    exit 1
fi
ok "Running as administrator '$(/usr/bin/id -un)'."

if /usr/bin/id "$ACCOUNT" >/dev/null 2>&1; then
    info "Account '$ACCOUNT' already exists — nothing to create."
    account_exists=true
else
    info "Account '$ACCOUNT' does not exist yet."
    account_exists=false
fi

# Only creation needs --apply. When the account is already there, there is
# nothing to change, so go straight on to verifying it and saying what comes
# next — which is the part you actually need on the second and later runs.
if ! $apply && ! $account_exists; then
    step "Dry run"
    info "Re-run with --apply to create the account. This run changed nothing."
    info ""
    info "It would run:"
    info "  sudo sysadminctl -addUser '$ACCOUNT' -fullName '$FULL_NAME' -password - "
    info "  (standard account: -admin is deliberately NOT passed)"
    exit 0
fi

if ! $account_exists; then
    # sysadminctl refuses to create a second account whose full name is already
    # taken, which happens the moment you add a second CI account. Catch it here
    # with a usable message rather than letting sysadminctl mumble about it.
    realname_owner="$(/usr/bin/dscl . -search /Users RealName "$FULL_NAME" 2>/dev/null \
        | /usr/bin/awk 'NR==1 {print $1}')"
    if [ -n "$realname_owner" ] && [ "$realname_owner" != "$ACCOUNT" ]; then
        bad "Full name '$FULL_NAME' already belongs to the account '$realname_owner'."
        info "sysadminctl will refuse to create '$ACCOUNT' with a duplicate full name."
        info "Give this one its own:"
        info "  $(/usr/bin/basename "${BASH_SOURCE[0]}") --apply --full-name 'CI Runner ($ACCOUNT)'"
        exit 1
    fi

    step "Creating the account"
    info "You will be prompted twice: once for sudo, once for the new account's password."
    # -admin is deliberately absent. A CI account that can escalate is not a
    # boundary, it is a speed bump.
    sudo /usr/sbin/sysadminctl -addUser "$ACCOUNT" -fullName "$FULL_NAME" -password -

    # Verify the outcome, do not trust the exit status. sysadminctl returns 0
    # even when it declines to do anything — it will print "User with full name
    # 'X' already exists" and still exit successfully, so a naive check reports
    # a created account that is not there.
    if ! /usr/bin/id "$ACCOUNT" >/dev/null 2>&1; then
        bad "'$ACCOUNT' was not created."
        info "sysadminctl exits 0 even when it refuses, so read its output above for the reason."
        exit 1
    fi
    ok "Created '$ACCOUNT'."
fi

step "Verifying isolation"

verify_failures=0

if /usr/bin/id -Gn "$ACCOUNT" 2>/dev/null | /usr/bin/grep -qw admin; then
    bad "'$ACCOUNT' is in the admin group. Remove it: sudo dseditgroup -o edit -d '$ACCOUNT' -t user admin"
    verify_failures=$((verify_failures + 1))
else
    ok "'$ACCOUNT' is not an administrator."
fi

account_home="$(/usr/bin/dscl . -read "/Users/$ACCOUNT" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
if [ -n "$account_home" ]; then
    ok "Home directory: $account_home"
else
    bad "Could not read the account's home directory."
    verify_failures=$((verify_failures + 1))
fi

if [ "$verify_failures" -gt 0 ]; then
    printf '\n%d verification failure(s). Fix them before registering a runner.\n' "$verify_failures"
    exit 1
fi

filevault_state="$(/usr/bin/fdesetup status 2>&1 | /usr/bin/head -1)"

step "What happens next"

/bin/cat <<EOF
  The account exists. Four things remain, in this order.

  ── 1. FileVault ─────────────────────────────────────── (this account, now)

     Currently: ${filevault_state}

     Not automated on purpose: enabling it emits a recovery key exactly once,
     and a recovery key that scrolls past in a terminal is already lost. Have
     somewhere to write it down, then:

         sudo fdesetup enable -user $(/usr/bin/id -un)

     Or System Settings > Privacy & Security > FileVault. Check with:

         fdesetup status

  ── 2. Sign in as '$ACCOUNT' once ────────────────── (login window)

     Log in through the login window to materialise the home directory and
     Keychain. While you are there, do NOT:

       - sign in to an Apple Account or iCloud
       - configure Mail, Messages, or browser sync
       - install a password manager
       - copy SSH keys, dotfiles, or a Keychain across from your account
       - run 'gh auth login'

     Every one of those is something a CI job could then read. The account is
     the security boundary; these are the things that would put holes in it.

     Install the toolchain the fleet contract promises while you are signed
     in — Xcode, and 'brew install xcodegen' (plus xcbeautify if any
     repository's workflow calls it). Workflows no longer install these per
     job, so the host owes them.

  ── 3. Mint tokens ───────────────────────────── (back on THIS account)

         ${script_dir}/mint-fleet-tokens.sh

     This is the awkward bit made easy. Minting a registration token needs a
     GitHub credential, and '$ACCOUNT' must never hold one — so the credential
     stays here and only short-lived, single-use tokens cross over.

     It reads which repositories to register from your fleet file:

         ${FLEET_FILE}

     one owner/repo per line (see fleet.example). That list stays out of the
     repository on purpose — it is public, and an inventory of which private
     repositories run on which machine is not something to publish.

     The script checks each one really is private, mints a token per
     repository, and prints a ready-to-paste block.

  ── 4. Paste and register ──────────────────── (Terminal as '$ACCOUNT')

     Paste the block. It clones this repository (public, so no credential
     needed), registers one runner per repository — a runner serves exactly
     one — installs them as launchd services, runs the audit, and schedules
     that audit weekly.

     Tokens expire about an hour after minting, so do steps 3 and 4 together.

  Then, back here, remove the credential a job could otherwise steal:

      gh auth logout --hostname github.com
EOF

printf '\n'
ok "Account ready. Start with FileVault above."
