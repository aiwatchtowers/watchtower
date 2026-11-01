#!/bin/bash
# Tests for scripts/relay-interop-kit.sh's CI mode (relay client Phase 3 Task 14):
# RELAY_INTEROP_CI=1 prints `relay-interop: passed=N skipped=M failed=K` as the
# last line of stdout, once, on success and failure; a run where no test passed
# or failed exits 1; WATCHTOWER_CHECKOUT must be a Watchtower checkout. The whole
# script runs against stubs that fake the stand: `npx` "starts" and sleeps,
# `curl` answers /healthz once it has started, `make` prints canned XCTest
# output. Every stub is on PATH; nothing real is built or started.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/../relay-interop-kit.sh"

FAILURES=0
note_fail() {
	echo "FAIL: $1"
	FAILURES=$((FAILURES + 1))
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# setup <case>: a fake relay checkout, a fake Watchtower checkout ($C/wt) and the
# stubs under $WORK_DIR/<case>. Sets C.
setup() {
	C="$WORK_DIR/$1"
	mkdir -p "$C/relay/worker/node_modules/wrangler" "$C/stub" \
		"$C/wt/WatchtowerKit/Sources/WatchtowerRelayProto"
	echo '{}' >"$C/relay/worker/package.json"
	echo '{}' >"$C/relay/worker/wrangler.jsonc"
	: >"$C/wt/Makefile"
	echo "0000000000000000000000000000000000000000 pin" >"$C/wt/WatchtowerKit/Sources/WatchtowerRelayProto/VERSION"
	: >"$C/make.out"
	printf '#!/bin/bash\necho $$ > "%s/stand.pid"\ntouch "%s/started"\nexec sleep 300\n' "$C" "$C" >"$C/stub/npx"
	printf '#!/bin/bash\ncat "%s/make.out"\nexit "${MAKE_RC:-0}"\n' "$C" >"$C/stub/make"
	printf '#!/bin/bash\necho abc\n' >"$C/stub/openssl"
	printf '#!/bin/bash\nexit 0\n' >"$C/stub/node"
	printf '#!/bin/bash\nexit 1\n' >"$C/stub/lsof"
	printf '#!/bin/bash\ncase " $* " in *" -w "*) echo 400; exit 0 ;; esac\n[ -e "%s/started" ]\n' "$C" >"$C/stub/curl"
	chmod +x "$C/stub/"*
}

# xc <tests> <skipped> <failures>: an XCTest total line.
xc() {
	printf '\t Executed %s tests, with %s tests skipped and %s failures (0 unexpected) in 0.1 (0.1) seconds\n' "$1" "$2" "$3"
}

# run_sut <ci 0|1> [env...] -- [args...]: stdout and stderr kept apart.
# Sets RC, OUT (stdout) and ERR (stderr).
run_sut() {
	local ci="$1" envs=()
	shift
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		envs+=("$1")
		shift
	done
	shift
	[ "$ci" = 1 ] && envs+=(RELAY_INTEROP_CI=1)
	OUT="$(env PATH="$C/stub:$PATH" WATCHTOWER_CHECKOUT="$C/wt" RELAY_INTEROP_PORT=18996 \
		${envs[@]+"${envs[@]}"} bash "$SUT" "$@" 2>"$C/err" </dev/null)"
	RC=$?
	ERR="$(cat "$C/err")"
}

# expect_summary <case> <rc> <counts>: the exit code, the summary line as the
# last line of stdout and only once, and the stand's process gone.
expect_summary() {
	[ "$RC" -eq "$2" ] || note_fail "$1: exit $RC, want $2 ($ERR)"
	[ "${OUT##*$'\n'}" = "relay-interop: $3" ] || note_fail "$1: last stdout line is not '$3': $OUT"
	[ "$(printf '%s\n' "$OUT" | grep -c '^relay-interop: passed=')" -eq 1 ] || note_fail "$1: summary not printed exactly once: $OUT"
	if [ -e "$C/stand.pid" ] && kill -0 "$(cat "$C/stand.pid")" 2>/dev/null; then
		note_fail "$1: the stand process is still alive"
	fi
}

setup ci-zero
run_sut 1 -- "$C/relay"
expect_summary ci-zero 1 "passed=0 skipped=0 failed=0"
case "$ERR" in *"no test ran"*) ;; *) note_fail "ci-zero: no 'no test ran' message: $ERR" ;; esac

setup ci-all-skipped
xc 4 4 0 >"$C/make.out"
run_sut 1 -- "$C/relay"
expect_summary ci-all-skipped 1 "passed=0 skipped=4 failed=0"

setup ci-pass
{ xc 5 2 0; xc 5 2 0; } >"$C/make.out"
run_sut 1 -- "$C/relay"
expect_summary ci-pass 0 "passed=3 skipped=2 failed=0"
case "$ERR" in *"Executed 5 tests"*) ;; *) note_fail "ci-pass: the test output is not on stderr: $ERR" ;; esac

setup ci-fail
xc 5 1 2 >"$C/make.out"
run_sut 1 MAKE_RC=1 -- "$C/relay"
expect_summary ci-fail 1 "passed=2 skipped=1 failed=2"

# A run that fails without a counted test failure still exits non-zero.
setup ci-build-error
echo "error: build failed" >"$C/make.out"
run_sut 1 MAKE_RC=1 -- "$C/relay"
expect_summary ci-build-error 1 "passed=0 skipped=0 failed=0"

# A refusal still ends with the summary line and keeps its own exit code.
setup ci-usage
run_sut 1 --
expect_summary ci-usage 2 "passed=0 skipped=0 failed=0"

setup ci-not-a-worker
rm "$C/relay/worker/wrangler.jsonc"
run_sut 1 -- "$C/relay"
expect_summary ci-not-a-worker 1 "passed=0 skipped=0 failed=0"

# WATCHTOWER_CHECKOUT must be a Watchtower checkout.
setup bad-checkout
rm "$C/wt/Makefile"
run_sut 1 -- "$C/relay"
expect_summary bad-checkout 1 "passed=0 skipped=0 failed=0"
case "$ERR" in *"is not a Watchtower checkout"*) ;; *) note_fail "bad-checkout: no refusal message: $ERR" ;; esac
[ ! -e "$C/started" ] || note_fail "bad-checkout: started the stand"

setup no-kit-dir
rm -r "$C/wt/WatchtowerKit"
run_sut 1 -- "$C/relay"
expect_summary no-kit-dir 1 "passed=0 skipped=0 failed=0"

setup missing-checkout-dir
run_sut 1 WATCHTOWER_CHECKOUT="$C/nowhere" -- "$C/relay"
expect_summary missing-checkout-dir 1 "passed=0 skipped=0 failed=0"

# Without CI mode: no summary line, and the tests' output stays on stdout.
setup no-ci
xc 2 0 0 >"$C/make.out"
run_sut 0 -- "$C/relay"
[ "$RC" -eq 0 ] || note_fail "no-ci: exit $RC, want 0 ($ERR)"
case "$OUT" in *"relay-interop: passed="*) note_fail "no-ci: printed a summary: $OUT" ;; esac
case "$OUT" in *"Executed 2 tests"*) ;; *) note_fail "no-ci: the test output is not on stdout: $OUT" ;; esac

if [ "$FAILURES" -ne 0 ]; then
	echo "test-relay-interop-kit: $FAILURES failure(s)"
	exit 1
fi
echo "test-relay-interop-kit: ok"
