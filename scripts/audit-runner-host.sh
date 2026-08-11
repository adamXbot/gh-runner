#!/bin/bash

# Audit the security boundary of an ordinary, non-signing macOS Actions runner.
# This script is intentionally read-only. It reports every finding before it exits.

set -uo pipefail

failures=0
warnings=0
runner_dir="${RUNNER_INSTALL_DIR:-}"
expected_repository=""
check_updates=false
check_visibility=false
declared_visibility=""
all_runners=false

usage() {
    /bin/cat <<'EOF'
Usage: audit-runner-host.sh [options]

Options:
  --runner-dir PATH              Actions runner installation directory. If omitted,
                                 discover it above GITHUB_WORKSPACE or use ~/actions-runner.
  --all-runners                  Audit every runner installation under $HOME instead of
                                 one. The fleet runs several (a runner serves a single
                                 repository), and they have to be checked together.
  --expected-repository SLUG     Expected owner/repository or GitHub repository URL.
  --visibility VALUE             Repository visibility as the workflow observed it.
                                 Fails unless "private". From CI, pass
                                 ${{ github.event.repository.private && 'private' || 'public' }}.
  --check-visibility             Ask github.com whether each bound repository is publicly
                                 visible, using an unauthenticated request (needs network,
                                 no credential — see the note below).
  --check-updates                Ask macOS Software Update whether updates are pending.
  -h, --help                     Show this help.

Why an unauthenticated request can answer "is this repository public":
GitHub answers 404 rather than 403 for a repository the caller cannot see, so
it never confirms a private repository's existence. That inverts neatly into
the check this host needs — 200 means the repository is readable by the entire
internet, which is exactly the state a self-hosted runner must not be bound to.
It also means the audit stays credential-free, which matters: this same script
FAILs the host when it finds a usable GitHub CLI login.
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
        --all-runners)
            all_runners=true
            shift
            ;;
        --expected-repository)
            require_value "$@"
            expected_repository="$2"
            shift 2
            ;;
        --visibility)
            require_value "$@"
            declared_visibility="$2"
            shift 2
            ;;
        --check-visibility)
            check_visibility=true
            shift
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

discover_all_runner_dirs() {
    # A runner serves exactly one repository, so a host that covers several
    # repositories has several installations side by side.
    /usr/bin/find "$HOME" -maxdepth 2 -name '.runner' -type f -print 2>/dev/null \
        | while IFS= read -r marker; do
            candidate="$(/usr/bin/dirname "$marker")"
            if [ -x "$candidate/bin/Runner.Listener" ]; then
                printf '%s\n' "$candidate"
            fi
        done
}

normalize_repository() {
    local value="$1"
    value="${value#https://github.com/}"
    value="${value#http://github.com/}"
    value="${value%/}"
    value="${value%.git}"
    printf '%s\n' "$value" | /usr/bin/tr '[:upper:]' '[:lower:]'
}

repository_is_public() {
    # Echoes public / not-public / unknown. See --help for why an
    # unauthenticated request is the right tool here.
    local slug="$1" status
    status="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' \
        --max-time 15 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${slug}" 2>/dev/null || true)"
    case "$status" in
        200) printf 'public\n' ;;
        404) printf 'not-public\n' ;;
        *)   printf 'unknown:%s\n' "${status:-no-response}" ;;
    esac
}

matched_expected_repository=false

audit_runner_install() {
    local dir="$1"

    if [ ! -f "$dir/.runner" ] || [ ! -x "$dir/bin/Runner.Listener" ]; then
        fail "'$dir' is not a configured Actions runner installation."
        return
    fi

    pass "Found the Actions runner installation at $dir."

    local configured_url configured_repository disable_update runner_version
    configured_url="$(/usr/bin/plutil -extract gitHubUrl raw -o - "$dir/.runner" 2>/dev/null || true)"
    configured_repository="$(normalize_repository "$configured_url")"
    if [[ "$configured_url" != https://github.com/* ]] \
        || [[ ! "$configured_repository" =~ ^[^/]+/[^/]+$ ]]; then
        fail "Runner is not registered at repository scope (configured URL: ${configured_url:-unknown})."
    elif [ -n "$expected_repository" ] \
        && [ "$(normalize_repository "$expected_repository")" = "$configured_repository" ]; then
        matched_expected_repository=true
        pass "Runner is registered only to repository '$configured_repository' (the expected one)."
    elif [ -n "$expected_repository" ] && ! $all_runners; then
        fail "Runner targets '$configured_repository', not '$(normalize_repository "$expected_repository")'."
    else
        # In --all-runners mode the other installations are siblings serving
        # other repositories, which is the normal shape of the fleet — a
        # runner serves exactly one repository. Whether the expected one was
        # found at all is reported once, after the loop.
        pass "Runner is registered only to repository '$configured_repository'."
    fi

    # The machine-side half of the fleet's central rule: self-hosted runners
    # are bound to private repositories only. A public repository accepts pull
    # requests from anyone, and this host is not reset between jobs.
    if $check_visibility && [[ "$configured_repository" =~ ^[^/]+/[^/]+$ ]]; then
        local visibility
        visibility="$(repository_is_public "$configured_repository")"
        case "$visibility" in
            public)
                fail "Repository '$configured_repository' is PUBLIC. A self-hosted runner must never be bound to a repository that accepts pull requests from strangers."
                ;;
            not-public)
                pass "Repository '$configured_repository' is not publicly readable."
                ;;
            *)
                warn "Could not determine whether '$configured_repository' is public (${visibility#unknown:})."
                ;;
        esac
    fi

    # config.sh snapshots the PATH of whatever shell registered the runner into
    # .path, and every job then runs with it. Register with `su ci-runner`
    # instead of `su - ci-runner` and you capture the ADMINISTRATOR's PATH —
    # including entries under their home, which this account cannot read.
    # Jobs then fail with EACCES on tool lookups, and worse, a readable entry
    # would silently hand CI the admin's binaries.
    if [ -f "$dir/.path" ]; then
        local foreign
        foreign="$(/usr/bin/tr ':' '\n' < "$dir/.path" 2>/dev/null \
            | /usr/bin/grep -E "^/Users/" \
            | /usr/bin/grep -v "^$HOME/" \
            | /usr/bin/grep -v "^/Users/Shared/" || true)"
        if [ -n "$foreign" ]; then
            fail "Runner PATH in $dir/.path points into another user's home:"
            while IFS= read -r entry; do
                [ -n "$entry" ] && printf '        %s\n' "$entry"
            done <<< "$foreign"
            printf '      Re-register from a clean login shell (su - ci-runner), or strip them:\n'
            printf '        tr ":" "\\n" < .path | grep -v "^/Users/OTHER" | paste -sd: - > .path.new && mv .path.new .path\n'
        else
            pass "Runner PATH contains no other user's home directory."
        fi
    fi

    disable_update="$(/usr/bin/plutil -extract disableupdate raw -o - "$dir/.runner" 2>/dev/null || true)"
    if [ "$disable_update" = "true" ]; then
        fail "Actions runner automatic updates are disabled for $dir."
    else
        pass "Actions runner automatic updates are enabled for $dir."
    fi

    runner_version="$("$dir/bin/Runner.Listener" --version 2>/dev/null || true)"
    if [ -n "$runner_version" ]; then
        pass "Actions runner version: $runner_version."
    else
        warn "Could not read the installed Actions runner version in $dir."
    fi
}

# Visibility as the calling workflow saw it. Cheap, needs no network, and
# catches the case the API probe cannot: a repository flipped to public
# between the audit's last run and this job.
if [ -n "$declared_visibility" ]; then
    if [ "$declared_visibility" = "private" ]; then
        pass "Calling workflow reports the repository is private."
    else
        fail "Calling workflow reports repository visibility '$declared_visibility'. Self-hosted runners are for private repositories only."
    fi
fi

if $all_runners; then
    runner_dirs=()
    while IFS= read -r found_dir; do
        [ -n "$found_dir" ] && runner_dirs+=("$found_dir")
    done < <(discover_all_runner_dirs)

    if [ "${#runner_dirs[@]}" -eq 0 ]; then
        fail "No Actions runner installations were found under $HOME."
    else
        pass "Found ${#runner_dirs[@]} Actions runner installation(s) under $HOME."
        for found_dir in "${runner_dirs[@]}"; do
            audit_runner_install "$found_dir"
        done

        if [ -n "$expected_repository" ]; then
            if $matched_expected_repository; then
                pass "A runner for '$(normalize_repository "$expected_repository")' is installed on this host."
            else
                fail "No runner on this host is registered to '$(normalize_repository "$expected_repository")'."
            fi
        fi
    fi
else
    if [ -z "$runner_dir" ]; then
        runner_dir="$(discover_runner_dir || true)"
    fi

    if [ -z "$runner_dir" ]; then
        fail "Could not locate the Actions runner installation. Pass --runner-dir."
    else
        audit_runner_install "$runner_dir"
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
