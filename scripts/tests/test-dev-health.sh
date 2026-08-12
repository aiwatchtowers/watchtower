#!/bin/bash
# Tests for scripts/dev-health.sh — a read-only reporter.
#
# Runs the real script with PATH pointing at stubbed docker/pgrep/sysctl
# binaries — no real Docker daemon, no real process list.
#
# Covers:
#   - all sections print their headers
#   - docker daemon unreachable (valid, degenerate) → "docker not running", exit 0
#   - script never exits non-zero (it is a report, not a gate)
#   - script contains no mutating docker/kill commands (read-only contract)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEV_HEALTH="$SCRIPT_DIR/../dev-health.sh"

FAILURES=0
note_fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

bash -n "$DEV_HEALTH" && echo "ok: bash -n" || note_fail "bash -n dev-health.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir "$WORK_DIR/bin"

# Stubs: docker that fails `info` (daemon down); pgrep finding 2 sessions;
# sysctl echoing a fixed swapusage line.
cat > "$WORK_DIR/bin/docker" <<'EOF'
#!/bin/bash
[ "$1" = "info" ] && exit 1
exit 0
EOF
cat > "$WORK_DIR/bin/pgrep" <<'EOF'
#!/bin/bash
printf '111\n222\n'
EOF
cat > "$WORK_DIR/bin/sysctl" <<'EOF'
#!/bin/bash
echo "vm.swapusage: total = 2048.00M  used = 100.00M  free = 1948.00M"
EOF
chmod +x "$WORK_DIR/bin/"*

OUT="$WORK_DIR/out.txt"
if PATH="$WORK_DIR/bin:$PATH" bash "$DEV_HEALTH" > "$OUT" 2>&1; then
    echo "ok: exit 0 with docker down"
else
    note_fail "dev-health.sh exited non-zero with docker down"
fi

for section in "== memory ==" "== docker ==" "== claude sessions =="; do
    grep -qF "$section" "$OUT" && echo "ok: section $section" || note_fail "missing section $section"
done
grep -q "docker not running" "$OUT" && echo "ok: docker-down message" || note_fail "missing docker-down message"
grep -q "vm.swapusage" "$OUT" && echo "ok: swapusage line" || note_fail "missing swapusage line"

# Read-only contract: no mutating commands anywhere in the script.
if grep -nE '(docker (rm|stop|kill|restart)|kill |pkill )' "$DEV_HEALTH"; then
    note_fail "dev-health.sh contains a mutating command"
else
    echo "ok: read-only"
fi

# Degenerate scenario: pgrep finds zero claude processes (prints nothing, exits 1 —
# the real `pgrep -f` behavior when nothing matches).
cat > "$WORK_DIR/bin/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$WORK_DIR/bin/pgrep"

OUT_ZERO="$WORK_DIR/out-zero.txt"
if PATH="$WORK_DIR/bin:$PATH" bash "$DEV_HEALTH" > "$OUT_ZERO" 2>&1; then
    echo "ok: exit 0 with zero claude processes"
else
    note_fail "dev-health.sh exited non-zero with zero claude processes"
fi
grep -q "live claude processes: 0" "$OUT_ZERO" && echo "ok: zero-process count" || note_fail "missing zero-process count"

[ "$FAILURES" -eq 0 ] || { echo "$FAILURES failure(s)"; exit 1; }
echo "all dev-health tests passed"
