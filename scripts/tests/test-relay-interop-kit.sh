#!/bin/bash
# Tests for scripts/relay-interop.sh KIT=1 (Go hub phase 2, Task 12): the
# owner's half of the Kit phone's pairing with a headless hub.
#
# No stand, no CLI build, no Kit: `npx` (the stand), `curl` (its /healthz and
# /dev/account), the watchtower CLI (RELAY_INTEROP_WATCHTOWER) and the Kit
# suite (RELAY_INTEROP_KIT_CMD) are stubs that record what they were asked
# and the pid of every process they leave running. Checks: the pairing url
# reaches pair.url, a matching code is confirmed and the phone gets its
# grants, a wrong code and no code in time are refused with a failing exit,
# and no started process outlives the script (exit, failure and SIGTERM).
# Runs on the dev Mac and in the Linux CI job alike.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INTEROP="$SCRIPT_DIR/../relay-interop.sh"

FAILURES=0
note_fail() {
	echo "FAIL: $1"
	FAILURES=$((FAILURES + 1))
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# setup <case>: a fresh fake relay checkout, stub dir and log dir under
# $WORK_DIR/<case>; sets C (the case dir).
setup() {
	C="$WORK_DIR/$1"
	mkdir -p "$C/relay/worker/node_modules/wrangler" "$C/stub" "$C/log"
	echo '{}' >"$C/relay/worker/package.json"
	echo '{}' >"$C/relay/worker/wrangler.jsonc"
	local log="$C/log"

	# npx wrangler dev: marks the stand up and stays until stopped.
	cat >"$C/stub/npx" <<EOF
#!/bin/bash
echo \$\$ >> '$log/pids'
: > '$log/up'
exec sleep 300
EOF
	# curl: /healthz answers once the stand is up; /dev/account is 400.
	cat >"$C/stub/curl" <<EOF
#!/bin/bash
for a in "\$@"; do
	case "\$a" in
	*/healthz) [ -e '$log/up' ]; exit \$? ;;
	*/dev/account) printf 400; exit 0 ;;
	esac
done
exit 7
EOF
	# The CLI. It runs under env -i, so its paths are baked in.
	cat >"$C/stub/watchtower" <<EOF
#!/bin/bash
echo "\$*" >> '$log/calls'
case "\$1 \${2:-}" in
"session-host "*) echo \$\$ >> '$log/pids'; : > "\$3"; exec sleep 300 ;;
"sync --daemon") echo \$\$ >> '$log/pids'; exec sleep 300 ;;
"hub status") echo '{"state":"running","reason":"","relay_device_id":"r1"}' ;;
"workbench create") printf '{\n  "id": 7\n}\n' ;;
"hub pair")
	echo \$\$ >> '$log/pids'
	echo '{"event":"qr","url":"https://relay.example.com/link?v=4&k=abc#x","expires_at":"2026-11-01T00:10:00Z"}'
	echo '{"event":"waiting"}'
	echo '{"event":"sas","device_id":"dev1","name":"Phone","code":"4821"}'
	read -r line
	echo "\$line" > '$log/confirm'
	case "\$line" in
	*true*) echo '{"event":"linked","device_id":"dev1"}' ;;
	*) echo '{"event":"refused","reason":"not_confirmed"}' ;;
	esac
	;;
esac
exit 0
EOF
	# The Kit suite: copies pair.url, writes STUB_PHONE_CODE to pair.sas and
	# copies pair.result; with no code it waits until stopped.
	cat >"$C/stub/kit" <<EOF
#!/bin/bash
echo \$\$ >> '$log/pids'
env | grep '^WT_' | sort > '$log/kitenv'
for i in \$(seq 1 100); do [ -s "\$WT_HUB_INTEROP_DIR/pair.url" ] && break; sleep 0.2; done
cp "\$WT_HUB_INTEROP_DIR/pair.url" '$log/url'
cp "\$WT_HUB_INTEROP_DIR/hub.json" '$log/hub.json'
[ -n "\${STUB_PHONE_CODE:-}" ] || exec sleep 300
printf '%s\n' "\$STUB_PHONE_CODE" > "\$WT_HUB_INTEROP_DIR/pair.sas.tmp"
mv "\$WT_HUB_INTEROP_DIR/pair.sas.tmp" "\$WT_HUB_INTEROP_DIR/pair.sas"
for i in \$(seq 1 100); do [ -s "\$WT_HUB_INTEROP_DIR/pair.result" ] && break; sleep 0.2; done
cp "\$WT_HUB_INTEROP_DIR/pair.result" '$log/result' 2>/dev/null
exit 0
EOF
	chmod +x "$C/stub/"*
}

# run_interop [env...]: runs the script KIT=1 against the case's stubs in
# the foreground; sets RC.
run_interop() {
	env PATH="$C/stub:$PATH" KIT=1 RELAY_INTEROP_PORT=18999 RELAY_INTEROP_HUB_MODE=test \
		RELAY_INTEROP_WATCHTOWER="$C/stub/watchtower" RELAY_INTEROP_KIT_CMD="$C/stub/kit" \
		"$@" bash "$INTEROP" "$C/relay" >"$C/out" 2>&1 </dev/null
	RC=$?
}

# assert_reaped <what>: no pid any stub recorded is still alive.
assert_reaped() {
	local pid
	[ -s "$C/log/pids" ] || {
		note_fail "$1: no stub recorded a pid"
		return
	}
	while read -r pid; do
		if kill -0 "$pid" 2>/dev/null; then
			note_fail "$1: pid $pid ($(ps -o command= -p "$pid" 2>/dev/null)) outlived the script"
			kill -KILL "$pid" 2>/dev/null
		fi
	done <"$C/log/pids"
}

assert_file() { # <what> <file> <expected content>
	local got
	got="$(cat "$2" 2>/dev/null)"
	[ "$got" = "$3" ] || note_fail "$1: got '$got', want '$3'"
}

show_out() {
	echo "--- script output ($1)"
	tail -n 30 "$C/out"
}

# 1. The phone's code matches: confirmed, grants given, the result written.
setup match
run_interop STUB_PHONE_CODE=4821
[ "$RC" -eq 0 ] || {
	note_fail "match: exit $RC, want 0"
	show_out match
}
assert_file "match: pair.url (Go's \\u0026 unescaped)" "$C/log/url" 'https://relay.example.com/link?v=4&k=abc#x'
assert_file "match: confirm" "$C/log/confirm" '{"confirm":true}'
assert_file "match: pair.result" "$C/log/result" '{"event":"linked","device_id":"dev1"}'
grep -qx 'hub allow dev1 typing' "$C/log/calls" || note_fail "match: no typing grant"
grep -qx 'hub allow dev1 start_sessions' "$C/log/calls" || note_fail "match: no start_sessions grant"
grep -q '"workbench_id":7' "$C/log/hub.json" || note_fail "match: hub.json has no workbench_id 7: $(cat "$C/log/hub.json" 2>/dev/null)"
grep -q '"mode":"test"' "$C/log/hub.json" || note_fail "match: hub.json has no mode"
grep -qx 'WT_RELAY_INTEROP_URL=http://127.0.0.1:18999' "$C/log/kitenv" || note_fail "match: the Kit suite got no WT_RELAY_INTEROP_URL"
grep -q '^WT_HUB_INTEROP_DIR=/' "$C/log/kitenv" || note_fail "match: the Kit suite got no WT_HUB_INTEROP_DIR"
for c in 'workspace init --headless --name hubtest-kit' 'config set hub.relay_origin http://127.0.0.1:18999' 'hub enable' 'sync stop'; do
	grep -qx "$c" "$C/log/calls" || note_fail "match: the hub never ran '$c'"
done
assert_reaped match

# 2. A wrong code: refused, no grants, a failing exit.
setup wrong
run_interop STUB_PHONE_CODE=1111
[ "$RC" -ne 0 ] || note_fail "wrong: exit 0, want non-zero"
assert_file "wrong: confirm" "$C/log/confirm" '{"confirm":false}'
if grep -q 'hub allow' "$C/log/calls"; then note_fail "wrong: grants given to a refused phone"; fi
grep -q 'does not match' "$C/out" || note_fail "wrong: no mismatch line"
assert_reaped wrong

# 3. No code in time: refused, the waiting Kit suite stopped, a failing exit.
setup timeout
run_interop RELAY_INTEROP_PAIR_TIMEOUT=2
[ "$RC" -ne 0 ] || note_fail "timeout: exit 0, want non-zero"
assert_file "timeout: confirm" "$C/log/confirm" '{"confirm":false}'
grep -q 'no code from the phone in 2 s' "$C/out" || {
	note_fail "timeout: no timeout line"
	show_out timeout
}
assert_reaped timeout

# 4. SIGTERM while the pairing waits: every started process is stopped.
setup term
env PATH="$C/stub:$PATH" KIT=1 RELAY_INTEROP_PORT=18999 RELAY_INTEROP_HUB_MODE=test \
	RELAY_INTEROP_WATCHTOWER="$C/stub/watchtower" RELAY_INTEROP_KIT_CMD="$C/stub/kit" \
	bash "$INTEROP" "$C/relay" >"$C/out" 2>&1 </dev/null &
SPID=$!
for _ in $(seq 1 150); do
	[ -s "$C/log/url" ] && break
	sleep 0.1
done
[ -s "$C/log/url" ] || note_fail "term: the Kit stub never saw pair.url"
kill -TERM "$SPID"
wait "$SPID"
RC=$?
[ "$RC" -eq 143 ] || note_fail "term: exit $RC, want 143"
assert_reaped term

if [ "$FAILURES" -gt 0 ]; then
	echo "test-relay-interop-kit: $FAILURES failure(s)"
	exit 1
fi
echo "test-relay-interop-kit: ok"
