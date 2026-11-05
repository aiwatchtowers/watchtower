#!/bin/bash
# Opt-in checks of the locally installed codex CLI against the feature flags
# Watchtower turns off on the codex runs it launches itself (never run in CI).
#
# Every Watchtower-launched codex run (batch, chat, code questions, spec
# review, automation agent()) passes `-c features.<name>=false` for each name
# in internal/codex disabledFeatures (generator.go), less toolRunFeatures on
# runs with tools. The offline guard TestDisabledFeatures_MatchSnapshot pins
# that list to internal/codex/testdata/codex_features.txt; after a codex
# upgrade this script:
#   1. compares `codex features list` (local, no model call) with the
#      snapshot — a flag the CLI lists that the snapshot lacks fails;
#      --update adds it as "undecided", which the offline guard then fails
#      until it is marked off, batch or keep (and added to disabledFeatures);
#      it also renders a run's prompt with `codex debug prompt-input` (no
#      model call) to check the owner's skill list stays out of it;
#   2. with --live, also runs TestCodexLive_* — real `codex exec` runs with
#      the production argv (needs the network and the owner's codex sign-in,
#      bills a few light-model turns): the system prompt and a mounted MCP
#      tool must reach the answer, and a read-folder run must read a file.
#
# Usage: scripts/check-codex-features.sh [--update] [--live]
set -euo pipefail

mode=check
live=0
for arg in "$@"; do
	case "$arg" in
	--update) mode=update ;;
	--live) live=1 ;;
	*) echo "usage: $0 [--update] [--live]" >&2; exit 2 ;;
	esac
done

cd "$(dirname "$0")/.."
# No bare `codex` call here: the tests resolve the binary the way Watchtower
# does (codex.FindBinary: RichPATH with nvm/volta/fnm, then the login shell),
# so a codex that is only under nvm and not on this shell's PATH still runs.
WATCHTOWER_CHECK_CODEX_FEATURES=$mode go test ./internal/codex -run '^TestDisabledFeatures_' -count=1 -v
if [ "$live" = 1 ]; then
	WATCHTOWER_LIVE_CODEX=1 go test ./internal/codex -run '^TestCodexLive_' -count=1 -v
fi
