#!/bin/bash
# Copies the hosted relay's relay.proto into the Kit and generates its Swift
# (WatchtowerKit/Sources/WatchtowerRelayProto/{relay.proto,relay.pb.swift,VERSION}),
# pinned to one relay commit — the Kit's twin of scripts/relay-go.sh (#1239).
#
#   scripts/relay-proto.sh <relay checkout> [<commit>]
#   make relay-proto RELAY=../relay [REF=<commit>]
#
# <commit> defaults to the commit pinned in the Kit's VERSION; pass a new one
# to move the pin. The relay checkout must be clean and its HEAD must be
# exactly that commit (check it out, clone it, or use a `git worktree` of it):
# a dirty or unpinned source is refused.
#
# Tools: `buf` on PATH (`brew install bufbuild/buf/buf`, or the release binary
# from https://github.com/bufbuild/buf/releases). protoc-gen-swift is built
# here from the swift-protobuf checkout the Kit resolves, so the generator is
# always the tag pinned `exact:` in WatchtowerKit/Package.swift; VERSION line 2
# records it. No protoc is needed (buf compiles the proto itself).
#
# Writes VERSION = "<commit> <commit date, ISO 8601>\nprotoc-gen-swift <tag>".
# Public CI never runs this: the generated file is committed.
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
	echo "usage: $0 <relay checkout> [<commit>]" >&2
	exit 2
fi
RELAY="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/WatchtowerKit"
DEST="$KIT/Sources/WatchtowerRelayProto"
REF="${2:-}"
if [ -z "$REF" ]; then
	if [ ! -f "$DEST/VERSION" ]; then
		echo "relay-proto: no REF given and no pinned VERSION file" >&2
		exit 2
	fi
	REF="$(head -n1 "$DEST/VERSION" | cut -d' ' -f1)"
fi

if ! git -C "$RELAY" rev-parse --git-dir >/dev/null 2>&1; then
	echo "relay-proto: $RELAY is not a git checkout" >&2
	exit 1
fi
if [ -n "$(git -C "$RELAY" status --porcelain)" ]; then
	echo "relay-proto: $RELAY has uncommitted changes; refusing a dirty source" >&2
	exit 1
fi
WANT="$(git -C "$RELAY" rev-parse --verify --quiet "$REF^{commit}" || true)"
HEAD="$(git -C "$RELAY" rev-parse HEAD)"
if [ -z "$WANT" ]; then
	echo "relay-proto: $REF is not a commit of $RELAY" >&2
	exit 1
fi
if [ "$HEAD" != "$WANT" ]; then
	echo "relay-proto: $RELAY is at $HEAD, not the pinned $WANT; refusing an unpinned source" >&2
	exit 1
fi

if ! command -v buf >/dev/null 2>&1; then
	echo "relay-proto: buf is not on PATH; install it: brew install bufbuild/buf/buf" >&2
	exit 1
fi
RELAY="$(cd "$RELAY" && pwd)"
PROTO="$RELAY/proto/relay/v1/relay.proto"
if [ ! -f "$PROTO" ]; then
	echo "relay-proto: $RELAY has no proto/relay/v1/relay.proto" >&2
	exit 1
fi

TAG="$(sed -n -E 's#.*apple/swift-protobuf", exact: "([^"]+)".*#\1#p' "$KIT/Package.swift")"
if [ -z "$TAG" ]; then
	echo "relay-proto: WatchtowerKit/Package.swift pins no swift-protobuf tag (exact:)" >&2
	exit 1
fi

OUT="$(mktemp -d)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$OUT" "$BUILD"' EXIT

(cd "$KIT" && swift package resolve)
SP="$KIT/.build/checkouts/swift-protobuf"
# Built in a temp scratch path: nothing is written into the Kit's checkout.
swift build -c release --product protoc-gen-swift --package-path "$SP" --scratch-path "$BUILD"
PLUGIN="$(swift build -c release --product protoc-gen-swift --package-path "$SP" --scratch-path "$BUILD" --show-bin-path)/protoc-gen-swift"

TEMPLATE="{\"version\":\"v2\",\"plugins\":[{\"local\":\"$PLUGIN\",\"out\":\"$OUT\",\"opt\":[\"Visibility=Public\",\"FileNaming=DropPath\"]}]}"
(cd "$RELAY" && buf generate "$RELAY/proto" --path "$PROTO" --template "$TEMPLATE")

if [ ! -f "$OUT/relay.pb.swift" ]; then
	echo "relay-proto: buf generate produced no relay.pb.swift" >&2
	exit 1
fi
mkdir -p "$DEST"
cp "$PROTO" "$DEST/relay.proto"
cp "$OUT/relay.pb.swift" "$DEST/relay.pb.swift"
{
	echo "$WANT $(git -C "$RELAY" show -s --format=%cI "$WANT")"
	echo "protoc-gen-swift $TAG"
} >"$DEST/VERSION"

echo "relay-proto: generated the Kit's relay proto from relay ${WANT:0:7} (protoc-gen-swift $TAG)"
echo "relay-proto: Kit pin $(cut -d' ' -f1 <"$DEST/VERSION" | head -n1)"
GOVER="$ROOT/internal/hub/transport/relay/VERSION"
if [ -f "$GOVER" ]; then
	echo "relay-proto: Go pin  $(cut -d' ' -f1 "$GOVER")"
else
	echo "relay-proto: Go pin  (none: no $GOVER)"
fi
