#!/bin/bash
# Runs the Go hub's interop tests against the hosted relay's local stand
# (Go hub design §6.1, §13 "Interop"):
#
#   scripts/relay-interop.sh <relay checkout>
#   make relay-interop RELAY=../relay
#
# It starts `wrangler dev` from <relay checkout>/worker (Node and `npm ci`
# there first; wrangler is the worker's own devDependency, run through npx)
# in its own process group, on fresh state in a temp dir, with RELAY_ENV=dev
# (App Attest off, the /dev/* endpoints), waits for /healthz, then runs
#
#   go test -tags interop -run '^TestInterop_' ./internal/hub -relay=<origin> -relay-control-pid=<this pid>
#
# (only internal/hub defines -relay, so the flag cannot go to ./internal/hub/...).
# A test sends this script SIGUSR1 to restart the stand on the same state.
# On exit, failure and SIGINT/SIGTERM the whole wrangler process group is
# killed and waited for, and so is the test run: no wrangler outlives it.
#
# Environment: RELAY_INTEROP_PORT (default 8787), RELAY_INTEROP_RUN (a -run
# regexp, default '^TestInterop_'), RELAY_INTEROP_KEEP=1 keeps the temp dir
# (wrangler's log and state) for a look after a failure.
set -uo pipefail

if [ $# -ne 1 ] || [ -z "$1" ]; then
	echo "usage: $0 <relay checkout>   (or: make relay-interop RELAY=<dir>)" >&2
	exit 2
fi
RELAY="$1"
WORKER="$RELAY/worker"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${RELAY_INTEROP_PORT:-8787}"
ORIGIN="http://127.0.0.1:$PORT"
RUN="${RELAY_INTEROP_RUN:-^TestInterop_}"

die() {
	echo "relay-interop: $*" >&2
	exit 1
}

[ -f "$WORKER/package.json" ] && [ -f "$WORKER/wrangler.jsonc" ] || die "$WORKER is not the relay's worker directory"
[ -d "$WORKER/node_modules/wrangler" ] || die "no wrangler in $WORKER/node_modules: run 'npm ci' in $WORKER"
command -v npx >/dev/null 2>&1 || die "npx not found: install Node"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v openssl >/dev/null 2>&1 || die "openssl not found"
if curl -fsS -m 2 "$ORIGIN/healthz" >/dev/null 2>&1; then
	die "something already answers on $ORIGIN: stop it or set RELAY_INTEROP_PORT"
fi

PIN="$(cut -d' ' -f1 "$ROOT/internal/hub/transport/relay/VERSION")"
if HEAD="$(git -C "$RELAY" rev-parse HEAD 2>/dev/null)"; then
	if [ "$HEAD" != "$PIN" ]; then
		echo "relay-interop: warning: $RELAY is at $HEAD, the vendored client is pinned to $PIN" >&2
	fi
else
	echo "relay-interop: $RELAY is not a git checkout; the vendored client is pinned to $PIN" >&2
fi

STATE="$(mktemp -d "${TMPDIR:-/tmp}/relay-interop.XXXXXX")" || die "mktemp failed"
LOG="$STATE/wrangler.log"
SECRET="$(openssl rand -hex 32)"
WPID=""
GOPID=""
RESTART=0

# stop_group ends process group $1: SIGTERM, then SIGKILL after 10 s, and
# waits until no process of the group is left.
stop_group() {
	local pg="$1" i
	kill -TERM -- "-$pg" 2>/dev/null
	for i in $(seq 1 100); do
		kill -0 -- "-$pg" 2>/dev/null || break
		sleep 0.1
	done
	kill -KILL -- "-$pg" 2>/dev/null
	for i in $(seq 1 50); do
		kill -0 -- "-$pg" 2>/dev/null || break
		sleep 0.1
	done
	wait "$pg" 2>/dev/null
}

stop_wrangler() {
	[ -n "$WPID" ] || return 0
	stop_group "$WPID"
	WPID=""
}

cleanup() {
	local rc=$?
	trap - EXIT INT TERM USR1
	if [ -n "$GOPID" ]; then
		stop_group "$GOPID"
		GOPID=""
	fi
	stop_wrangler
	if [ "${RELAY_INTEROP_KEEP:-}" = 1 ]; then
		echo "relay-interop: kept $STATE" >&2
	else
		rm -rf "$STATE"
	fi
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'RESTART=1' USR1

# start_wrangler starts the stand in its own process group (job control on
# for that one launch) and waits for /healthz.
start_wrangler() {
	echo "relay-interop: starting the stand on $ORIGIN" >&2
	set -m
	(cd "$WORKER" && exec env NO_COLOR=1 WRANGLER_SEND_METRICS=false CI=1 npx wrangler dev \
		--port "$PORT" --ip 127.0.0.1 --inspector-port 0 --persist-to "$STATE/persist" \
		--show-interactive-dev-session=false \
		--var "RELAY_SESSION_SECRET:$SECRET" --var "RELAY_SERVER_ORIGIN:$ORIGIN") >>"$LOG" 2>&1 </dev/null &
	WPID=$!
	set +m
	local i
	for i in $(seq 1 900); do
		if curl -fsS -m 2 "$ORIGIN/healthz" >/dev/null 2>&1; then
			return 0
		fi
		if ! kill -0 "$WPID" 2>/dev/null; then
			echo "relay-interop: wrangler dev exited before it was ready:" >&2
			tail -n 40 "$LOG" >&2
			return 1
		fi
		sleep 0.1
	done
	echo "relay-interop: the stand did not answer /healthz in 90 s:" >&2
	tail -n 40 "$LOG" >&2
	return 1
}

start_wrangler || exit 1

cd "$ROOT" || exit 1
set -m
go test -count=1 -tags interop -run "$RUN" -v ./internal/hub -relay="$ORIGIN" -relay-control-pid=$$ </dev/null &
GOPID=$!
set +m

rc=0
while :; do
	wait "$GOPID"
	rc=$?
	if [ "$RESTART" = 1 ]; then
		RESTART=0
		echo "relay-interop: restarting the stand (asked by a test)" >&2
		stop_wrangler
		if ! start_wrangler; then
			rc=1
			break
		fi
		continue
	fi
	break
done
GOPID=""
if [ "$rc" -ne 0 ]; then
	echo "relay-interop: FAIL (exit $rc); wrangler log tail:" >&2
	tail -n 60 "$LOG" >&2
fi
exit "$rc"
