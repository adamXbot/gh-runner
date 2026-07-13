#!/bin/bash

# Audit the security boundary of an ordinary, non-signing macOS Actions runner.
# This script is intentionally read-only. It reports every finding before it exits.

set -uo pipefail

failures=0
warnings=0
runner_dir="${RUNNER_INSTALL_DIR:-}"
expected_repository=""
check_updates=false

usage() {
    /bin/cat <<'EOF'
Usage: audit-runner-host.sh [options]

Options:
  --runner-dir PATH              Actions runner installation directory. If omitted,
                                 discover it above GITHUB_WORKSPACE or use ~/actions-runner.
  --expected-repository SLUG     Expected owner/repository or GitHub repository URL.
  --check-updates                Ask macOS Software Update whether updates are pending.
  -h, --help                     Show this help.
EOF
}

pass() {
    printf 'PASS  %s\n' "$1"
}

warn() {
    warnings=$((warnings + 1))
    printf 'WARN  %s\n' "$1"
}

fail() {
    failures=$((failures + 1))
    printf 'FAIL  %s\n' "$1"
}

require_value() {
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        printf 'Missing value for %s\n' "$1" >&2
        usage >&2
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --runner-dir)
            require_value "$@"
            runner_dir="$2"
            shift 2
            ;;
        --expected-repository)
            require_value "$@"
            expected_repository="$2"
            shift 2
            ;;
        --check-updates)
            check_updates=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$(/usr/bin/uname -s)" != "Darwin" ]; then
    fail "Host is not macOS."
    printf '\n%d failure(s), %d warning(s).\n' "$failures" "$warnings"
    exit 1
fi

current_user="$(/usr/bin/id -un)"
current_uid="$(/usr/bin/id -u)"

if [ "$current_uid" -eq 0 ]; then
    fail "Runner is executing as root."
else
    pass "Runner is executing as the unprivileged account '$current_user'."
fi

is_admin=false
for group in $(/usr/bin/id -Gn "$current_user"); do
    if [ "$group" = "admin" ]; then
        is_admin=true
        break
    fi
done
if $is_admin; then
    fail "Account '$current_user' belongs to the macOS admin group."
else
    pass "Account '$current_user' is not a macOS administrator."
fi

home_owner="$(/usr/bin/stat -f '%Su' "$HOME" 2>/dev/null || true)"
if [ "$home_owner" = "$current_user" ]; then
    pass "The runner account owns its home directory."
else
    fail "Home directory '$HOME' is owned by '${home_owner:-an unknown account}'."
fi

icloud_accounts="$(/usr/bin/defaults read MobileMeAccounts Accounts 2>/dev/null || true)"
icloud_compact="$(printf '%s' "$icloud_accounts" | /usr/bin/tr -d '[:space:]')"
if [ -z "$icloud_compact" ] || [ "$icloud_compact" = "()" ]; then
    pass "No iCloud account is configured for this macOS account."
else
    fail "An iCloud account appears to be configured for '$current_user'."
fi

private_key_count=0
if [ -d "$HOME/.ssh" ]; then
    while IFS= read -r key_file; do
        if /usr/bin/head -n 1 "$key_file" 2>/dev/null \
            | /usr/bin/grep -Eq '^-----BEGIN ([A-Z0-9]+ |OPENSSH )?PRIVATE KEY-----'; then
            private_key_count=$((private_key_count + 1))
            fail "SSH private key found at $key_file."
        fi
    done < <(/usr/bin/find "$HOME/.ssh" -type f -print 2>/dev/null)
fi
if [ "$private_key_count" -eq 0 ]; then
    pass "No SSH private keys were found in ~/.ssh."
fi

gh_path="$(command -v gh 2>/dev/null || true)"
if [ -n "$gh_path" ] && "$gh_path" auth status --hostname github.com >/dev/null 2>&1; then
    fail "A long-lived GitHub CLI credential is available to ordinary PR jobs."
else
    pass "No authenticated GitHub CLI session is available to ordinary PR jobs."
fi

password_manager_data=false
for data_path in \
    "$HOME/Library/Application Support/1Password" \
    "$HOME/Library/Application Support/Bitwarden" \
    "$HOME/Library/Application Support/Dashlane" \
    "$HOME/Library/Application Support/LastPass" \
    "$HOME/.config/Bitwarden"; do
    if [ -e "$data_path" ]; then
        password_manager_data=true
        fail "Password-manager account data found at $data_path."
    fi
done
if ! $password_manager_data; then
    pass "No common password-manager account data was found."
fi

identity_output="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
if printf '%s\n' "$identity_output" | /usr/bin/grep -Eqi \
    'Apple Distribution|Developer ID Application|Mac App Distribution|3rd Party Mac Developer Application|iPhone Distribution'; then
    fail "A distribution signing identity is accessible to the ordinary CI account."
else
    pass "No distribution signing identity is accessible to the ordinary CI account."
fi

filevault_status="$(/usr/bin/fdesetup status 2>&1 || true)"
if printf '%s\n' "$filevault_status" | /usr/bin/grep -Eq '^FileVault is On'; then
    pass "FileVault is enabled."
elif printf '%s\n' "$filevault_status" | /usr/bin/grep -Eq '^FileVault is Off'; then
    fail "FileVault is disabled."
else
    fail "FileVault status could not be verified."
fi

discover_runner_dir() {
    local candidate="${GITHUB_WORKSPACE:-$PWD}"
    while [ "$candidate" != "/" ]; do
        if [ -f "$candidate/.runner" ] && [ -x "$candidate/bin/Runner.Listener" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        candidate="$(/usr/bin/dirname "$candidate")"
    done
    if [ -f "$HOME/actions-runner/.runner" ] \
        && [ -x "$HOME/actions-runner/bin/Runner.Listener" ]; then
        printf '%s\n' "$HOME/actions-runner"
        return 0
    fi
    return 1
}

if [ -z "$runner_dir" ]; then
    runner_dir="$(discover_runner_dir || true)"
fi

normalize_repository() {
    local value="$1"
    value="${value#https://github.com/}"
    value="${value#http://github.com/}"
    value="${value%/}"
    value="${value%.git}"
    printf '%s\n' "$value" | /usr/bin/tr '[:upper:]' '[:lower:]'
}

if [ -z "$runner_dir" ]; then
    fail "Could not locate the Actions runner installation. Pass --runner-dir."
elif [ ! -f "$runner_dir/.runner" ] || [ ! -x "$runner_dir/bin/Runner.Listener" ]; then
    fail "'$runner_dir' is not a configured Actions runner installation."
else
    pass "Found the Actions runner installation at $runner_dir."

    configured_url="$(/usr/bin/plutil -extract gitHubUrl raw -o - "$runner_dir/.runner" 2>/dev/null || true)"
    configured_repository="$(normalize_repository "$configured_url")"
    if [[ "$configured_url" != https://github.com/* ]] \
        || [[ ! "$configured_repository" =~ ^[^/]+/[^/]+$ ]]; then
        fail "Runner is not registered at repository scope (configured URL: ${configured_url:-unknown})."
    elif [ -n "$expected_repository" ] \
        && [ "$(normalize_repository "$expected_repository")" != "$configured_repository" ]; then
        fail "Runner targets '$configured_repository', not '$(normalize_repository "$expected_repository")'."
    else
        pass "Runner is registered only to repository '$configured_repository'."
    fi

    disable_update="$(/usr/bin/plutil -extract disableupdate raw -o - "$runner_dir/.runner" 2>/dev/null || true)"
    if [ "$disable_update" = "true" ]; then
        fail "Actions runner automatic updates are disabled."
    else
        pass "Actions runner automatic updates are enabled."
    fi

    runner_version="$($runner_dir/bin/Runner.Listener --version 2>/dev/null || true)"
    if [ -n "$runner_version" ]; then
        pass "Actions runner version: $runner_version."
    else
        warn "Could not read the installed Actions runner version."
    fi
fi

xcode_path="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
if [ -n "$xcode_path" ]; then
    xcode_version="$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/paste -sd ' ' - || true)"
    pass "Selected developer tools: ${xcode_version:-$xcode_path}."
else
    fail "No Xcode or Command Line Tools installation is selected."
fi

macos_version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
pass "macOS version: ${macos_version:-unknown}."

if $check_updates; then
    update_output="$(/usr/sbin/softwareupdate --list 2>&1)"
    update_status=$?
    if [ "$update_status" -ne 0 ]; then
        warn "Software Update could not complete its update check."
    elif printf '%s\n' "$update_output" | /usr/bin/grep -Eqi \
        'No new software available|No updates are available'; then
        pass "macOS Software Update reports no pending updates."
    else
        fail "macOS Software Update reports one or more pending updates."
    fi
else
    warn "Pending macOS/Xcode updates were not queried; rerun with --check-updates."
fi

warn "Keychain contents and Apple/password-manager sign-in state still require manual review."

printf '\n%d failure(s), %d warning(s).\n' "$failures" "$warnings"
if [ "$failures" -gt 0 ]; then
    exit 1
fi
