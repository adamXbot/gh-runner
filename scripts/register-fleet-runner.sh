#!/bin/bash

# Register one self-hosted Actions runner against one repository, refusing to
# do it for a public repository.
#
# Registration is the earliest point at which the fleet's central rule can be
# enforced, and it is the cheapest place to catch a mistake: a workflow gate
# fails a job, but a runner bound to the wrong repository is a standing
# invitation that nobody looks at again. So the visibility check happens here,
# before the token is even minted.
#
# The rule: self-hosted runners serve PRIVATE repositories only. A public
# repository accepts pull requests from anyone, a pull request is a proposal to
# run the author's code, and this machine is not reset between jobs. Public
# repositories also get free Actions minutes — so binding one to owned hardware
# takes on the entire risk in exchange for nothing.
#
# A runner serves exactly one repository, so a host covering several
# repositories gets several installations side by side. That is why this script
# takes a directory as well as a repository.

set -uo pipefail

repository=""
runner_dir=""
runner_name=""
labels="repo-ci"
runner_version=""
supplied_token=""

usage() {
    /bin/cat <<'EOF'
Usage: register-fleet-runner.sh --repository OWNER/REPO --dir PATH [options]

Required:
  --repository OWNER/REPO   Repository to bind this runner to. Must be private.
  --dir PATH                Runner installation directory. Created if missing.

Options:
  --token TOKEN     A one-time registration token minted elsewhere. With this,
                    the GitHub CLI is not needed and never consulted — which is
                    the point: the CI account must not hold a GitHub login, and
                    this is how it registers without one. Use
                    mint-fleet-tokens.sh from the administrator account to
                    produce a ready-to-paste block of these commands.
  --name NAME       Runner name as it appears in GitHub. Defaults to the
                    directory's basename. Deliberately NOT the hostname:
                    the runner name is printed in every job log, and a
                    hostname is a detail those logs do not need.
  --labels CSV      Extra labels beyond the implicit self-hosted/macOS/ARM64
                    set (default: repo-ci). Use release-signing ONLY on a
                    runner in its own account that runs no pull request code.
  --runner-version V  Actions runner release to download (default: latest).
  -h, --help        Show this help.

Two ways to run this, and they differ in which account you are in:

  From the CI account, with --token (recommended). Nothing here needs a
  GitHub credential, so the account that runs jobs never holds one. The
  registration token is short-lived (about an hour) and single-use.

  From the ADMINISTRATOR account, without --token, letting it mint the token
  through 'gh'. Convenient for a one-off, but then the runner directory
  belongs to the wrong user unless you are careful — and log gh out after:

      gh auth logout --hostname github.com

The audit script FAILs a host where a CI job can reach a GitHub CLI login, and
it is right to.

Note that the repository-visibility check below does NOT need a credential
either, so the private-repositories-only rule is enforced identically in both
modes.
EOF
}

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
info() { printf '  %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repository)     repository="${2:?--repository needs a value}"; shift 2 ;;
        --token)          supplied_token="${2:?--token needs a value}"; shift 2 ;;
        --dir)            runner_dir="${2:?--dir needs a value}"; shift 2 ;;
        --name)           runner_name="${2:?--name needs a value}"; shift 2 ;;
        --labels)         labels="${2:?--labels needs a value}"; shift 2 ;;
        --runner-version) runner_version="${2:?--runner-version needs a value}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$repository" ] || [ -z "$runner_dir" ]; then
    bad "--repository and --dir are both required."
    usage >&2
    exit 2
fi

if [[ ! "$repository" =~ ^[^/]+/[^/]+$ ]]; then
    bad "--repository must be OWNER/REPO, got '$repository'."
    exit 2
fi

[ -n "$runner_name" ] || runner_name="$(/usr/bin/basename "$runner_dir")"

step "Checking repository visibility"

# Unauthenticated on purpose: GitHub answers 404 rather than 403 for a
# repository the caller cannot see, so a 200 means "readable by the entire
# internet" — exactly the state this host must not be bound to. Asking without
# a credential also means the answer cannot be skewed by whatever access the
# operator happens to hold.
http_status="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' \
    --max-time 15 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${repository}" 2>/dev/null || true)"

case "$http_status" in
    200)
        bad "'$repository' is PUBLIC."
        info ""
        info "Refusing to register. A public repository accepts pull requests from"
        info "anyone, and this machine keeps its disk between jobs. Public"
        info "repositories also get free Actions minutes, so there is nothing to"
        info "save here — leave it on a GitHub-hosted runner."
        exit 1
        ;;
    404)
        ok "'$repository' is not publicly readable."
        ;;
    *)
        bad "Could not determine visibility of '$repository' (HTTP ${http_status:-no response})."
        info "Refusing to guess. Check the network and the repository name, then retry."
        exit 1
        ;;
esac

step "Checking prerequisites"

if [ -n "$supplied_token" ]; then
    # The whole point of this mode: no GitHub credential is consulted, so the
    # account that runs jobs never holds one.
    ok "Using a supplied registration token; the GitHub CLI is not needed."
else
    if ! command -v gh >/dev/null 2>&1; then
        bad "The GitHub CLI ('gh') is required to mint a registration token."
        info "Either install it, or pass --token with a token minted elsewhere"
        info "(see mint-fleet-tokens.sh, run from the administrator account)."
        exit 1
    fi
    if ! gh auth status --hostname github.com >/dev/null 2>&1; then
        bad "'gh' is not authenticated."
        info "From the CI account this is expected and correct — it must not hold a"
        info "GitHub login. Pass --token instead; mint-fleet-tokens.sh on the"
        info "administrator account prints ready-to-paste commands."
        exit 1
    fi
    ok "GitHub CLI is authenticated."
fi

if /usr/bin/id -Gn "$(/usr/bin/id -un)" | /usr/bin/grep -qw admin; then
    printf '  \033[33mWARN\033[0m  Registering as administrator account '\''%s'\''.\n' "$(/usr/bin/id -un)"
    info "The runner must RUN as the unprivileged CI account. Register into a"
    info "directory that account owns, and start the service as that account."
fi

step "Preparing $runner_dir"

if [ -f "$runner_dir/.runner" ]; then
    bad "'$runner_dir' already holds a configured runner. Remove it first (./config.sh remove) or pick another directory."
    exit 1
fi

/bin/mkdir -p "$runner_dir" || { bad "Could not create $runner_dir"; exit 1; }

if [ ! -x "$runner_dir/config.sh" ]; then
    step "Downloading the Actions runner"

    if [ -z "$runner_version" ]; then
        # Plain curl, not `gh api`: actions/runner is public, and this path has
        # to work from the CI account, which holds no GitHub credential.
        runner_version="$(/usr/bin/curl -fsSL --max-time 20 \
            -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/actions/runner/releases/latest" 2>/dev/null \
            | /usr/bin/jq -r '.tag_name // empty' \
            | /usr/bin/sed 's/^v//')"
    fi
    if [ -z "$runner_version" ]; then
        bad "Could not determine the latest runner version. Pass --runner-version."
        exit 1
    fi

    arch="arm64"
    [ "$(/usr/bin/uname -m)" = "x86_64" ] && arch="x64"
    tarball="actions-runner-osx-${arch}-${runner_version}.tar.gz"
    url="https://github.com/actions/runner/releases/download/v${runner_version}/${tarball}"

    info "Runner ${runner_version} (${arch})"

    # Download to disk and verify before extracting — never pipe a tarball
    # straight into tar. The digest is published in the release notes.
    if ! /usr/bin/curl -fsSL --retry 3 -o "${runner_dir}/${tarball}" "$url"; then
        bad "Download failed: $url"
        exit 1
    fi

    # Captured, then parsed. Ending this pipeline in `head -1` lets head close
    # the pipe, gh take SIGPIPE, and pipefail hand back an empty digest — at
    # which point the script would fall through to "no SHA-256 found" and
    # install an unverified tarball. Flaky verification is worse than none,
    # because it looks like verification.
    # The release notes list each asset as:
    #
    #   - actions-runner-osx-arm64-X.Y.Z.tar.gz <!-- BEGIN SHA osx-arm64 -->8e88...<!-- END SHA osx-arm64 -->
    #
    # so the digest follows the filename on the same line, inside an HTML
    # comment — not the `<sha>  <file>` layout shasum produces. Match the
    # line by filename, then take the only 64-hex string on it. (The download
    # instructions elsewhere in the notes mention the same filename but carry
    # no digest, so they contribute nothing.)
    # `jq -r '.body'` is load-bearing, not decoration: the raw JSON carries the
    # release notes as ONE line with escaped newlines, so grepping it directly
    # matches the whole blob and hands back whichever digest happens to come
    # first — the Windows one. Decoding to real lines is what makes "the line
    # naming this tarball" mean anything.
    release_body="$(/usr/bin/curl -fsSL --max-time 20 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/actions/runner/releases/tags/v${runner_version}" 2>/dev/null \
        | /usr/bin/jq -r '.body // empty' || true)"
    expected_sha="$(printf '%s\n' "$release_body" \
        | /usr/bin/grep -F -- "$tarball" \
        | /usr/bin/grep -Eo '[a-f0-9]{64}' \
        | /usr/bin/awk 'NR==1')"

    if [ -n "$expected_sha" ]; then
        actual_sha="$(/usr/bin/shasum -a 256 "${runner_dir}/${tarball}" | /usr/bin/awk '{print $1}')"
        if [ "$expected_sha" != "$actual_sha" ]; then
            bad "SHA-256 mismatch for ${tarball}."
            info "expected $expected_sha"
            info "got      $actual_sha"
            /bin/rm -f "${runner_dir}/${tarball}"
            exit 1
        fi
        ok "SHA-256 verified against the published release notes."
    else
        printf '  \033[33mWARN\033[0m  No SHA-256 found in the release notes; the download could not be verified.\n'
    fi

    /usr/bin/tar -xzf "${runner_dir}/${tarball}" -C "$runner_dir" || { bad "Extraction failed."; exit 1; }
    /bin/rm -f "${runner_dir}/${tarball}"
    ok "Runner extracted to $runner_dir"
fi

step "Registering"

if [ -n "$supplied_token" ]; then
    token="$supplied_token"
    ok "Using the supplied registration token."
else
    # Shape-checked, not emptiness-checked: on an error `gh api --jq` returns
    # the whole error body on stdout, so a 404 reads as a long non-empty
    # "token" and sails past `[ -z ... ]`.
    token="$(gh api --method POST "repos/${repository}/actions/runners/registration-token" --jq '.token' 2>/dev/null)"
    if ! printf '%s' "$token" | /usr/bin/grep -Eq '^[A-Za-z0-9_-]{20,}$'; then
        bad "Could not mint a registration token for '$repository'."
        if [ "$(gh api "repos/${repository}" --jq '.permissions.admin' 2>/dev/null)" = "false" ]; then
            info "You do not administer this repository. Minting needs admin —"
            info "have someone who administers ${repository%%/*} mint one and pass it with --token."
        fi
        exit 1
    fi
    ok "Minted a one-time registration token."
fi

info "Name:   $runner_name"
info "Labels: $labels"

# --unattended so this cannot block on a prompt; --replace so re-running after
# a failed attempt is not a manual cleanup job.
if ! (cd "$runner_dir" && ./config.sh \
        --url "https://github.com/${repository}" \
        --token "$token" \
        --name "$runner_name" \
        --labels "$labels" \
        --unattended \
        --replace); then
    bad "Runner configuration failed."
    if [ -n "$supplied_token" ]; then
        info "Registration tokens expire about an hour after they are minted, and"
        info "are single-use. If this one is stale, mint a fresh set from the"
        info "administrator account: ./scripts/mint-fleet-tokens.sh"
    fi
    exit 1
fi

ok "Runner registered to $repository."

step "Next"

/bin/cat <<EOF
  Start it as the CI account (not as an administrator, and not with sudo):

      cd "$runner_dir" && ./run.sh          # foreground
      cd "$runner_dir" && ./svc.sh install && ./svc.sh start   # launchd service

  Then verify the host:

      ./scripts/audit-runner-host.sh --all-runners --check-visibility

  And, if you registered from an administrator account, remove the credential
  a CI job would otherwise be able to steal:

      gh auth logout --hostname github.com
EOF
