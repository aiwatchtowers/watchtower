#!/bin/bash
# Runs the mobile Kit's relay interop tests (WatchtowerKit, the *InteropTests classes)
# against the hosted relay's local stand:
#
#   scripts/relay-interop-kit.sh <relay checkout>
#   make relay-interop-kit RELAY=../relay
#
# The Kit twin of scripts/relay-interop.sh (the Go hub's). It runs `npm ci` in
# <relay checkout>/worker when node_modules is missing (nothing else is written into
# the checkout), starts `wrangler dev` there in its own process group on fresh state in
# a temp dir — RELAY_ENV=dev from wrangler.jsonc (the /dev/* endpoints), attestation
# off, a random session secret, the server origin the clients sign, the register rate
# limit raised (a copy of wrangler.jsonc in the temp dir; see below) — waits for
# /healthz, then runs
#
#   WATCHTOWER_RELAY_INTEROP_URL=<origin> make kit-test FILTER='InteropTests'
#
# On exit, failure and SIGINT/SIGTERM the whole wrangler process group is killed and
# waited for, and so is the test run, and the temp dir is removed. Exits with the
# tests' code.
#
# The port is fixed (RELAY_INTEROP_PORT, default 8787), not wrangler's --port 0: the
# relay checks the origin signed into register and login against RELAY_SERVER_ORIGIN,
# so the origin must be known before the stand starts.
#
# Environment: RELAY_INTEROP_PORT, RELAY_INTEROP_FILTER (default 'InteropTests'),
# RELAY_INTEROP_KEEP=1 keeps the temp dir (wrangler's log and state).
# WATCHTOWER_CHECKOUT is the Watchtower checkout to test (default: this script's
# repo; needs a Makefile and WatchtowerKit/), so a relay CI job can call it.
# RELAY_INTEROP_CI=1 is the CI mode (scripts/relay-interop-ci-lib.sh): stdin from
# /dev/null, the test output goes to stderr after the run, the last stdout line
# is `relay-interop: passed=N skipped=M failed=K`, and a run where no test passed
# or failed exits 1.
#
# No `set -e`: the script reads exit codes itself (the readiness loop's curl, `wait` on
# the test run, whose code is the script's), and an early exit there would skip the
# messages around them; every failure that must stop the run goes through `die`, and the
# EXIT trap reaps whatever was started.
set -uo pipefail

# shellcheck source=relay-interop-ci-lib.sh
. "$(dirname "$0")/relay-interop-ci-lib.sh" || exit 1

WPID=""
TPID=""
STATE=""
KLOG=""
LOGS_SHOWN=0

die() {
	echo "relay-interop-kit: $*" >&2
	exit 1
}

# report_logs shows the test run's output on stderr and counts it, once (CI mode):
# after a normal end, or from cleanup when a signal cut the run short.
report_logs() {
	[ "$CI_MODE" = 1 ] && [ "$LOGS_SHOWN" != 1 ] && [ -n "$KLOG" ] && [ -f "$KLOG" ] || return 0
	LOGS_SHOWN=1
	cat "$KLOG" >&2
	ci_add_xctest "$KLOG"
}

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
	# A second Ctrl-C or TERM must not cut the stop short and orphan wrangler.
	trap - EXIT
	trap '' INT TERM
	if [ -n "$TPID" ]; then
		stop_group "$TPID"
		TPID=""
	fi
	if [ -n "$WPID" ]; then
		stop_group "$WPID"
		WPID=""
	fi
	report_logs
	if [ -n "$STATE" ] && [ "${RELAY_INTEROP_KEEP:-}" = 1 ]; then
		echo "relay-interop-kit: kept $STATE" >&2
	elif [ -n "$STATE" ]; then
		rm -rf "$STATE"
	fi
	ci_exit "$rc"
}

# The trap is first, so no exit path (a refusal too) skips the cleanup and the CI summary.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ $# -ne 1 ] || [ -z "$1" ]; then
	echo "usage: $0 <relay checkout>   (or: make relay-interop-kit RELAY=<dir>)" >&2
	exit 2
fi
RELAY="$1"
WORKER="$RELAY/worker"
ROOT="$(ci_checkout "$(cd "$(dirname "$0")" && pwd)")" || die "no usable Watchtower checkout"
PORT="${RELAY_INTEROP_PORT:-8787}"
ORIGIN="http://127.0.0.1:$PORT"
FILTER="${RELAY_INTEROP_FILTER:-InteropTests}"

[ -f "$WORKER/package.json" ] && [ -f "$WORKER/wrangler.jsonc" ] || die "$WORKER is not the relay's worker directory"
command -v node >/dev/null 2>&1 || die "node not found: install Node"
command -v npx >/dev/null 2>&1 || die "npx not found: install Node"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v openssl >/dev/null 2>&1 || die "openssl not found"
if [ ! -d "$WORKER/node_modules" ]; then
	echo "relay-interop-kit: npm ci in $WORKER" >&2
	(cd "$WORKER" && npm ci --no-audit --no-fund) >&2 || die "npm ci failed in $WORKER"
fi
[ -d "$WORKER/node_modules/wrangler" ] || die "no wrangler in $WORKER/node_modules"
if command -v lsof >/dev/null 2>&1; then
	holder="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $1 " (pid " $2 ")"; exit }')"
	[ -z "$holder" ] || die "port $PORT is held by $holder: stop it or set RELAY_INTEROP_PORT"
fi
if curl -fsS -m 2 "$ORIGIN/healthz" >/dev/null 2>&1; then
	die "something already answers on $ORIGIN: stop it or set RELAY_INTEROP_PORT"
fi

PIN="$(head -n 1 "$ROOT/WatchtowerKit/Sources/WatchtowerRelayProto/VERSION" | cut -d' ' -f1)"
if HEAD="$(git -C "$RELAY" rev-parse HEAD 2>/dev/null)"; then
	echo "relay-interop-kit: relay checkout at $HEAD" >&2
	if [ "$HEAD" != "$PIN" ]; then
		echo "relay-interop-kit: warning: the Kit's proto is pinned to $PIN" >&2
	fi
else
	echo "relay-interop-kit: $RELAY is not a git checkout; the Kit's proto is pinned to $PIN" >&2
fi

# The temp dir is created right after the checks; the EXIT trap above removes it.
STATE="$(mktemp -d "${TMPDIR:-/tmp}/relay-interop-kit.XXXXXX")" || die "mktemp failed"
LOG="$STATE/wrangler.log"
SECRET="$(openssl rand -hex 32)"
[ -n "$SECRET" ] || die "openssl rand gave no session secret"

# The stand's config: the worker's wrangler.jsonc copied into the temp dir with `main`
# made absolute and REGISTER_LIMIT (10 registrations a minute per address) raised: the
# Kit's scenarios give every test devices of its own, well past 10 a minute from 127.0.0.1.
# The relay's own vitest suite gets around the same limit with a fresh address per
# registration, which a local stand cannot fake.
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

echo "relay-interop-kit: starting the stand on $ORIGIN" >&2
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
		echo "relay-interop-kit: wrangler dev exited before it was ready:" >&2
		tail -n 40 "$LOG" >&2
		exit 1
	fi
	sleep 0.1
done
if [ "$ready" != 1 ]; then
	echo "relay-interop-kit: the stand did not answer /healthz in 90 s:" >&2
	tail -n 40 "$LOG" >&2
	exit 1
fi
# The stand must be the dev environment: /dev/* answers 404 everywhere else.
# An unknown phone gets 404 too, so probe with a malformed body (400).
code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -d '{}' "$ORIGIN/dev/account")"
if [ "$code" = 404 ] || [ "$code" = 000 ]; then
	die "the stand has no /dev/* endpoints (HTTP $code): it is not running with RELAY_ENV=dev"
fi

cd "$ROOT" || exit 1
run_kit() {
	WATCHTOWER_RELAY_INTEROP_URL="$ORIGIN" make kit-test FILTER="$FILTER" </dev/null
}
KLOG="$STATE/kit-test.log"
set -m
if [ "$CI_MODE" = 1 ]; then
	# stdout is only the summary line: the run's output is kept for the count and
	# shown on stderr when it ends.
	run_kit >"$KLOG" 2>&1 &
else
	run_kit &
fi
TPID=$!
set +m
wait "$TPID"
rc=$?
TPID=""
report_logs
if [ "$rc" -ne 0 ]; then
	echo "relay-interop-kit: FAIL (exit $rc); wrangler log tail:" >&2
	tail -n 60 "$LOG" >&2
fi
exit "$rc"
