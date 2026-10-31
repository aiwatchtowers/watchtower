#!/bin/bash
# Copies the hosted relay's Go client and generated proto into
# internal/hub/transport/relay/{client,relayv1}, pinned to one relay commit
# (Go hub design §6.1; the same rule as the Kit's copy, ask #734).
#
#   scripts/relay-go.sh <relay checkout> [<commit>]
#   make relay-go RELAY=../relay [REF=<commit>]
#
# <commit> defaults to the commit pinned in internal/hub/transport/relay/VERSION;
# pass a new one to move the pin. The relay checkout must be clean and its HEAD
# must be exactly that commit (check it out, or use a `git worktree` of it):
# a dirty or unpinned source is refused. It copies client/{client,ws,client_test}.go
# and gen/relay/v1/*.go, rewrites their import paths to this module, writes
# VERSION = "<commit> <commit date, ISO 8601>" and gofmts the copy.
#
# Public CI never runs this: the copy is committed and builds on its own.
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
	echo "usage: $0 <relay checkout> [<commit>]" >&2
	exit 2
fi
RELAY="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/internal/hub/transport/relay"
REF="${2:-}"
if [ -z "$REF" ]; then
	if [ ! -f "$DEST/VERSION" ]; then
		echo "relay-go: no REF given and no pinned VERSION file" >&2
		exit 2
	fi
	REF="$(cut -d' ' -f1 "$DEST/VERSION")"
fi

if ! git -C "$RELAY" rev-parse --git-dir >/dev/null 2>&1; then
	echo "relay-go: $RELAY is not a git checkout" >&2
	exit 1
fi
if [ -n "$(git -C "$RELAY" status --porcelain)" ]; then
	echo "relay-go: $RELAY has uncommitted changes; refusing a dirty source" >&2
	exit 1
fi
WANT="$(git -C "$RELAY" rev-parse --verify --quiet "$REF^{commit}" || true)"
HEAD="$(git -C "$RELAY" rev-parse HEAD)"
if [ -z "$WANT" ]; then
	echo "relay-go: $REF is not a commit of $RELAY" >&2
	exit 1
fi
if [ "$HEAD" != "$WANT" ]; then
	echo "relay-go: $RELAY is at $HEAD, not the pinned $WANT; refusing an unpinned source" >&2
	exit 1
fi

mkdir -p "$DEST/client" "$DEST/relayv1"
rm -f "$DEST"/client/*.go "$DEST"/relayv1/*.go
for f in client.go ws.go client_test.go; do
	cp "$RELAY/client/$f" "$DEST/client/$f"
done
cp "$RELAY"/gen/relay/v1/*.go "$DEST/relayv1/"

# Only whole import paths are rewritten: relay.pb.go's raw descriptor also
# carries the go_package string, and changing its length would corrupt it.
for f in "$DEST"/client/*.go "$DEST"/relayv1/*.go; do
	sed -i.bak -E \
		-e 's#"github.com/aiwatchtowers/relay/gen/relay/v1"$#"watchtower/internal/hub/transport/relay/relayv1"#' \
		-e 's#"github.com/aiwatchtowers/relay/client"$#"watchtower/internal/hub/transport/relay/client"#' \
		"$f"
	rm -f "$f.bak"
done
if grep -nE '^[[:space:]]*([A-Za-z0-9_]+[[:space:]]+)?"github.com/aiwatchtowers/relay' "$DEST"/client/*.go "$DEST"/relayv1/*.go; then
	echo "relay-go: an import of the relay module was left unrewritten" >&2
	exit 1
fi

echo "$WANT $(git -C "$RELAY" show -s --format=%cI "$WANT")" >"$DEST/VERSION"
gofmt -w "$DEST/client" "$DEST/relayv1"
echo "relay-go: copied relay ${WANT:0:7} into $DEST"
