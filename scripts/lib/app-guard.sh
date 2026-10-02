# shellcheck shell=bash
# Shared helpers for replacing an app bundle that may be in use. Sourced by
# scripts/build-app.sh, scripts/app-swap.sh and scripts/app-install.sh; defines
# functions and one constant only, so sourcing it has no side effects.
#
# Why a guard at all: replacing the files beneath a live process breaks it.
# A rewritten binary invalidates its code signature (Security.framework/TLS
# then fails with `SecPolicyCreateSSL error: 0`), and a swapped bundle makes
# the running app lazily load dylibs, resources, mlx.metallib or the bundled
# CLI from the NEW build. So a directory is only ever replaced while nothing
# executes from it — and nothing here ever quits or kills the app to get
# there (it may be recording a meeting; scripting a quit would also raise an
# Automation TCC prompt). The owner quits it; the scripts wait or defer.

# Written into the staging dir as the very last step of a successful
# build-app.sh run; app-swap.sh refuses to promote a staging dir without it
# (a failed build leaves a half-built staging dir behind).
# shellcheck disable=SC2034  # used by the scripts that source this file
STAGED_BUILD_MARKER=".build-complete"

# BEGIN live-process-guard (extracted verbatim by scripts/tests/test-build-app-guard.sh)
# running_from <dir> — prints the command line of every process executing from
# <dir>/ (empty output: nothing runs there). Returns 2 when the process list
# cannot be read: callers must treat that as "in use" (fail closed).
# awk matches the WHOLE LINE by literal prefix: `ps -axo command=` emits no
# leading whitespace, so the executable path always starts at position 1 and an
# argv that merely MENTIONS <dir> in a later token can never match there. The
# match is index()/literal rather than a regex because paths carry regex
# metacharacters ('+' in worktree names); matching $0 rather than $1 also keeps
# a <dir> containing a space from being truncated at the field split. The
# trailing slash keeps a sibling '<dir>-other' out.
# `awk -v` processes backslash escapes in p — irrelevant for macOS paths, which
# do not realistically contain backslashes.
# Accepted limitation: a process launched via a RELATIVE argv (./build/watchtower)
# is not matched, since ps reports argv[0] as typed. Every primary consumer (the
# app bundle, the make targets, the daemon spawn) launches from an absolute path.
# The explicit `|| return 2` (not set -e) is load-bearing: callers run this in
# `$(...)` and in `||` contexts, where errexit does not apply.
running_from() {
    local ps_snapshot
    ps_snapshot=$(ps -axo command=) || return 2
    printf '%s\n' "$ps_snapshot" | awk -v p="$1/" 'index($0, p) == 1' || return 2
}
# END live-process-guard

# wait_until_free <dir> — blocks until nothing runs from <dir>/, polling every
# second for up to WAIT_TIMEOUT seconds (default 600). Asks the owner to quit
# the app once; never quits or kills it. Returns 0 when free, 1 on timeout,
# 2 when the process list cannot be read (fail closed).
wait_until_free() {
    local dir="$1"
    local timeout="${WAIT_TIMEOUT:-600}"
    case "$timeout" in
        '' | *[!0-9]*)
            echo "ERROR: WAIT_TIMEOUT must be a whole number of seconds, got '$timeout'" >&2
            return 1
            ;;
    esac
    local deadline=$((SECONDS + timeout))
    local announced=false
    local running
    while :; do
        running=$(running_from "$dir") || {
            echo "ERROR: could not read the process list (ps failed) — refusing to touch $dir" >&2
            return 2
        }
        if [ -z "$running" ]; then
            return 0
        fi
        if ! $announced; then
            echo "==> Watchtower is running from $dir:"
            printf '%s\n' "$running"
            echo "==> Quit Watchtower (⌘Q) — waiting up to ${timeout}s for it to exit..."
            announced=true
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "ERROR: timed out after ${timeout}s waiting for these processes to exit:" >&2
            printf '%s\n' "$running" >&2
            return 1
        fi
        sleep 1
    done
}

# replace_dir <new> <dest> <aside> — moves <new> into place at <dest>: an
# existing <dest> is renamed to <aside> first and deleted after, so <dest> is
# missing only between two renames. The caller has already checked that nothing
# runs from <dest> or <new>, and removed any stale <aside>. Returns 1 on
# failure, with the previous <dest> moved back when possible and the message
# saying where it is otherwise. Explicit error handling throughout: callers use
# `replace_dir ... || exit 1`, where errexit does not apply.
replace_dir() {
    local new="$1" dest="$2" aside="$3"
    if [ -e "$dest" ] && ! mv "$dest" "$aside"; then
        echo "ERROR: could not move $dest aside — nothing was replaced" >&2
        return 1
    fi
    # Re-check: had <dest> reappeared, `mv` would nest <new> inside it.
    if [ -e "$dest" ] || ! mv "$new" "$dest"; then
        if [ -e "$aside" ] && { [ -e "$dest" ] || ! mv "$aside" "$dest"; }; then
            echo "ERROR: could not move $new into $dest, nor restore the previous copy — it is at $aside" >&2
        else
            echo "ERROR: could not move $new into $dest — the previous copy (if any) is back in place" >&2
        fi
        return 1
    fi
    if ! rm -rf "$aside"; then
        echo "WARNING: replaced $dest, but could not delete the previous copy at $aside" >&2
    fi
}
