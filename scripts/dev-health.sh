#!/bin/bash
# Read-only machine health report for heavy local builds.
#
# Prints the three known build-speed killers on this machine (see
# docs/superpowers/specs/2026-08-11-local-build-speed-design.md): swap
# pressure, Docker containers (leaked mcp containers pattern), and live
# Claude session processes. It only reports — cleanup order and decisions
# stay with the human (sessions -> containers -> Docker restart).
set -uo pipefail

echo "== memory =="
sysctl vm.swapusage 2>/dev/null || echo "sysctl unavailable"

echo "== docker =="
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker ps --format '{{.Names}}	{{.Status}}'
else
    echo "docker not running"
fi

echo "== claude sessions =="
COUNT=$(pgrep -f "claude" 2>/dev/null | wc -l | tr -d ' ')
echo "live claude processes: ${COUNT}"

exit 0
