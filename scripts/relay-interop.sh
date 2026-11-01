#!/bin/bash
# Runs the Go hub's interop tests against the hosted relay's local stand
# (Go hub design §6.1, §13 "Interop"):
#
#   scripts/relay-interop.sh <relay checkout>
#   make relay-interop RELAY=../relay
#
# It starts `wrangler dev` from <relay checkout>/worker (Node and `npm ci`
# there first; wrangler is the worker's own devDependency, run through npx)
# in its own process group, on fresh state in a temp dir, and waits for
# /healthz. It relies on the worker's wrangler.jsonc top-level defaults
# (RELAY_ENV=dev, RELAY_ATTEST_MODE=off: App Attest off, the /dev/*
# endpoints) and checks that /dev/* exists before the tests run. Then it runs
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
#
# KIT=1 (make relay-interop RELAY=../relay KIT=1; macOS only) runs the Kit
# phone against a live headless hub instead of the Go tests (Go hub phase 2,
# Task 12). After the stand is up it builds the CLI into the temp dir and,
# in a short temp HOME (/tmp/wtkit.*), starts the session host on its own
# socket, runs `workspace init --headless`, `config set hub.relay_origin`,
# `hub enable` and `sync --daemon`, waits for the hub to hold a relay device
# id, and creates a workbench over an empty git repo whose `claude` is a stub
# that marks itself ready and appends its terminal input to a file. On a Mac
# with /Applications/Watchtower.app the hub cannot run live (desktop_host),
# so it runs the phase-1 test mode, as `make hub-smoke` does on darwin; that
# mode has no relay-only rules. Then, in $WT_HUB_INTEROP_DIR:
#
#   hub.json     {"mode","workbench_id","typed","ready"}: written first
#   pair.url     the `hub pair --json --stream` QR line's url
#   pair.sas     the Kit test writes the code its phone shows (tmp + rename);
#                the script answers {"confirm":true} only when it equals
#                the hub's sas.code, else {"confirm":false}
#   pair.result  the stream's last line (linked or refused), written after
#                a linked phone got the typing and start_sessions grants
#
# and runs the Kit suite with WT_RELAY_INTEROP_URL (the stand's origin) and
# WT_HUB_INTEROP_DIR exported. No code within RELAY_INTEROP_PAIR_TIMEOUT
# seconds (default 600) of the url answers {"confirm":false} and fails.
# Every process it started (stand, session host, daemon, pairing, Kit suite)
# is stopped on every exit path. Seams for scripts/tests: RELAY_INTEROP_WATCHTOWER
# (a built CLI instead of `go build`), RELAY_INTEROP_KIT_CMD (instead of
# `make kit-test FILTER='^WatchtowerHostedRelayTests.GoHubInteropTests'`, exact so
# KitGoHubInteropTests never runs here; it also lifts the macOS check),
# RELAY_INTEROP_HUB_MODE=live|test (instead of the /Applications rule).
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
KIT="${KIT:-}"
if [ "$KIT" = 1 ] && [ -z "${RELAY_INTEROP_KIT_CMD:-}" ] && [ "$(uname -s)" != Darwin ]; then
	die "KIT=1 runs the Kit suite, which needs macOS"
fi
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
	# A second Ctrl-C or TERM must not cut the stop short and orphan wrangler.
	trap - EXIT
	trap '' INT TERM USR1
	if [ -n "$GOPID" ]; then
		stop_group "$GOPID"
		GOPID=""
	fi
	kit_cleanup
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

# --- KIT=1: the Kit phone against a live headless hub (Task 12) ---

KIT_HOME=""   # the hub's temp HOME, short enough for a unix socket path
KIT_DIR=""    # $WT_HUB_INTEROP_DIR
KIT_BIN=""
KIT_SOCK=""
KIT_ENV=()
SHPID=""      # the session host we started
DPID=""       # sync --daemon
PAIRPID=""    # hub pair --json --stream
KPID=""       # the Kit suite
KIT_FD=0      # 1 while fd 3 (the pairing's stdin) is open
PAIR_TIMEOUT="${RELAY_INTEROP_PAIR_TIMEOUT:-600}"

# hubcli runs the CLI in the hub's own environment only.
hubcli() {
	env -i "${KIT_ENV[@]}" "$KIT_BIN" "$@"
}

# kit_cli runs one setup command, failing the run with its output.
kit_cli() {
	if ! hubcli "$@" >>"$KIT_HOME/cli.log" 2>&1 </dev/null; then
		tail -n 20 "$KIT_HOME/cli.log" >&2
		die "watchtower $* failed"
	fi
}

# bounded <secs> <cmd...> runs cmd in its own process group and stops the
# group past secs.
bounded() {
	local secs="$1" pid i
	shift
	set -m
	"$@" </dev/null >/dev/null 2>&1 &
	pid=$!
	set +m
	for i in $(seq 1 $((secs * 10))); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	stop_group "$pid"
}

# kit_until <secs> <what> <cmd...> waits until cmd succeeds.
kit_until() {
	local secs="$1" what="$2" i
	shift 2
	for i in $(seq 1 $((secs * 5))); do
		"$@" && return 0
		sleep 0.2
	done
	echo "relay-interop: no $what in $secs s" >&2
	return 1
}

# json_field <key> prints the first string or number value of key in the
# JSON on stdin. Go's encoder escapes <, > and & as <, >, &;
# a value with any other escape is not matched.
json_field() {
	sed -nE 's/.*"'"$1"'":[[:space:]]*("(([^"\\]|\\u00(26|3c|3e))*)"|(-?[0-9]+)).*/\2\5/p' |
		head -n 1 | sed -e 's/\\u0026/\&/g' -e 's/\\u003c/</g' -e 's/\\u003e/>/g'
}

# write_atomic <file> <text> writes text and a newline through a rename, so
# the Kit test never reads half a file.
write_atomic() {
	printf '%s\n' "$2" >"$1.tmp" && mv -f "$1.tmp" "$1"
}

kit_hub_up() {
	local s
	s="$(hubcli hub status --json 2>/dev/null)" || return 1
	printf '%s' "$s" | grep -Eq '"state":[[:space:]]*"(running|paused)"' || return 1
	[ -n "$(printf '%s' "$s" | json_field relay_device_id)" ]
}

kit_pair_has() {
	grep -q '"event":[[:space:]]*"'"$1"'"' "$KIT_HOME/pair.out" 2>/dev/null
}

# kit_confirm <true|false> answers the pairing once.
kit_confirm() {
	[ "$KIT_FD" = 1 ] || return 0
	# In a subshell: a pairing that already ended must not SIGPIPE the script.
	(printf '{"confirm":%s}\n' "$1" >&3) 2>/dev/null
	exec 3>&-
	KIT_FD=0
}

# kit_handoff is the owner's half of the pairing: it answers the hub's code
# with the Kit test's (pair.sas), then, once the stream ends linked, gives
# the phone its grants and writes pair.result. 0 = linked, or the Kit suite
# ended without pairing (its tests skipped); 1 = refused, a wrong code, or
# no code in time.
kit_handoff() {
	local deadline answered="" hub_code phone_code last device i
	deadline=$(($(date +%s) + PAIR_TIMEOUT))
	while :; do
		if [ -z "$answered" ]; then
			if kit_pair_has sas && [ -s "$KIT_DIR/pair.sas" ]; then
				hub_code="$(grep -E '"event":[[:space:]]*"sas"' "$KIT_HOME/pair.out" | head -n 1 | json_field code)"
				phone_code="$(tr -d '[:space:]' <"$KIT_DIR/pair.sas")"
				if [ -n "$hub_code" ] && [ "$phone_code" = "$hub_code" ]; then
					answered=true
				else
					answered=false
					echo "relay-interop: the phone's code does not match the hub's; refusing" >&2
				fi
				kit_confirm "$answered"
			elif ! kill -0 "$PAIRPID" 2>/dev/null; then
				echo "relay-interop: the pairing ended before a phone showed a code" >&2
				tail -n 1 "$KIT_HOME/pair.out" >&2
				return 1
			elif ! kill -0 "$KPID" 2>/dev/null; then
				return 0
			elif [ "$(date +%s)" -ge "$deadline" ]; then
				echo "relay-interop: no code from the phone in $PAIR_TIMEOUT s; refusing" >&2
				kit_confirm false
				# A shown code makes the stream end refused at once.
				for i in $(seq 1 50); do
					kill -0 "$PAIRPID" 2>/dev/null || break
					sleep 0.1
				done
				stop_group "$PAIRPID"
				PAIRPID=""
				[ -s "$KIT_HOME/pair.out" ] && write_atomic "$KIT_DIR/pair.result" "$(tail -n 1 "$KIT_HOME/pair.out")"
				return 1
			fi
		elif ! kill -0 "$PAIRPID" 2>/dev/null; then
			wait "$PAIRPID" 2>/dev/null
			PAIRPID=""
			last="$(tail -n 1 "$KIT_HOME/pair.out")"
			if [ "$answered" = true ] && printf '%s' "$last" | grep -Eq '"event":[[:space:]]*"linked"'; then
				device="$(printf '%s' "$last" | json_field device_id)"
				kit_cli hub allow "$device" typing
				kit_cli hub allow "$device" start_sessions
				write_atomic "$KIT_DIR/pair.result" "$last"
				echo "relay-interop: linked the phone" >&2
				return 0
			fi
			write_atomic "$KIT_DIR/pair.result" "$last"
			echo "relay-interop: not linked: $last" >&2
			return 1
		fi
		sleep 0.2
	done
}

# kit_run brings the hub up, pairs the Kit test's phone and runs the Kit
# suite; its exit is the run's.
kit_run() {
	local mode wb kitcmd hrc rc
	mode="${RELAY_INTEROP_HUB_MODE:-}"
	if [ -z "$mode" ]; then
		mode=live
		if [ "$(uname -s)" = Darwin ] && [ -e /Applications/Watchtower.app ]; then
			mode=test
		fi
	fi
	case "$mode" in live | test) ;; *) die "RELAY_INTEROP_HUB_MODE is live or test, not $mode" ;; esac
	KIT_HOME="$(mktemp -d /tmp/wtkit.XXXXXX)" || die "mktemp failed"
	KIT_HOME="$(cd "$KIT_HOME" && pwd -P)"
	KIT_DIR="$STATE/interop"
	KIT_SOCK="$KIT_HOME/sh.sock"
	mkdir -p "$KIT_HOME/stub" "$KIT_HOME/tmp" "$KIT_HOME/repo" "$KIT_DIR" || die "mkdir failed"
	if [ -n "${RELAY_INTEROP_WATCHTOWER:-}" ]; then
		KIT_BIN="$RELAY_INTEROP_WATCHTOWER"
	else
		KIT_BIN="$KIT_HOME/bin/watchtower"
		echo "relay-interop: building the CLI" >&2
		go build -o "$KIT_BIN" . || die "go build failed"
	fi
	# The session's login shell finds the stub claude through the profile,
	# as a real install does (a hosted launch passes no PATH).
	printf 'export PATH=%s:"$PATH"\n' "$KIT_HOME/stub" >"$KIT_HOME/.bash_profile"
	cp "$KIT_HOME/.bash_profile" "$KIT_HOME/.profile"
	KIT_ENV=("HOME=$KIT_HOME" "PATH=$KIT_HOME/stub:$PATH" "SHELL=/bin/bash" "TMPDIR=$KIT_HOME/tmp"
		"LANG=en_US.UTF-8" "USER=${USER:-}" "LOGNAME=${LOGNAME:-}" "WATCHTOWER_SESSION_HOST_SOCKET=$KIT_SOCK")
	if [ "$mode" = test ]; then
		# A Mac with the app is a desktop host: the phase-1 test mode, as
		# make hub-smoke runs on darwin. It has no relay-only rules.
		KIT_ENV+=("WATCHTOWER_HUB_DIR=$KIT_HOME/hub" "WATCHTOWER_HUB_TEST_WORKSPACE=hubtest-kit"
			"WATCHTOWER_RELAY_ORIGIN=$ORIGIN")
	fi
	echo "relay-interop: KIT=1, the hub in $mode mode, HOME $KIT_HOME" >&2

	set -m
	hubcli session-host --socket "$KIT_SOCK" >>"$KIT_HOME/session-host.log" 2>&1 </dev/null &
	SHPID=$!
	set +m
	kit_until 30 "session host socket" test -e "$KIT_SOCK" || die "the session host did not start"

	if [ "$mode" = test ]; then
		kit_cli workspace init --headless --name hubtest-kit
	else
		kit_cli workspace init --headless
	fi
	kit_cli config set hub.relay_origin "$ORIGIN"
	kit_cli hub enable
	set -m
	hubcli sync --daemon >>"$KIT_HOME/daemon.log" 2>&1 </dev/null &
	DPID=$!
	set +m
	if ! kit_until 120 "running hub with a relay device id" kit_hub_up; then
		tail -n 40 "$KIT_HOME/daemon.log" >&2
		die "the hub did not come up"
	fi

	git -C "$KIT_HOME/repo" init -q &&
		git -C "$KIT_HOME/repo" -c user.name=Interop -c user.email=interop@example.com commit -q --allow-empty -m init ||
		die "git init failed"
	wb="$(hubcli workbench create --folder "$KIT_HOME/repo" --json 2>>"$KIT_HOME/cli.log" </dev/null | json_field id)"
	[ -n "$wb" ] || die "workbench create printed no id"
	# The stub claude: bracketed paste on, the Stop hook (idle) reported,
	# marked ready, its raw terminal input appended to typed. It stays a
	# shell (no exec) so cleanup finds it by its path.
	cat >"$KIT_HOME/stub/claude" <<EOF
#!/bin/sh
[ "\$1" = "--session-id" ] || exit 0
printf '\033[?2004h'
printf '{"hook_event_name":"Stop","session_id":"%s"}' "\$2" | '$KIT_BIN' workbench session-state --workbench $wb
stty raw -echo
: > '$KIT_HOME/ready'
cat >> '$KIT_HOME/typed'
EOF
	chmod 0755 "$KIT_HOME/stub/claude"
	write_atomic "$KIT_DIR/hub.json" \
		"{\"mode\":\"$mode\",\"workbench_id\":$wb,\"typed\":\"$KIT_HOME/typed\",\"ready\":\"$KIT_HOME/ready\"}"

	mkfifo "$KIT_HOME/pair.in" || die "mkfifo failed"
	set -m
	hubcli hub pair --json --stream <"$KIT_HOME/pair.in" >"$KIT_HOME/pair.out" 2>"$KIT_HOME/pair.err" &
	PAIRPID=$!
	set +m
	exec 3>"$KIT_HOME/pair.in"
	KIT_FD=1
	if ! kit_until 60 "pairing QR" kit_pair_has qr; then
		cat "$KIT_HOME/pair.out" "$KIT_HOME/pair.err" >&2
		die "hub pair printed no QR"
	fi
	write_atomic "$KIT_DIR/pair.url" "$(grep -E '"event":[[:space:]]*"qr"' "$KIT_HOME/pair.out" | head -n 1 | json_field url)"

	kitcmd="${RELAY_INTEROP_KIT_CMD:-make -C '$ROOT' kit-test FILTER='^WatchtowerHostedRelayTests.GoHubInteropTests'}"
	echo "relay-interop: running the Kit suite: $kitcmd" >&2
	set -m
	WT_RELAY_INTEROP_URL="$ORIGIN" WT_HUB_INTEROP_DIR="$KIT_DIR" sh -c "$kitcmd" </dev/null &
	KPID=$!
	set +m

	kit_handoff
	hrc=$?
	if [ "$hrc" -ne 0 ]; then
		echo "relay-interop: FAIL (pairing); daemon log tail:" >&2
		tail -n 40 "$KIT_HOME/daemon.log" >&2
		return "$hrc"
	fi
	wait "$KPID"
	rc=$?
	KPID=""
	[ "$rc" -eq 0 ] || echo "relay-interop: FAIL (Kit suite, exit $rc)" >&2
	return "$rc"
}

# kit_cleanup stops everything kit_run started, newest first.
kit_cleanup() {
	[ -n "$KIT_HOME" ] || return 0
	if [ -n "$KPID" ]; then
		stop_group "$KPID"
		KPID=""
	fi
	kit_confirm false
	if [ -n "$PAIRPID" ]; then
		stop_group "$PAIRPID"
		PAIRPID=""
	fi
	if [ -n "$DPID" ]; then
		bounded 15 hubcli sync stop
		stop_group "$DPID"
		DPID=""
	fi
	if [ -n "$SHPID" ]; then
		stop_group "$SHPID"
		SHPID=""
	fi
	# A session host the daemon relaunched after ours idled out (its own
	# session, not our group) and the stub sessions it hosted.
	pkill -TERM -f -- "session-host --socket $KIT_SOCK" 2>/dev/null
	pkill -TERM -f -- "$KIT_HOME/" 2>/dev/null
	sleep 0.5
	pkill -KILL -f -- "session-host --socket $KIT_SOCK" 2>/dev/null
	pkill -KILL -f -- "$KIT_HOME/" 2>/dev/null
	if [ "${RELAY_INTEROP_KEEP:-}" = 1 ]; then
		echo "relay-interop: kept $KIT_HOME" >&2
	else
		rm -rf "$KIT_HOME"
	fi
	KIT_HOME=""
}

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
# The stand must be the dev environment: /dev/* answers 404 everywhere else.
# An unknown phone gets 404 too, so probe with a malformed body (400).
code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -d '{}' "$ORIGIN/dev/account")"
if [ "$code" = 404 ] || [ "$code" = 000 ]; then
	die "the stand has no /dev/* endpoints (HTTP $code): it is not running with RELAY_ENV=dev"
fi

cd "$ROOT" || exit 1
if [ "$KIT" = 1 ]; then
	kit_run
	exit $?
fi
set -m
go test -count=1 -tags interop -run "$RUN" -v ./internal/hub -relay="$ORIGIN" -relay-control-pid=$$ </dev/null &
GOPID=$!
set +m

rc=0
while :; do
	wait "$GOPID"
	rc=$?
	# A restart only while the tests still run (wait was cut short by the
	# signal); a failed restart keeps GOPID so cleanup stops the tests.
	if [ "$RESTART" = 1 ] && kill -0 "$GOPID" 2>/dev/null; then
		RESTART=0
		echo "relay-interop: restarting the stand (asked by a test)" >&2
		stop_wrangler
		if ! start_wrangler; then
			echo "relay-interop: the stand did not restart; stopping the tests" >&2
			rc=1
			break
		fi
		continue
	fi
	GOPID="" # the tests exited
	break
done
if [ "$rc" -ne 0 ]; then
	echo "relay-interop: FAIL (exit $rc); wrangler log tail:" >&2
	tail -n 60 "$LOG" >&2
fi
exit "$rc"
