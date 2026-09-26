#!/bin/bash
# Read-only machine health report for heavy local builds and agent runs.
#
# Prints the known build-speed killers on this machine (see
# docs/superpowers/specs/2026-08-11-local-build-speed-design.md and the
# "Agent-driven runs" rules in CLAUDE.md): load vs cores, swap pressure,
# the top CPU consumers, Docker containers, live Claude sessions with their
# age and directory, and orphaned test subprocesses. It only reports —
# cleanup order and decisions stay with the human (sessions -> containers
# -> Docker restart). The last line is a one-word verdict an agent can
# check before dispatching more work: "HEALTH: ok" or "HEALTH: overloaded".
set -uo pipefail

overloaded=0

echo "== load =="
CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
LOAD1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
echo "load(1m): ${LOAD1:-?} on ${CORES} cores"
if [ -n "${LOAD1:-}" ] && awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{exit !(l > 3*c)}'; then
    echo "  -> load above 3x cores"
    overloaded=1
fi

echo "== memory =="
sysctl vm.swapusage 2>/dev/null || echo "sysctl unavailable"
# Swap stays allocated long after pressure is gone, so the verdict keys on
# the kernel's free-memory level (the figure `memory_pressure` prints).
FREE_PCT=$(sysctl -n kern.memorystatus_level 2>/dev/null || true)
echo "free memory: ${FREE_PCT:-?}%"
if [ -n "$FREE_PCT" ] && [ "$FREE_PCT" -lt 15 ]; then
    echo "  -> free memory below 15%"
    overloaded=1
fi

echo "== top cpu =="
ps -Ao pcpu,etime,comm -r 2>/dev/null | sed -n '2,9p' |
    awk '{n=split($3,a,"/"); printf "%6s%%  up %-12s %s\n", $1, $2, a[n]}'

echo "== docker =="
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker ps --format '{{.Names}}	{{.Status}}'
else
    echo "docker not running"
fi

echo "== claude sessions =="
# -a: macOS pgrep otherwise hides its own ancestors (the calling session).
PIDS=$(pgrep -ax claude 2>/dev/null || true)
echo "live claude processes: $(echo "$PIDS" | grep -c . || true)"
for p in $PIDS; do
    CWD=$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    printf "  pid %-6s up %-12s %s\n" "$p" "$(ps -o etime= -p "$p" | tr -d ' ')" "${CWD:-?}"
done

echo "== orphaned test subprocesses =="
# A test stub whose test binary is gone gets reparented to launchd (PPID 1)
# and keeps running from the Go test temp dir.
ORPHANS=$(ps -Ao pid,ppid,etime,command 2>/dev/null |
    awk '$2 == 1 && $0 ~ /\/T\/Test[A-Za-z0-9_]+/' | cut -c1-160)
if [ -n "$ORPHANS" ]; then
    echo "$ORPHANS"
else
    echo "none"
fi

if [ "$overloaded" -eq 1 ]; then
    echo "HEALTH: overloaded"
else
    echo "HEALTH: ok"
fi
exit 0
