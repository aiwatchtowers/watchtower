#!/bin/bash
# Tests for scripts/relay-interop-kit-hub.sh's refusals (relay client Phase 3
# Task 13): a missing or wrong argument, a relay dir that is not a checkout, a
# bad RELAY_INTEROP_PORT, a held port and a port something already answers on.
# No stand, no build: `lsof`, `curl`, `npx`, `go`, `make` and `node` are stubs
# on PATH that record every call, and each refusal must come before any of
# them builds or starts anything. Starts no process of its own.
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

if [ "$FAILURES" -ne 0 ]; then
	echo "test-relay-interop-kit-hub: $FAILURES failure(s)"
	exit 1
fi
echo "test-relay-interop-kit-hub: ok"
