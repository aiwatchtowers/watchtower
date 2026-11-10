#!/bin/bash
# Sets up the owner's Mac as Watchtower's self-hosted CI (see README.md next
# to this file): a standard macOS user `ci` and four GitHub Actions runners
# under it, each a LaunchAgent in ci's GUI session —
#
#   ~ci/actions-runner-swift      label wt-swift    (Swift Test only)
#   ~ci/actions-runner-general-N  label wt-general  (every other job), N = 1..3
#
# .github/workflows/ci.yml sends jobs here only while these runners are online
# (scripts/ci-pick-runner.sh); otherwise CI runs on GitHub-hosted runners.
#
# Run it as yourself (not root) with `gh` signed in as a repository admin; it
# asks for your sudo password. Safe to run again: it creates what is missing,
# rewrites each runner's PATH and environment, and restarts the runners.
#
# Usage: scripts/ci-runner/setup-mac-runner.sh [--uninstall] [--repo OWNER/NAME]
#            [--xcode /Applications/Xcode.app] [--allow-open-home]
#
#   --uninstall        stop, unregister and delete the four runners (the ci
#                      user and its caches stay; the script prints how to
#                      remove the user)
#   --repo             repository the runners serve (default aiwatchtowers/watchtower)
#   --xcode            the Xcode the jobs use, through DEVELOPER_DIR (default
#                      /Applications/Xcode.app); your own xcode-select stays
#   --allow-open-home  go ahead although your home folder is readable by
#                      other users (by default the script stops: the ci user
#                      could read your ~/.config/watchtower and the live database)
#
# Compatible with bash 3.2 (macOS).
set -euo pipefail

REPO="aiwatchtowers/watchtower"
CI_USER="ci"
XCODE_APP="/Applications/Xcode.app"
ALLOW_OPEN_HOME=0
UNINSTALL=0

# actions/runner release (osx-arm64). The checksum is the one in the
# release notes (<!-- BEGIN SHA osx-arm64 -->); the runner updates itself
# after registration, so a newer release needs no change here.
RUNNER_VERSION="2.338.2"
RUNNER_SHA256="25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"

# name:label — the folder is actions-runner-<name>, the runner wt-mac-<name>.
# Runner names show in public job logs: never the host name.
INSTANCES="swift:wt-swift general-1:wt-general general-2:wt-general general-3:wt-general"

die() {
    echo "setup-mac-runner: $*" >&2
    exit 1
}
step() { echo "==> $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
    --uninstall) UNINSTALL=1 ;;
    --repo)
        [ $# -ge 2 ] || die "--repo needs a value"
        REPO=$2
        shift
        ;;
    --xcode)
        [ $# -ge 2 ] || die "--xcode needs a value"
        XCODE_APP=$2
        shift
        ;;
    --allow-open-home) ALLOW_OPEN_HOME=1 ;;
    -h | --help)
        sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
        exit 0
        ;;
    *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done

[ "$(uname -s)" = Darwin ] || die "macOS only"
[ "$(uname -m)" = arm64 ] || die "Apple silicon only (the runner download is osx-arm64)"
[ "$(id -u)" -ne 0 ] || die "run it as yourself, not with sudo"
command -v gh >/dev/null || die "gh is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not signed in (gh auth login)"

# Commands as the ci user, with its own HOME.
as_ci() { sudo -u "$CI_USER" -H "$@"; }

# in_dir_as_ci <dir> <command...>: runs it as ci inside <dir>, which you may
# not be allowed to enter yourself.
in_dir_as_ci() {
    local dir=$1
    shift
    # shellcheck disable=SC2016 # expanded by the inner bash, not here
    as_ci /bin/bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

ci_home() {
    dscl . -read "/Users/$CI_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
}

# A one-time token from GitHub (registration-token or remove-token).
runner_token() {
    gh api -X POST "repos/$REPO/actions/runners/$1" --jq .token
}

# runner_config <dir> <token> <config.sh args...>: the token travels in the
# environment (ACTIONS_RUNNER_INPUT_TOKEN), never on a command line that
# `ps` shows to other users.
runner_config() {
    local dir=$1 token=$2
    shift 2
    # shellcheck disable=SC2016 # expanded by the inner bash, not here
    ACTIONS_RUNNER_INPUT_TOKEN=$token sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN \
        -u "$CI_USER" -H /bin/bash -c 'cd "$1" && shift && exec ./config.sh "$@"' _ "$dir" "$@"
}

# The plist svc.sh installed for a runner folder, if any.
service_plist() {
    local dir=$1
    if sudo test -f "$dir/.service"; then
        sudo cat "$dir/.service"
    fi
}

gui_session() { sudo launchctl print "gui/$1" >/dev/null 2>&1; }

uninstall() {
    local home uid entry name dir plist token=""
    home=$(ci_home)
    [ -n "$home" ] || die "no user $CI_USER"
    uid=$(id -u "$CI_USER")
    for entry in $INSTANCES; do
        name=${entry%%:*}
        dir="$home/actions-runner-$name"
        sudo test -d "$dir" || continue
        step "removing $dir"
        plist=$(service_plist "$dir")
        if [ -n "$plist" ]; then
            sudo launchctl bootout "gui/$uid" "$plist" 2>/dev/null || true
            sudo rm -f "$plist" "$dir/.service"
        fi
        if sudo test -f "$dir/.runner"; then
            [ -n "$token" ] || token=$(runner_token remove-token)
            runner_config "$dir" "$token" remove ||
                echo "   could not unregister wt-mac-$name; remove it under Settings → Actions → Runners"
        fi
        sudo rm -rf "$dir"
    done
    echo
    echo "Runners removed. The $CI_USER user and its caches are still there; to delete them:"
    echo "  sudo sysadminctl -deleteUser $CI_USER"
}

ensure_user() {
    if ! id "$CI_USER" >/dev/null 2>&1; then
        step "creating the standard user $CI_USER (type its new password when asked)"
        sudo sysadminctl -addUser "$CI_USER" -fullName "Watchtower CI" -password -
    fi
    if dseditgroup -o checkmember -m "$CI_USER" admin >/dev/null 2>&1; then
        die "$CI_USER is an administrator; CI must run as a standard user"
    fi
    if [ -z "$(ci_home)" ] || ! sudo test -d "$(ci_home)"; then
        sudo createhomedir -c -u "$CI_USER" >/dev/null
    fi
}

# Jobs run your branches' code as ci: your own files must be out of its reach.
check_owner_home() {
    local mode
    mode=$(stat -f %Lp "$HOME")
    if [ $((8#$mode & 8#077)) -ne 0 ]; then
        if [ "$ALLOW_OPEN_HOME" -eq 1 ]; then
            echo "warning: $HOME is mode $mode; the $CI_USER user can read parts of it"
        else
            die "$HOME is mode $mode, so the $CI_USER user can read parts of it (your
~/.config/watchtower, the live database). Close it and run again:
  chmod 700 \"\$HOME\"
or pass --allow-open-home to go ahead anyway."
        fi
    fi
}

ensure_tools() {
    command -v brew >/dev/null || die "Homebrew is required (swiftlint comes from it)"
    if ! command -v swiftlint >/dev/null; then
        step "installing swiftlint (Homebrew, as you: $CI_USER cannot write there)"
        brew install swiftlint
    fi
    [ -d "$XCODE_APP/Contents/Developer" ] || die "no Xcode at $XCODE_APP (see --xcode)"
    step "accepting the Xcode license and installing its first-launch packages"
    sudo env DEVELOPER_DIR="$XCODE_APP/Contents/Developer" xcodebuild -license accept
    sudo env DEVELOPER_DIR="$XCODE_APP/Contents/Developer" xcodebuild -runFirstLaunch
}

# The runner reads PATH from .path and extra variables from .env at start.
write_runner_env() {
    local dir=$1 path=$2
    printf '%s\n' "$path" | as_ci tee "$dir/.path" >/dev/null
    printf 'LANG=en_US.UTF-8\nDEVELOPER_DIR=%s\n' "$XCODE_APP/Contents/Developer" |
        as_ci tee "$dir/.env" >/dev/null
}

download_runner() {
    local home=$1 tarball
    tarball="$home/actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz"
    if ! as_ci test -f "$tarball"; then
        step "downloading actions/runner $RUNNER_VERSION" >&2
        as_ci curl -fsSL -o "$tarball.part" "$RUNNER_URL"
        as_ci mv "$tarball.part" "$tarball"
    fi
    if ! as_ci shasum -a 256 "$tarball" | grep -q "^$RUNNER_SHA256 "; then
        as_ci rm -f "$tarball"
        die "the runner download does not match its checksum (deleted; run again)"
    fi
    echo "$tarball"
}

install() {
    check_owner_home
    ensure_user
    ensure_tools

    local home uid brew_prefix runner_path tarball entry name label dir plist token=""
    home=$(ci_home)
    uid=$(id -u "$CI_USER")
    brew_prefix=$(brew --prefix)
    runner_path="$brew_prefix/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    tarball=$(download_runner "$home")

    for entry in $INSTANCES; do
        name=${entry%%:*}
        label=${entry#*:}
        dir="$home/actions-runner-$name"
        if ! as_ci test -f "$dir/.runner"; then
            step "registering wt-mac-$name ($label)"
            as_ci mkdir -p "$dir"
            as_ci tar xzf "$tarball" -C "$dir"
            [ -n "$token" ] || token=$(runner_token registration-token)
            runner_config "$dir" "$token" --unattended --replace \
                --url "https://github.com/$REPO" --name "wt-mac-$name" \
                --labels "$label" --work _work
        fi
        write_runner_env "$dir" "$runner_path"
        if ! as_ci test -f "$dir/.service"; then
            in_dir_as_ci "$dir" ./svc.sh install >/dev/null
        fi
        plist=$(service_plist "$dir")
        if gui_session "$uid"; then
            sudo launchctl bootout "gui/$uid" "$plist" 2>/dev/null || true
            sudo launchctl bootstrap "gui/$uid" "$plist"
            echo "   wt-mac-$name started"
        fi
    done

    echo
    if gui_session "$uid"; then
        echo "All four runners are running in $CI_USER's session."
    else
        echo "Runners installed. They start when $CI_USER logs in: log in as $CI_USER once"
        echo "(Fast User Switching), then switch back to your account without logging out."
    fi
    echo "Keep the Mac awake on power while it serves CI:  sudo pmset -c sleep 0"
    echo "The rest of the checklist (token secret, fork approvals) is in scripts/ci-runner/README.md."
}

sudo -v || die "sudo is required"
if [ "$UNINSTALL" -eq 1 ]; then
    uninstall
else
    install
fi
