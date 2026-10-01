#!/usr/bin/env bash
# Structural regression gate — the same check CI's blocking "Sentrux Quality
# Gate" job runs, MINUS the global god-file count.
#
# Why: `sentrux gate`'s god_file_count (fan-out > 15, whole tree) is not a
# property of the file being measured. Sentrux resolves an unresolved method
# call by BARE NAME to whichever file happens to declare a method of that
# name, so deleting a duplicated helper (or adding an unrelated one anywhere
# in the tree) can move the count by dozens with no real structural change —
# see docs/backlog/2026-09-28-sentrux-god-file-count-is-driven-by-name-based-
# method-resolution.md for the bisected proof, and scripts/god-files.sh's own
# header for the same story from the source-roster side. Owner decision
# 2026-09-29: stop blocking PRs on that specific metric here.
#
# Everything else `sentrux gate` checks — quality signal, coupling, import
# cycles, complex functions — still gates exactly as before: this script
# shells out to the real `sentrux gate` (so its actual thresholds/tolerances
# are used, not a reimplementation that could drift from them) and only
# reclassifies a failure whose SOLE cause is the god-file count as
# informational. `scripts/god-files.sh` — a committed roster of SOURCE files
# at fan-out > 30, tests excluded, reviewed one addition at a time — remains
# the real god-file protection and is unaffected by this script.
#
# Measures the COMMITTED tree only (git archive HEAD into a scratch copy),
# never the live working tree: untracked files and any uncommitted edits
# (yours or another session's, mid-checkout) can never leak into the
# verdict. CI's checkout has no local edits to diverge from anyway, so this
# is what CI should run too, not just a local convenience wrapper.
#
# Usage:
#   scripts/sentrux-gate.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v sentrux >/dev/null 2>&1; then
    echo "sentrux-gate: sentrux not found on PATH" >&2
    exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "sentrux-gate: jq not found on PATH" >&2
    exit 127
fi

BASELINE=".sentrux/baseline.json"
if [ ! -f "$BASELINE" ]; then
    echo "sentrux-gate: missing $BASELINE" >&2
    exit 1
fi

TMPDIR="$(mktemp -d)"
GATE_OUT="$(mktemp)"
cleanup() {
    rm -rf "$TMPDIR"
    rm -f "$GATE_OUT"
}
trap cleanup EXIT

# Tracked files at HEAD only — a scratch copy of exactly what CI would see,
# so untracked scratch files and uncommitted edits to tracked files (this
# checkout's or another session's) can't move the measurement either way.
git archive HEAD | (cd "$TMPDIR" && tar -x)

# The scratch copy carries its own copy of the committed baseline.json (part
# of the archive), so this is the real, authoritative gate comparison — same
# one CI has always run — just on a clean tree instead of the live one.
gate_rc=0
sentrux gate "$TMPDIR" >"$GATE_OUT" 2>&1 || gate_rc=$?

cat "$GATE_OUT"

if [ "$gate_rc" -eq 0 ]; then
    echo
    echo "✓ sentrux-gate: no structural regressions"
    exit 0
fi

# DEGRADED. Each specific reason is a two-space-indented "  ✗ <check>
# increased/degraded/dropped: old → new" line under the unindented "✗
# DEGRADED" summary — anchor on the indent so the summary line itself is
# never mistaken for a reason.
FAILURES="$(grep -E '^  ✗ ' "$GATE_OUT" || true)"
NON_GOD_FAILURES="$(printf '%s\n' "$FAILURES" | grep -vi 'god files' || true)"

if [ -n "$NON_GOD_FAILURES" ]; then
    echo
    echo "✗ sentrux-gate: structural regression (blocking):"
    printf '%s\n' "$NON_GOD_FAILURES" | sed 's/^/    /'
    exit 1
fi

if [ -z "$FAILURES" ]; then
    # sentrux exited non-zero but printed no reason line this script
    # recognizes — fail loudly instead of silently waving through whatever
    # it actually found (a future sentrux version changing its output is a
    # bug to notice, not a reason to pass).
    echo
    echo "✗ sentrux-gate: gate failed with no recognized '  ✗ ' line — treating as a regression, inspect the output above" >&2
    exit 1
fi

# Only the god-file count failed. Report the exact delta from the baseline
# fields (not the display line, which sentrux may round) but don't block.
sentrux gate --save "$TMPDIR" >/dev/null 2>&1
old_god="$(jq -r '.god_file_count' "$BASELINE")"
new_god="$(jq -r '.god_file_count' "$TMPDIR/$BASELINE")"

echo
echo "note: god files: ${old_god} → ${new_god} (not gating — see scripts/god-files.sh)"
echo "✓ sentrux-gate: no blocking structural regressions"
