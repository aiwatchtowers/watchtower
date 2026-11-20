#!/bin/bash
# Daily trim of the CI user's shared build caches (see README.md, "Cache trim").
# Runs as the `ci` user from a LaunchDaemon that setup-mac-runner.sh installs.
#
# Deletes cache FILES not modified for more than a day: Go refreshes an
# entry's mtime when it uses one older than an hour, so anything older than a
# day is unused. Files only, never directories, so a job that is building
# right now at worst misses one entry and rebuilds it.
#
# Usage: trim-ci-caches.sh   (HOME must be the ci user's home)
set -euo pipefail

HOME_DIR=${HOME:?HOME is not set}
[ "$HOME_DIR" != "/" ] || {
    echo "trim-ci-caches: HOME is /" >&2
    exit 1
}
LOG="$HOME_DIR/Library/Logs/ci-cache-trim.log"
MAX_LOG_LINES=500

mkdir -p "$HOME_DIR/Library/Logs"

# trim <dir>: deletes files older than a day under <dir>, logs the size.
trim() {
    local dir=$1 before after
    if [ ! -d "$dir" ]; then
        echo "$(date '+%F %T') skip $dir (absent)"
        return
    fi
    before=$(du -sk "$dir" | awk '{print $1}')
    find "${dir:?}" -type f -mtime +1 -delete
    after=$(du -sk "$dir" | awk '{print $1}')
    echo "$(date '+%F %T') trimmed $dir: $((before / 1024)) MB -> $((after / 1024)) MB"
}

{
    trim "$HOME_DIR/Library/Caches/go-build"
    trim "$HOME_DIR/Library/Caches/golangci-lint"
} >>"$LOG" 2>&1

# Keep the log bounded.
if [ "$(wc -l <"$LOG")" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
