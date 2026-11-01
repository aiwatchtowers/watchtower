#!/bin/bash
# Tests for scripts/relay-interop-kit-hub.sh's refusals (relay client Phase 3
# Task 13): a missing or wrong argument, a relay dir that is not a checkout, a
# bad RELAY_INTEROP_PORT, a held port and a port something already answers on.
# No stand, no build: `lsof`, `curl`, `npx`, `go`, `make` and `node` are stubs
# on PATH that record every call, and each refusal must come before any of
# them builds or starts anything. Starts no process of its own.
#
# Task 14 adds the CI mode (RELAY_INTEROP_CI=1) and WATCHTOWER_CHECKOUT: the
# summary line `relay-interop: passed=N skipped=M failed=K` (last line of
# stdout, once, on success and failure), exit 1 when no test passed or failed,
# and the refusal of a bad checkout. Those cases run the whole script against
# stubs that fake the stand (see setup_run).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/../relay-interop-kit-hub.sh"

FAILURES=0
note_fail() {
	echo "FAIL: $1"
	FAILURES=$((FAILURES + 1))
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# setup <case>: a fake relay checkout and the stubs under $WORK_DIR/<case>;
# LSOF_HOLDER (lsof's listener line) and CURL_ANSWERS=1 (/healthz answers)
# pick the port's state. Sets C (the case dir).
setup() {
	C="$WORK_DIR/$1"
	mkdir -p "$C/relay/worker/node_modules/wrangler" "$C/stub"
	echo '{}' >"$C/relay/worker/package.json"
	echo '{}' >"$C/relay/worker/wrangler.jsonc"
	: >"$C/calls"
	local tool
	for tool in npx go make node npm openssl; do
		printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\nexit 0\n' "$tool" "$C" >"$C/stub/$tool"
	done
	cat >"$C/stub/lsof" <<EOF
#!/bin/bash
[ -n "\${LSOF_HOLDER:-}" ] || exit 1
echo "COMMAND PID USER"
echo "\$LSOF_HOLDER"
EOF
	cat >"$C/stub/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> '$C/calls'
[ "\${CURL_ANSWERS:-}" = 1 ]
EOF
	chmod +x "$C/stub/"*
}

# run_sut [env...] -- [args...]: runs the script with the stubs first on PATH;
# sets RC and OUT.
run_sut() {
	local envs=()
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		envs+=("$1")
		shift
	done
	shift
	OUT="$(env PATH="$C/stub:$PATH" ${envs[@]+"${envs[@]}"} bash "$SUT" "$@" 2>&1 </dev/null)"
	RC=$?
}

# expect <case> <rc> <text>: the exit code, the message, and nothing built or started.
expect() {
	[ "$RC" -eq "$2" ] || note_fail "$1: exit $RC, want $2 ($OUT)"
	case "$OUT" in
	*"$3"*) ;;
	*) note_fail "$1: output lacks '$3': $OUT" ;;
	esac
	if grep -qE '^(npx|go|make|node|npm|openssl) ' "$C/calls"; then
		note_fail "$1: built or started something: $(tr '\n' ';' <"$C/calls")"
	fi
}

setup no-arg
run_sut --
expect no-arg 2 "usage:"

setup two-args
run_sut -- "$C/relay" extra
expect two-args 2 "usage:"

setup empty-arg
run_sut -- ""
expect empty-arg 2 "usage:"

setup missing-checkout
run_sut -- "$C/no-such-relay"
expect missing-checkout 1 "does not exist"

setup not-a-worker
rm "$C/relay/worker/wrangler.jsonc"
run_sut -- "$C/relay"
expect not-a-worker 1 "is not the relay's worker directory"

setup bad-port
run_sut RELAY_INTEROP_PORT=80a -- "$C/relay"
expect bad-port 2 "RELAY_INTEROP_PORT is not a port number"

setup port-out-of-range
run_sut RELAY_INTEROP_PORT=70000 -- "$C/relay"
expect port-out-of-range 2 "RELAY_INTEROP_PORT is not a port number"

setup held-port
run_sut "LSOF_HOLDER=workerd 4242 owner" RELAY_INTEROP_PORT=18998 -- "$C/relay"
expect held-port 1 "port 18998 is held by workerd (pid 4242)"

setup answering-port
run_sut CURL_ANSWERS=1 RELAY_INTEROP_PORT=18998 -- "$C/relay"
expect answering-port 1 "something already answers on http://127.0.0.1:18998"

# ---- CI mode (Task 14) ----

# setup_run <case>: setup plus a fake Watchtower checkout ($C/wt) and stubs
# that fake the stand: npx "starts" (touches $C/started, records its pid, sleeps),
# curl answers /healthz once it has started and 400 to the /dev probe, make and go
# print $C/make.out / $C/go.out and exit MAKE_RC / GO_RC (the real runs only).
setup_run() {
	setup "$1"
	mkdir -p "$C/wt/WatchtowerKit/Sources/WatchtowerRelayProto" "$C/wt/internal/hub/transport/relay"
	: >"$C/wt/Makefile"
	echo "0000000000000000000000000000000000000000 pin" >"$C/wt/WatchtowerKit/Sources/WatchtowerRelayProto/VERSION"
	echo "0000000000000000000000000000000000000000 pin" >"$C/wt/internal/hub/transport/relay/VERSION"
	: >"$C/make.out"
	: >"$C/go.out"
	printf '#!/bin/bash\necho $$ > "%s/stand.pid"\ntouch "%s/started"\nexec sleep 300\n' "$C" "$C" >"$C/stub/npx"
	# The build steps (go test -run '^$', make without the stand's URL) always succeed.
	printf '#!/bin/bash\ncat "%s/make.out"\n[ -n "${WATCHTOWER_RELAY_INTEROP_URL:-}" ] || exit 0\nexit "${MAKE_RC:-0}"\n' "$C" >"$C/stub/make"
	printf '#!/bin/bash\ncat "%s/go.out"\ncase " $* " in *" -v "*) exit "${GO_RC:-0}" ;; esac\nexit 0\n' "$C" >"$C/stub/go"
	printf '#!/bin/bash\necho abc\n' >"$C/stub/openssl"
	printf '#!/bin/bash\ncase " $* " in *" -w "*) echo 400; exit 0 ;; esac\n[ -e "%s/started" ]\n' "$C" >"$C/stub/curl"
}

# xc <tests> <skipped> <failures>: an XCTest total line.
xc() {
	local i
	for ((i = 0; i < ${4:-$3}; i++)); do
		printf "Test Case '-[T t%d]' failed (0.1 seconds).\n" "$i"
	done
	printf '\t Executed %s tests, with %s tests skipped and %s failures (0 unexpected) in 0.1 (0.1) seconds\n' "$1" "$2" "$3"
}

# run_ci [env...] -- [args...]: a CI-mode run of the whole script; stdout and
# stderr are kept apart. Sets RC, OUT (stdout) and ERR (stderr).
run_ci() {
	local envs=()
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		envs+=("$1")
		shift
	done
	shift
	OUT="$(env PATH="$C/stub:$PATH" RELAY_INTEROP_CI=1 WATCHTOWER_CHECKOUT="$C/wt" RELAY_INTEROP_PORT=18997 \
		${envs[@]+"${envs[@]}"} bash "$SUT" "$@" 2>"$C/err" </dev/null)"
	RC=$?
	ERR="$(cat "$C/err")"
}

# expect_summary <case> <rc> <counts>: the exit code, and the summary line as
# the last line of stdout, exactly once, and the stand's process gone.
expect_summary() {
	[ "$RC" -eq "$2" ] || note_fail "$1: exit $RC, want $2 ($ERR)"
	[ "${OUT##*$'\n'}" = "relay-interop: $3" ] || note_fail "$1: last stdout line is not '$3': $OUT"
	[ "$(printf '%s\n' "$OUT" | grep -c '^relay-interop: passed=')" -eq 1 ] || note_fail "$1: summary not printed exactly once: $OUT"
	if [ -e "$C/stand.pid" ] && kill -0 "$(cat "$C/stand.pid")" 2>/dev/null; then
		note_fail "$1: the stand process is still alive"
	fi
}

setup_run ci-zero
run_ci -- "$C/relay"
expect_summary ci-zero 1 "passed=0 skipped=0 failed=0"
case "$ERR" in *"no test ran"*) ;; *) note_fail "ci-zero: no 'no test ran' message: $ERR" ;; esac

setup_run ci-all-skipped
xc 1 1 0 >"$C/make.out"
echo "--- SKIP: TestInterop_KitPhone (0.00s)" >"$C/go.out"
run_ci -- "$C/relay"
expect_summary ci-all-skipped 1 "passed=0 skipped=2 failed=0"

setup_run ci-pass
{ xc 3 1 0; xc 3 1 0; } >"$C/make.out"
printf '%s\n' "=== RUN   TestInterop_KitPhone" "--- PASS: TestInterop_KitPhone (1.20s)" "    --- PASS: TestInterop_KitPhone/sub (0.10s)" "PASS" >"$C/go.out"
run_ci -- "$C/relay"
expect_summary ci-pass 0 "passed=3 skipped=1 failed=0"

setup_run ci-go-fails
xc 2 0 0 >"$C/make.out"
echo "--- FAIL: TestInterop_KitPhone (1.20s)" >"$C/go.out"
run_ci GO_RC=1 -- "$C/relay"
expect_summary ci-go-fails 1 "passed=2 skipped=0 failed=1"

setup_run ci-kit-fails
xc 2 0 1 >"$C/make.out"
echo "--- PASS: TestInterop_KitPhone (1.20s)" >"$C/go.out"
run_ci MAKE_RC=1 -- "$C/relay"
expect_summary ci-kit-fails 1 "passed=2 skipped=0 failed=1"

# A refusal still ends with the summary line and keeps its own exit code.
setup_run ci-usage
run_ci --
expect_summary ci-usage 2 "passed=0 skipped=0 failed=0"

setup_run ci-bad-port
run_ci RELAY_INTEROP_PORT=80a -- "$C/relay"
expect_summary ci-bad-port 2 "passed=0 skipped=0 failed=0"

# WATCHTOWER_CHECKOUT must be a Watchtower checkout.
setup_run bad-checkout
rm "$C/wt/Makefile"
run_ci -- "$C/relay"
expect_summary bad-checkout 1 "passed=0 skipped=0 failed=0"
case "$ERR" in *"is not a Watchtower checkout"*) ;; *) note_fail "bad-checkout: no refusal message: $ERR" ;; esac
[ ! -e "$C/started" ] || note_fail "bad-checkout: started the stand"

setup_run missing-checkout-dir
run_ci WATCHTOWER_CHECKOUT="$C/nowhere" -- "$C/relay"
expect_summary missing-checkout-dir 1 "passed=0 skipped=0 failed=0"

# Without CI mode: no summary line, and a run with no counted test is not an error.
setup_run no-ci
OUT="$(env PATH="$C/stub:$PATH" WATCHTOWER_CHECKOUT="$C/wt" RELAY_INTEROP_PORT=18997 bash "$SUT" "$C/relay" 2>/dev/null </dev/null)"
RC=$?
[ "$RC" -eq 0 ] || note_fail "no-ci: exit $RC, want 0"
case "$OUT" in *"relay-interop: passed="*) note_fail "no-ci: printed a summary: $OUT" ;; esac

# A TERM while the run hangs (a cancelled or timed-out CI job): the stand and the
# run are killed, the partial output reaches stderr, and the summary is still
# the last line of stdout with a non-zero exit.
setup_run term-mid-run
echo "--- PASS: TestInterop_KitPhone (1.20s)" >"$C/go.out"
printf '#!/bin/bash\necho "partial output from make"\n[ -n "${WATCHTOWER_RELAY_INTEROP_URL:-}" ] || exit 0\necho $$ > "%s/make.pid"\ntouch "%s/make.started"\nexec sleep 300\n' "$C" "$C" >"$C/stub/make"
env PATH="$C/stub:$PATH" RELAY_INTEROP_CI=1 WATCHTOWER_CHECKOUT="$C/wt" RELAY_INTEROP_PORT=18997 \
	bash "$SUT" "$C/relay" >"$C/out" 2>"$C/err" </dev/null &
SUT_PID=$!
for _ in $(seq 1 100); do
	[ -e "$C/make.started" ] && break
	sleep 0.1
done
[ -e "$C/make.started" ] || note_fail "term-mid-run: the run never started"
kill -TERM "$SUT_PID" 2>/dev/null
wait "$SUT_PID"
RC=$?
OUT="$(cat "$C/out")"
ERR="$(cat "$C/err")"
[ "$RC" -ne 0 ] || note_fail "term-mid-run: exit 0 after TERM"
expect_summary term-mid-run "$RC" "passed=1 skipped=0 failed=0"
case "$ERR" in *"partial output from make"*) ;; *) note_fail "term-mid-run: the run's output is not on stderr: $ERR" ;; esac
if kill -0 "$(cat "$C/make.pid")" 2>/dev/null; then
	note_fail "term-mid-run: the test run is still alive"
fi

if [ "$FAILURES" -ne 0 ]; then
	echo "test-relay-interop-kit-hub: $FAILURES failure(s)"
	exit 1
fi
echo "test-relay-interop-kit-hub: ok"
