# Shared by scripts/relay-interop-kit.sh and scripts/relay-interop-kit-hub.sh
# (relay client Phase 3 Task 14): the CI mode. Sourced, never run.
#
# RELAY_INTEROP_CI=1 makes a script
#   - non-interactive (stdin from /dev/null; the scripts never prompt),
#   - print exactly one line as the last line of its stdout, also on failure:
#       relay-interop: passed=N skipped=M failed=K
#     (everything else goes to stderr),
#   - exit non-zero on any failure and when no test ran (passed + failed is 0,
#     even if tests were skipped).
# The counts come from the test runners' own output (XCTest's "Executed N tests,
# with S tests skipped and K failures" line, `go test -v`'s top-level
# "--- PASS/SKIP/FAIL" lines), not from the scripts' exit codes. A run that
# failed without a test failing (a build error, a timeout) has failed=0 and a
# non-zero exit.

CI_MODE=0
[ "${RELAY_INTEROP_CI:-}" = 1 ] && CI_MODE=1
CI_PASSED=0
CI_SKIPPED=0
CI_FAILED=0

[ "$CI_MODE" = 1 ] && exec </dev/null

# ci_add_xctest <log>: adds the last "Executed N tests, with ..." line of an
# XCTest log (the run's grand total; Executed includes the skipped ones).
ci_add_xctest() {
	local line n s f p
	line="$(grep -E 'Executed [0-9]+ tests?, with ' "$1" 2>/dev/null | tail -n 1)"
	[ -n "$line" ] || return 0
	n="$(sed -E 's/.*Executed ([0-9]+) tests?, with.*/\1/' <<<"$line")"
	s=0
	case "$line" in
	*" skipped and "*) s="$(sed -E 's/.* with ([0-9]+) tests? skipped and.*/\1/' <<<"$line")" ;;
	esac
	f="$(sed -E 's/.* ([0-9]+) failures?.*/\1/' <<<"$line")"
	p=$((n - s - f))
	[ "$p" -ge 0 ] || p=0
	CI_PASSED=$((CI_PASSED + p))
	CI_SKIPPED=$((CI_SKIPPED + s))
	CI_FAILED=$((CI_FAILED + f))
}

# ci_add_go <log>: adds the top-level "--- PASS/SKIP/FAIL" lines of a
# `go test -v` log.
ci_add_go() {
	local p s f
	p="$(grep -c '^--- PASS' "$1" 2>/dev/null)" || true
	s="$(grep -c '^--- SKIP' "$1" 2>/dev/null)" || true
	f="$(grep -c '^--- FAIL' "$1" 2>/dev/null)" || true
	CI_PASSED=$((CI_PASSED + ${p:-0}))
	CI_SKIPPED=$((CI_SKIPPED + ${s:-0}))
	CI_FAILED=$((CI_FAILED + ${f:-0}))
}

# ci_exit <rc>: the scripts' only exit once their cleanup has run.
ci_exit() {
	local rc="$1"
	if [ "$CI_MODE" = 1 ]; then
		if [ $((CI_PASSED + CI_FAILED)) -eq 0 ] && [ "$rc" -eq 0 ]; then
			echo "relay-interop: no test ran (passed + failed is 0)" >&2
			rc=1
		fi
		printf 'relay-interop: passed=%d skipped=%d failed=%d\n' "$CI_PASSED" "$CI_SKIPPED" "$CI_FAILED"
	fi
	exit "$rc"
}

# ci_checkout <script dir>: prints the Watchtower checkout to use:
# WATCHTOWER_CHECKOUT, else the script's own repo. Fails (message on stderr)
# unless it has a Makefile and WatchtowerKit/.
ci_checkout() {
	local dir="${WATCHTOWER_CHECKOUT:-$1/..}"
	if [ ! -d "$dir" ] || [ ! -f "$dir/Makefile" ] || [ ! -d "$dir/WatchtowerKit" ]; then
		echo "$dir is not a Watchtower checkout (needs a Makefile and WatchtowerKit/): set WATCHTOWER_CHECKOUT" >&2
		return 1
	fi
	(cd "$dir" && pwd)
}
