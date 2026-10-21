#!/bin/bash
# Tests for scripts/ci-dedupe-gate.sh (the CI `gate` job's dedupe step).
#
# `gh` is a stub first in PATH: `pr list` prints STUB_PR (FAIL → exits 1);
# each `run list` call takes the next ';'-separated entry of STUB_RUNS — a
# JSON array of runs ({conclusion, headBranch}), FAIL (exits 1) or raw text —
# keeps the runs on the --branch it was given and applies the gate's own
# --jq with jq. Polls are instant (DEDUPE_POLL_SECONDS=0).
#
# Covers:
#   - push to main, a pull_request event      → run, no gh call
#   - no open PR, PR conflicting              → run, no run lookup
#   - PR run found at once / on the 3rd poll  → skip
#   - mergeable UNKNOWN with a PR run         → skip
#   - PR run never appears                    → run after every poll
#   - gh pr list / gh run list fails          → run (fail-open)
#   - run list returns something not a count  → run, raw value logged
#   - only a cancelled PR run                 → run
#   - the PR run is on another branch         → run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../ci-dedupe-gate.sh"

FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

if ! bash -n "$GATE"; then
    echo "FAIL: ci-dedupe-gate.sh does not parse"
    exit 1
fi
if ! command -v jq >/dev/null; then
    echo "FAIL: jq is required by the gh stub"
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci-dedupe-gate-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$STUB_LOG"
case "$1 $2" in
"pr list")
    [ "$STUB_PR" = FAIL ] && exit 1
    echo "$STUB_PR"
    ;;
"run list")
    calls=$(grep -c '^gh run list' "$STUB_LOG")
    IFS=';' read -ra entries <<< "$STUB_RUNS"
    idx=$((calls - 1))
    [ "$idx" -ge "${#entries[@]}" ] && idx=$((${#entries[@]} - 1))
    entry=${entries[$idx]}
    [ "$entry" = FAIL ] && exit 1
    branch="" filter=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --branch) branch=$2; shift ;;
        --jq) filter=$2; shift ;;
        esac
        shift
    done
    if ! jq -e 'type == "array"' <<< "$entry" >/dev/null 2>&1; then
        echo "$entry"
        exit 0
    fi
    jq -c --arg b "$branch" '[.[] | select(.headBranch == $b) | {conclusion}]' <<< "$entry" | jq -r "$filter"
    ;;
esac
EOF
chmod +x "$TMP/bin/gh"

# gate <label> <event> <ref> <pr> <runs> <want run> <want run-list calls> [<want log text>]
gate() {
    local label=$1 out="$TMP/out" log="$TMP/log" stdout rc=0
    : > "$out"
    : > "$log"
    stdout=$(EVENT=$2 GITHUB_REF_NAME=$3 STUB_PR=$4 STUB_RUNS=$5 STUB_LOG=$log \
        GITHUB_OUTPUT=$out GITHUB_REPOSITORY=acme/repo GITHUB_SHA=abc123 \
        DEDUPE_POLL_SECONDS=0 PATH="$TMP/bin:$PATH" bash "$GATE" 2>&1) || rc=$?
    local got calls
    got=$(cat "$out")
    calls=$(grep -c '^gh run list' "$log" || true)
    if [ "$rc" -ne 0 ]; then
        note_fail "$label: exit $rc ($stdout)"
    elif [ "$got" != "run=$6" ]; then
        note_fail "$label: wrote '$got', want run=$6 ($stdout)"
    elif [ "$calls" -ne "$7" ]; then
        note_fail "$label: $calls run-list calls, want $7"
    elif [ -n "${8:-}" ] && [[ "$stdout" != *"$8"* ]]; then
        note_fail "$label: log '$stdout' lacks '$8'"
    else
        echo "ok: $label — $stdout"
    fi
}

HERE='[{"conclusion":"","headBranch":"feature/x"}]'
DONE='[{"conclusion":"success","headBranch":"feature/x"}]'
NONE='[]'

gate "push to main" push main MERGEABLE "$HERE" true 0
gate "pull_request event" pull_request feature/x MERGEABLE "$HERE" true 0
gate "no open PR" push feature/x "" "$HERE" true 0 "no open PR"
gate "conflicting PR" push feature/x CONFLICTING "$HERE" true 0 "conflicting"
gate "PR run found at once" push feature/x MERGEABLE "$HERE" false 1 "skipping"
gate "PR run on the 3rd poll" push feature/x MERGEABLE "$NONE;$NONE;$DONE" false 3 "skipping"
gate "mergeable unknown, PR run found" push feature/x UNKNOWN "$HERE" false 1 "skipping"
gate "PR run never appears" push feature/x MERGEABLE "$NONE" true 12 "no pull_request run"
gate "gh pr list fails" push feature/x FAIL "$HERE" true 0 "gh pr list failed"
gate "gh run list fails" push feature/x MERGEABLE FAIL true 1 "gh run list failed"
gate "run list returns no count" push feature/x MERGEABLE "oops" true 1 "returned 'oops'"
gate "only a cancelled PR run" push feature/x MERGEABLE '[{"conclusion":"cancelled","headBranch":"feature/x"}]' true 12 "no pull_request run"
gate "PR run on another branch" push feature/x MERGEABLE '[{"conclusion":"success","headBranch":"feature/y"}]' true 12 "no pull_request run"

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "all ci-dedupe-gate tests passed"
