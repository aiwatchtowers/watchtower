#!/bin/bash
# Daily trim of the CI user's shared build caches (see README.md, "Cache trim").
# Runs as the `ci` user from a LaunchDaemon that setup-mac-runner.sh installs;
# the daemon fires hourly and this script acts at most once a day, and only
# while no runner job is running.
#
# It mirrors Go's own cache trim: an entry is a file `<hash>-a` (or a
# directory `<hash>-d`, a cached executable) inside one of the two-hex-digit
# subdirectories, and it is judged by ITS OWN mtime, which Go refreshes when
# it uses the entry. An entry unused for more than a day goes; a `-d`
# directory goes whole (its inner file's mtime is never refreshed). Anything
# else in the cache (fuzz/, README, trim.txt) stays. golangci-lint's cache is
# a fork of Go's and has the same layout.
#
# Usage: trim-ci-caches.sh   (HOME must be the ci user's home)
set -uo pipefail

HOME_DIR=${HOME:?HOME is not set}
[ "$HOME_DIR" != "/" ] || {
    echo "trim-ci-caches: HOME is /" >&2
    exit 1
}
LOGDIR="$HOME_DIR/Library/Logs"
LOG="$LOGDIR/ci-cache-trim.log"
STAMP="$LOGDIR/ci-cache-trim.stamp"
MAX_LOG_LINES=500
MIN_INTERVAL=$((23 * 3600))

mkdir -p "$LOGDIR"
log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

cap_log() {
    if [ "$(wc -l <"$LOG")" -gt "$MAX_LOG_LINES" ]; then
        tail -n "$MAX_LOG_LINES" "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

job_running() { pgrep -u "$(id -u)" -f Runner.Worker >/dev/null 2>&1; }

# trim <dir>: removes the cache entries under <dir> unused for over a day,
# one two-hex-digit shard at a time, re-checking before each shard that no
# runner job has started meanwhile. Returns 0 when the whole cache was
# scanned and trimmed, 1 on an error, 2 when a job started (pass aborted).
trim() {
    local dir=$1 shard entry list removed=0 failed=0 size
    if [ ! -d "$dir" ]; then
        log "skip $dir (absent)"
        return 0
    fi
    list=$(mktemp "${TMPDIR:-/tmp}/ci-cache-trim.XXXXXX") || return 1
    for shard in "${dir:?}"/[0-9a-f][0-9a-f]; do
        [ -d "$shard" ] || continue
        if job_running; then
            rm -f -- "$list"
            log "aborted $dir: a job started (removed $removed entries so far)"
            return 2
        fi
        if ! find "$shard" -mindepth 1 -maxdepth 1 \( -name '*-a' -o -name '*-d' \) -mtime +1 >"$list" 2>/dev/null; then
            failed=1 # incomplete scan: whatever it listed still goes, but no stamp
        fi
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            # Only <dir>/<2 hex digits>/<hash>-a|-d; never anything else.
            case "$entry" in
            "$dir"/[0-9a-f][0-9a-f]/*-[ad]) ;;
            *) continue ;;
            esac
            if [ -d "$entry" ]; then
                rm -rf -- "${entry:?}" || failed=1
            else
                rm -f -- "${entry:?}" || failed=1
            fi
            removed=$((removed + 1))
        done <"$list"
    done
    rm -f -- "$list"
    size=$(du -sk "$dir" 2>/dev/null | awk '{print int($1 / 1024)}')
    log "trimmed $dir: removed $removed entries, now ${size:-?} MB"
    [ "$failed" -eq 0 ] || log "error: $dir was not fully scanned or trimmed"
    return "$failed"
}

now=$(date +%s)
last=$(stat -f %m "$STAMP" 2>/dev/null || echo 0)
if [ $((now - last)) -lt "$MIN_INTERVAL" ]; then
    exit 0
fi

if job_running; then
    log "skipped: job running"
    cap_log
    exit 0
fi

rc=0
for cache in go-build golangci-lint; do
    trim "$HOME_DIR/Library/Caches/$cache"
    case $? in
    0) ;;
    2) rc=1; break ;;
    *) rc=1 ;;
    esac
done
[ "$rc" -ne 0 ] || touch "$STAMP"
cap_log
exit 0
