#!/bin/bash

# Install a weekly host audit as a launchd LaunchAgent, run as the account
# that owns the runners.
#
# This used to be a scheduled GitHub Actions workflow. It cannot be, any more:
# auditing the host means running ON the host, and this repository is public —
# so it must not touch the fleet. That is the same rule the audit itself
# enforces, and a project that broke it to check whether anyone else was
# breaking it would be a poor advertisement.
#
# Running locally is a better fit anyway. The audit inspects accounts,
# FileVault, keychains and runner registrations; none of that needs GitHub,
# and a machine that has drifted out of policy should not depend on CI being
# healthy in order to say so.
#
# Run this while signed in as the CI account.

set -uo pipefail

LABEL="com.github.actions.runner-audit"
DAY=1          # Monday
HOUR=3
MINUTE=17
uninstall=false

usage() {
    /bin/cat <<'EOF'
Usage: install-audit-schedule.sh [options]

Options:
  --label NAME    launchd label (default: com.github.actions.runner-audit).
  --day N         Weekday, 0=Sunday (default: 1, Monday).
  --hour N        Hour, 24h (default: 3).
  --minute N      Minute (default: 17).
  --uninstall     Remove the agent and its plist.
  -h, --help      Show this help.

Run as the account that owns the runners, NOT as an administrator and NOT with
sudo — a LaunchAgent belongs to the user whose runners it is auditing.

Output goes to ~/Library/Logs/runner-audit.log. A failing audit is a
maintenance alert, not a reason to relax a check.
EOF
}

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
info() { printf '  %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label)     LABEL="${2:?--label needs a value}"; shift 2 ;;
        --day)       DAY="${2:?--day needs a value}"; shift 2 ;;
        --hour)      HOUR="${2:?--hour needs a value}"; shift 2 ;;
        --minute)    MINUTE="${2:?--minute needs a value}"; shift 2 ;;
        --uninstall) uninstall=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[ "$(/usr/bin/uname -s)" = "Darwin" ] || { bad "macOS only."; exit 1; }

plist="$HOME/Library/LaunchAgents/${LABEL}.plist"
log_file="$HOME/Library/Logs/runner-audit.log"
script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
audit="${script_dir}/audit-runner-host.sh"

if $uninstall; then
    step "Removing the scheduled audit"
    /bin/launchctl bootout "gui/$(/usr/bin/id -u)/${LABEL}" 2>/dev/null || true
    if [ -f "$plist" ]; then
        /bin/rm -f "$plist"
        ok "Removed $plist"
    else
        info "No plist at $plist — nothing to remove."
    fi
    exit 0
fi

step "Checks"

if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    bad "Do not run this as root. A LaunchAgent belongs to the user whose runners it audits."
    exit 1
fi

if /usr/bin/id -Gn "$(/usr/bin/id -un)" | /usr/bin/grep -qw admin; then
    printf '  \033[33mWARN\033[0m  You are an administrator (%s).\n' "$(/usr/bin/id -un)"
    info "The audit should be scheduled on the CI account, which is the one"
    info "whose isolation it checks. Continuing anyway."
fi

if [ ! -x "$audit" ]; then
    bad "audit-runner-host.sh not found or not executable at $audit"
    exit 1
fi
ok "Found $audit"

step "Writing the agent"

/bin/mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

/bin/cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${audit}</string>
        <string>--all-runners</string>
        <string>--check-visibility</string>
        <string>--check-updates</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key><integer>${DAY}</integer>
        <key>Hour</key><integer>${HOUR}</integer>
        <key>Minute</key><integer>${MINUTE}</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${log_file}</string>
    <key>StandardErrorPath</key>
    <string>${log_file}</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF

if ! /usr/bin/plutil -lint "$plist" >/dev/null 2>&1; then
    bad "Generated plist is malformed — not loading it."
    exit 1
fi
ok "Wrote $plist"

# bootout first so re-running this is idempotent rather than an error.
/bin/launchctl bootout "gui/$(/usr/bin/id -u)/${LABEL}" 2>/dev/null || true
if /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$plist" 2>/dev/null; then
    ok "Loaded ${LABEL}"
else
    bad "Could not load the agent. Check: launchctl print gui/$(/usr/bin/id -u)/${LABEL}"
    exit 1
fi

step "Done"

/bin/cat <<EOF
    Runs weekly (weekday ${DAY}, ${HOUR}:${MINUTE}), logging to:

        ${log_file}

    Run it now to see the current state:

        ${audit} --all-runners --check-visibility --check-updates

    Remove it with: $(/usr/bin/basename "${BASH_SOURCE[0]}") --uninstall
EOF
