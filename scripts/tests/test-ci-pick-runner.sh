#!/bin/bash
# Tests for scripts/ci-pick-runner.sh (the CI `gate` job's runner picker).
#
# `gh` is a stub first in PATH: `gh api` prints STUB_RUNNERS (FAIL → exits 1,
# HANG → sleeps past PICK_TIMEOUT) and logs the token it was given.
#
# Covers:
#   - push / workflow_dispatch / same-repo PR with both labels online → Mac
#   - fork PR, PR with no head repo, another event → cloud, no gh call
#   - no token                                   → cloud, no gh call
#   - gh fails, hangs, prints junk or JSON without a runner list → cloud
#   - no runner online, only offline runners    → cloud
#   - only wt-swift / only wt-general online    → that class alone on the Mac
#   - the token reaches gh as GH_TOKEN; the script always exits 0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PICK="$SCRIPT_DIR/../ci-pick-runner.sh"

FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

if ! bash -n "$PICK"; then
    echo "FAIL: ci-pick-runner.sh does not parse"
    exit 1
fi
if ! command -v jq >/dev/null; then
    echo "FAIL: jq is required by ci-pick-runner.sh"
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci-pick-runner-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
echo "gh $* token=$GH_TOKEN" >> "$STUB_LOG"
[ "$1" = api ] || exit 2
case "$STUB_RUNNERS" in
FAIL) exit 1 ;;
HANG) exec sleep 5 ;;
*) echo "$STUB_RUNNERS" ;;
esac
EOF
chmod +x "$TMP/bin/gh"
# A `timeout` for hosts without coreutils' (stock macOS), so HANG is covered
# everywhere; the script uses whichever is on PATH.
if ! command -v timeout >/dev/null; then
    cat > "$TMP/bin/timeout" <<'EOF'
#!/bin/bash
secs=$1; shift
"$@" & child=$!
( sleep "$secs"; kill "$child" 2>/dev/null ) & watcher=$!
wait "$child"; rc=$?
kill "$watcher" 2>/dev/null
exit "$rc"
EOF
    chmod +x "$TMP/bin/timeout"
fi

LINUX_CLOUD='"ubuntu-24.04"'
MACOS_CLOUD='"macos-26"'
GENERAL='["self-hosted","wt-general"]'
SWIFT='["self-hosted","wt-swift"]'

runner() { # name status label...
    local name=$1 status=$2 labels="" l
    shift 2
    for l in self-hosted macOS ARM64 "$@"; do
        labels="$labels${labels:+,}{\"name\":\"$l\"}"
    done
    printf '{"name":"%s","status":"%s","busy":false,"labels":[%s]}' "$name" "$status" "$labels"
}
list() {
    local IFS=,
    printf '{"total_count":%d,"runners":[%s]}' "$#" "$*"
}

BOTH=$(list "$(runner swift online wt-swift)" "$(runner general-1 online wt-general)" "$(runner general-2 offline wt-general)")
SWIFT_ONLY=$(list "$(runner swift online wt-swift)" "$(runner general-1 offline wt-general)")
GENERAL_ONLY=$(list "$(runner swift offline wt-swift)" "$(runner general-3 online wt-general)")
ALL_OFFLINE=$(list "$(runner swift offline wt-swift)" "$(runner general-1 offline wt-general)")
OTHER_LABEL=$(list "$(runner elsewhere online some-other-label)")
EMPTY=$(list)

# pick <label> <event> <head repo> <token> <runners> <want linux> <want macos> <want swift> <want gh calls> [<want log text>]
pick() {
    local label=$1 out="$TMP/out" log="$TMP/log" stdout rc=0
    : > "$out"
    : > "$log"
    stdout=$(EVENT=$2 HEAD_REPO=$3 RUNNER_STATUS_TOKEN=$4 STUB_RUNNERS=$5 STUB_LOG=$log \
        GITHUB_OUTPUT=$out GITHUB_REPOSITORY=acme/repo PICK_TIMEOUT=1 \
        PATH="$TMP/bin:$PATH" bash "$PICK" 2>&1) || rc=$?
    local want got calls
    want=$(printf 'linux=%s\nmacos=%s\nswift=%s' "$6" "$7" "$8")
    got=$(cat "$out")
    calls=$(grep -c '^gh ' "$log" || true)
    if [ "$rc" -ne 0 ]; then
        note_fail "$label: exit $rc ($stdout)"
    elif [ "$got" != "$want" ]; then
        note_fail "$label: wrote '$got', want '$want' ($stdout)"
    elif [ "$calls" -ne "$9" ]; then
        note_fail "$label: $calls gh calls, want $9"
    elif [ "$calls" -gt 0 ] && ! grep -q "token=$4\$" "$log"; then
        note_fail "$label: gh did not get the token as GH_TOKEN ($(cat "$log"))"
    elif [ -n "${10:-}" ] && [[ "$stdout" != *"${10}"* ]]; then
        note_fail "$label: log '$stdout' lacks '${10}'"
    else
        echo "ok: $label — ${stdout//$'\n'/ | }"
    fi
}

pick "push, both online" push "" tok "$BOTH" "$GENERAL" "$GENERAL" "$SWIFT" 1
pick "workflow_dispatch, both online" workflow_dispatch "" tok "$BOTH" "$GENERAL" "$GENERAL" "$SWIFT" 1
pick "same-repo PR, both online" pull_request acme/repo tok "$BOTH" "$GENERAL" "$GENERAL" "$SWIFT" 1
pick "fork PR" pull_request someone/repo tok "$BOTH" "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 0 "someone/repo"
pick "PR without a head repo" pull_request "" tok "$BOTH" "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 0 "unknown repository"
pick "another event" schedule "" tok "$BOTH" "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 0 "event schedule"
pick "no token" push "" "" "$BOTH" "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 0 "not set"
pick "gh fails" push "" tok FAIL "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 1 "listing the runners failed"
pick "gh hangs" push "" tok HANG "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 1 "listing the runners failed"
pick "junk output" push "" tok "<html>rate limited</html>" "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 1 "did not parse"
pick "JSON without a runner list" push "" tok '{"message":"Bad credentials"}' "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 1 "did not parse"
pick "no runners" push "" tok "$EMPTY" "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 1 "no runner online"
pick "all offline" push "" tok "$ALL_OFFLINE" "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 1 "no runner online"
pick "another label online" push "" tok "$OTHER_LABEL" "$LINUX_CLOUD" "$MACOS_CLOUD" "$MACOS_CLOUD" 1
pick "only wt-swift online" push "" tok "$SWIFT_ONLY" "$LINUX_CLOUD" "$MACOS_CLOUD" "$SWIFT" 1
pick "only wt-general online" push "" tok "$GENERAL_ONLY" "$GENERAL" "$GENERAL" "$MACOS_CLOUD" 1

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "all ci-pick-runner tests passed"
