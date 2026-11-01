#!/bin/bash
# Runs the Kit phone against the Go hub on the hosted relay's local stand
# (relay client Phase 3 Task 13):
#
#   scripts/relay-interop-kit-hub.sh <relay checkout>
#   make relay-interop-kit-hub RELAY=../relay
#
# Both halves run beside each other and hand off through files in one folder
# (the list is in internal/hub/interop_kit_test.go):
#
#   go test -tags interop -run '^TestInterop_KitPhone$' ./internal/hub -relay=<origin> -kit-dir=<dir>
#   WATCHTOWER_RELAY_INTEROP_URL=<origin> WT_GO_HUB_INTEROP_DIR=<dir> make kit-test FILTER=GoHubInteropTests
#
# Before the stand starts, both are built (the Go test run with -run '^$', the
# Kit class without the variables, where it skips), so neither half waits on
# the other's compile. The stand is started as scripts/relay-interop-kit.sh
# does: `wrangler dev` from <relay checkout>/worker (`npm ci` there when
# node_modules is missing; nothing else is written into the checkout) in its
# own process group, fresh state in a temp dir, attestation off, a random
# session secret, the signed origin, the register rate limit raised. The Go
# test and the Kit run each get their own process group too; on exit, failure
# and SIGINT/SIGTERM all three groups are killed and waited for, and the temp
# dir is removed. A half that fails leaves a mark (kit.fail / go.fail) the
# other reads, so neither waits out its timeouts. Exits 0 only when both pass.
#
# Environment: RELAY_INTEROP_PORT (default 8787), RELAY_INTEROP_KEEP=1 keeps
# the temp dir (wrangler's log, the handoff files).
#
# No `set -e`: the script reads exit codes itself; every refusal goes through
# `die` and the EXIT trap reaps whatever was started.
set -uo pipefail

usage() {
	echo "usage: $0 <relay checkout>   (or: make relay-interop-kit-hub RELAY=<dir>)" >&2
	exit 2
}

if [ $# -ne 1 ] || [ -z "$1" ]; then
	usage
fi
RELAY="$1"
WORKER="$RELAY/worker"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${RELAY_INTEROP_PORT:-8787}"
ORIGIN="http://127.0.0.1:$PORT"

die() {
	echo "relay-interop-kit-hub: $*" >&2
	exit 1
}

case "$PORT" in
'' | *[!0-9]*)
	echo "relay-interop-kit-hub: RELAY_INTEROP_PORT is not a port number" >&2
	exit 2
	;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
	echo "relay-interop-kit-hub: RELAY_INTEROP_PORT is not a port number" >&2
	exit 2
fi
[ -d "$RELAY" ] || die "$RELAY does not exist: pass a relay checkout"
[ -f "$WORKER/package.json" ] && [ -f "$WORKER/wrangler.jsonc" ] || die "$WORKER is not the relay's worker directory"
# The port before anything is built or started: a held port fails at once.
if command -v lsof >/dev/null 2>&1; then
	holder="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $1 " (pid " $2 ")"; exit }')"
	[ -z "$holder" ] || die "port $PORT is held by $holder: stop it or set RELAY_INTEROP_PORT"
fi
command -v curl >/dev/null 2>&1 || die "curl not found"
if curl -fsS -m 2 "$ORIGIN/healthz" >/dev/null 2>&1; then
	die "something already answers on $ORIGIN: stop it or set RELAY_INTEROP_PORT"
fi
command -v node >/dev/null 2>&1 || die "node not found: install Node"
command -v npx >/dev/null 2>&1 || die "npx not found: install Node"
command -v openssl >/dev/null 2>&1 || die "openssl not found"
command -v go >/dev/null 2>&1 || die "go not found"
command -v make >/dev/null 2>&1 || die "make not found"

KIT_PIN="$(head -n 1 "$ROOT/WatchtowerKit/Sources/WatchtowerRelayProto/VERSION" | cut -d' ' -f1)"
GO_PIN="$(cut -d' ' -f1 "$ROOT/internal/hub/transport/relay/VERSION")"
if HEAD="$(git -C "$RELAY" rev-parse HEAD 2>/dev/null)"; then
	echo "relay-interop-kit-hub: relay checkout at $HEAD (Kit pin $KIT_PIN, Go hub pin $GO_PIN)" >&2
	[ "$HEAD" = "$KIT_PIN" ] || echo "relay-interop-kit-hub: warning: the Kit's proto is pinned to $KIT_PIN" >&2
else
	echo "relay-interop-kit-hub: $RELAY is not a git checkout (Kit pin $KIT_PIN, Go hub pin $GO_PIN)" >&2
fi

WPID=""
GOPID=""
KPID=""
STATE=""

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

cleanup() {
	local rc=$?
	# A second Ctrl-C or TERM must not cut the stop short and orphan a group.
	trap - EXIT
	trap '' INT TERM
	local pg
	for pg in "$KPID" "$GOPID" "$WPID"; do
		[ -n "$pg" ] && stop_group "$pg"
	done
	KPID="" GOPID="" WPID=""
	if [ -n "$STATE" ] && [ "${RELAY_INTEROP_KEEP:-}" = 1 ]; then
		echo "relay-interop-kit-hub: kept $STATE" >&2
	elif [ -n "$STATE" ]; then
		rm -rf "$STATE"
	fi
	exit "$rc"
}

# The trap goes in right after mktemp, so no exit path leaves the temp dir behind.
STATE="$(mktemp -d "${TMPDIR:-/tmp}/relay-interop-kit-hub.XXXXXX")" || die "mktemp failed"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
LOG="$STATE/wrangler.log"
HANDOFF="$STATE/handoff"
mkdir -m 700 "$HANDOFF" || die "could not create the handoff folder"

cd "$ROOT" || exit 1
echo "relay-interop-kit-hub: building the Go test and the Kit tests" >&2
go test -count=1 -tags interop -run '^$' ./internal/hub >"$STATE/go-build.log" 2>&1 </dev/null ||
	{ tail -n 40 "$STATE/go-build.log" >&2; die "the Go interop test does not build"; }
env -u WATCHTOWER_RELAY_INTEROP_URL -u WT_GO_HUB_INTEROP_DIR make kit-test FILTER=GoHubInteropTests \
	>"$STATE/kit-build.log" 2>&1 </dev/null ||
	{ tail -n 40 "$STATE/kit-build.log" >&2; die "the Kit tests do not build"; }

if [ ! -d "$WORKER/node_modules" ]; then
	echo "relay-interop-kit-hub: npm ci in $WORKER" >&2
	(cd "$WORKER" && npm ci --no-audit --no-fund) >&2 || die "npm ci failed in $WORKER"
fi
[ -d "$WORKER/node_modules/wrangler" ] || die "no wrangler in $WORKER/node_modules"
SECRET="$(openssl rand -hex 32)"
[ -n "$SECRET" ] || die "openssl rand gave no session secret"

# The stand's config: the worker's wrangler.jsonc with `main` made absolute and
# REGISTER_LIMIT raised (see scripts/relay-interop-kit.sh).
node - "$WORKER" "$STATE/wrangler.jsonc" <<'NODE' || die "could not write the stand's wrangler config"
const fs = require("fs");
const path = require("path");
const [worker, out] = process.argv.slice(2);
let text = fs.readFileSync(path.join(worker, "wrangler.jsonc"), "utf8");
const swap = (re, to) => {
  if ((text.match(new RegExp(re.source, "g")) || []).length !== 1) throw new Error(`no single match for ${re}`);
  text = text.replace(re, to);
};
swap(/"main": "src\/index\.ts"/, `"main": ${JSON.stringify(path.resolve(worker, "src/index.ts"))}`);
swap(/("name": "REGISTER_LIMIT", "namespace_id": "1001", "simple": \{ "limit": )10,/, "$1100000,");
fs.writeFileSync(out, text);
NODE

echo "relay-interop-kit-hub: starting the stand on $ORIGIN" >&2
set -m
(cd "$WORKER" && exec env NO_COLOR=1 WRANGLER_SEND_METRICS=false CI=1 npx wrangler dev \
	--config "$STATE/wrangler.jsonc" --port "$PORT" --ip 127.0.0.1 --inspector-port 0 --persist-to "$STATE/persist" \
	--show-interactive-dev-session=false \
	--var "RELAY_SESSION_SECRET:$SECRET" --var "RELAY_ATTEST_MODE:off" \
	--var "RELAY_SERVER_ORIGIN:$ORIGIN") >>"$LOG" 2>&1 </dev/null &
WPID=$!
set +m
ready=0
for _ in $(seq 1 900); do
	if curl -fsS -m 2 "$ORIGIN/healthz" >/dev/null 2>&1; then
		ready=1
		break
	fi
	if ! kill -0 "$WPID" 2>/dev/null; then
		echo "relay-interop-kit-hub: wrangler dev exited before it was ready:" >&2
		tail -n 40 "$LOG" >&2
		exit 1
	fi
	sleep 0.1
done
if [ "$ready" != 1 ]; then
	echo "relay-interop-kit-hub: the stand did not answer /healthz in 90 s:" >&2
	tail -n 40 "$LOG" >&2
	exit 1
fi
code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -d '{}' "$ORIGIN/dev/account")"
if [ "$code" = 404 ] || [ "$code" = 000 ]; then
	die "the stand has no /dev/* endpoints (HTTP $code): it is not running with RELAY_ENV=dev"
fi

# mark <file> <text>: a failure mark for the other half, unless it is there.
mark() {
	[ -e "$HANDOFF/$1" ] && return 0
	printf '%s' "$2" >"$HANDOFF/.$1.tmp" && mv "$HANDOFF/.$1.tmp" "$HANDOFF/$1"
}

set -m
go test -count=1 -timeout 30m -tags interop -run '^TestInterop_KitPhone$' -v ./internal/hub \
	-relay="$ORIGIN" -kit-dir="$HANDOFF" </dev/null &
GOPID=$!
WATCHTOWER_RELAY_INTEROP_URL="$ORIGIN" WT_GO_HUB_INTEROP_DIR="$HANDOFF" make kit-test FILTER=GoHubInteropTests </dev/null &
KPID=$!
set +m

# Whichever half ends first: a failed one leaves its mark, so the other stops waiting.
# kit_rc/go_rc say a leader is done; KPID/GOPID stay set, so cleanup still sweeps a
# group whose leader exited but left children (a test runner's helpers).
kit_rc="" go_rc=""
while [ -z "$kit_rc" ] || [ -z "$go_rc" ]; do
	if [ -z "$kit_rc" ] && ! kill -0 "$KPID" 2>/dev/null; then
		wait "$KPID"
		kit_rc=$?
		[ "$kit_rc" -eq 0 ] || mark kit.fail "kit exited $kit_rc"
	fi
	if [ -z "$go_rc" ] && ! kill -0 "$GOPID" 2>/dev/null; then
		wait "$GOPID"
		go_rc=$?
		[ "$go_rc" -eq 0 ] || mark go.fail "go exited $go_rc"
	fi
	sleep 0.5
done

echo "relay-interop-kit-hub: Go hub exit $go_rc, Kit phone exit $kit_rc" >&2
if [ "$go_rc" -ne 0 ] || [ "$kit_rc" -ne 0 ]; then
	echo "relay-interop-kit-hub: FAIL; handoff files: $(ls -A "$HANDOFF" | tr '\n' ' ')" >&2
	echo "relay-interop-kit-hub: wrangler log tail:" >&2
	tail -n 60 "$LOG" >&2
	exit 1
fi
echo "relay-interop-kit-hub: PASS" >&2
exit 0
