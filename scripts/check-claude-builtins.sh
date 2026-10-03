#!/bin/bash
# Opt-in check of the locally installed claude CLI's built-in tools against
# what Watchtower's chat runs approve (never run in CI).
#
# Chat runs pass Claude Code an allowlist of built-ins (--tools, see
# internal/ai ChatBuiltinTools/SessionBuiltinTools) plus a deny list as
# defence in depth. The offline guards (TestChatBuiltins_*) check both
# against the pinned snapshot internal/ai/testdata/claude_builtins.txt; this
# script refreshes that comparison against a real CLI after an upgrade:
#   1. the CLI's full built-in set (--tools default) must be in the snapshot;
#   2. launched with each chat run's real argv, the CLI must expose only
#      that run's approved built-ins (proves it honours --tools).
#
# The CLI has no offline tool listing, so each of the three launches is a
# real `claude -p "ok"` run (model haiku, empty temp working directory, no
# user settings, no MCP servers, --no-session-persistence) read up to its
# stream-json init event and then killed — it may still bill a few input
# tokens. The project directory the CLI creates for the temp cwd under
# ~/.claude/projects is removed afterwards.
#
# Usage: scripts/check-claude-builtins.sh [--update]
#   --update  add built-ins missing from the snapshot to it (kept sorted); then add
#             them to the deny list in internal/ai/client.go.
set -euo pipefail

mode=check
case "${1:-}" in
"") ;;
--update) mode=update ;;
*) echo "usage: $0 [--update]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
echo "claude $(claude --version)"
WATCHTOWER_CHECK_CLAUDE_BUILTINS=$mode go test ./internal/ai -run '^TestChatBuiltins_LiveCLI$' -count=1 -v
