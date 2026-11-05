#!/usr/bin/env bash
# Records the live-CLI fixtures of the transport contract suite
# (internal/transporttest). Opt-in per transport, on a development machine:
#
#   WATCHTOWER_LIVE_CLAUDE=1 WATCHTOWER_LIVE_CODEX=1 bash scripts/record-transport-fixtures.sh
#
# WATCHTOWER_LIVE_CLAUDE needs a logged-in `claude`; WATCHTOWER_LIVE_CODEX a
# logged-in `codex` (CODEX_BIN overrides the lookup); WATCHTOWER_LIVE_OLLAMA
# a running Ollama at OLLAMA_URL (default http://localhost:11434) and
# OLLAMA_MODEL. It extends internal/chat/testdata/record_fixtures.sh (whose
# warm-chat fixtures the suite reuses) with the one-shot, batch and codex
# shapes.
#
# Each recording lands in internal/transporttest/testdata/<transport>/live/
# and is scrubbed at once by internal/chat/testdata/scrub_fixtures.py
# --transport (zero UUIDs, /work, example.com; no account, path or session
# id). The scenario fixtures one level up are assembled from these
# recordings by hand: a line copied as recorded stays as it is, an edited or
# made-up line carries "synthetic": true. Run the leak check and read the
# diff before committing.
set -euo pipefail
repo=$(pwd)
out="$repo/internal/transporttest/testdata"
scrub="$repo/internal/chat/testdata/scrub_fixtures.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
recorded=()

# An empty cwd: no project instructions are loaded and no repo path leaks.
mkdir -p "$work/cwd0"

# The watchtower MCP server on an empty temp database, for the tool runs.
if [ -n "${WATCHTOWER_LIVE_CLAUDE:-}${WATCHTOWER_LIVE_CODEX:-}" ]; then
  (cd "$repo" && go build -o "$work/watchtower" .)
fi

# ---- claude: the one-shot (ai.Client) and batch (digest) shapes ----------
if [ -n "${WATCHTOWER_LIVE_CLAUDE:-}" ]; then
  mkdir -p "$out/claude/live"
  cat > "$work/mcp.json" <<JSON
{"mcpServers":{"watchtower":{"command":"$work/watchtower","args":["mcp","--db-path","$work/wt.db"]}}}
JSON
  base=(-p --model haiku --setting-sources project,local --strict-mcp-config --no-session-persistence)
  tools=(--mcp-config "$work/mcp.json" --allowedTools mcp__watchtower --tools "")
  rec() { # rec <name> <prompt> <claude args...>
    local name=$1 prompt=$2; shift 2
    (cd "$work/cwd0" && printf '%s' "$prompt" | claude "$@" > "$out/claude/live/$name.jsonl") || true
    recorded+=("$out/claude/live/$name.jsonl")
  }
  rec plain_stream "Reply with exactly three words." "${base[@]}" --tools "" --output-format stream-json --verbose
  rec plain_json "Reply with exactly three words." "${base[@]}" --tools "" --output-format json
  rec tool_ok "Say one short sentence, then call the list_targets tool once with no arguments, then say how many targets it returned." \
    "${base[@]}" "${tools[@]}" --output-format stream-json --verbose
  rec tool_failed "Call the get_target tool once with id 999999, then say in one sentence what happened." \
    "${base[@]}" "${tools[@]}" --output-format stream-json --verbose
  rec max_turns "Call the list_targets tool, then call it again, then answer." \
    "${base[@]}" "${tools[@]}" --max-turns 1 --output-format stream-json --verbose
fi

# ---- codex: exec --json (codex.Client and CodexGenerator) ----------------
if [ -n "${WATCHTOWER_LIVE_CODEX:-}" ]; then
  codex_bin=${CODEX_BIN:-codex}
  mkdir -p "$out/codex/live"
  exec_args=(exec --json --ephemeral --skip-git-repo-check -c approval_policy=never -c sandbox_mode=read-only)
  mcp=(-c "mcp_servers.watchtower={command=\"$work/watchtower\",args=[\"mcp\",\"--db-path\",\"$work/wt.db\"],default_tools_approval_mode=\"approve\"}")
  rec_codex() { # rec_codex <name> <prompt> <codex args...>
    local name=$1 prompt=$2; shift 2
    (cd "$work/cwd0" && printf '%s' "$prompt" | "$codex_bin" "$@" - > "$out/codex/live/$name.jsonl") || true
    recorded+=("$out/codex/live/$name.jsonl")
  }
  rec_codex plain "Reply with exactly three words." "${exec_args[@]}"
  rec_codex tool_ok "Say one short sentence, then call the watchtower list_targets tool once with no arguments, then say how many targets it returned." \
    "${exec_args[@]}" "${mcp[@]}"
  rec_codex tool_failed "Call the watchtower get_target tool once with id 999999, then say in one sentence what happened." \
    "${exec_args[@]}" "${mcp[@]}"
  rec_codex parallel_tools "Call the watchtower list_targets tool three times in parallel in one response, then answer with the three counts." \
    "${exec_args[@]}" "${mcp[@]}"
fi

# ---- ollama: the OpenAI-compatible endpoint ------------------------------
if [ -n "${WATCHTOWER_LIVE_OLLAMA:-}" ]; then
  url=${OLLAMA_URL:-http://localhost:11434}
  model=${OLLAMA_MODEL:?set OLLAMA_MODEL}
  mkdir -p "$out/ollama/live"
  body() { printf '{"model":"%s","stream":%s,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"Reply with exactly three words."}]}' "$model" "$1"; }
  curl -sN "$url/v1/chat/completions" -d "$(body true)" > "$out/ollama/live/plain_sse.jsonl"
  curl -s "$url/v1/chat/completions" -d "$(body false)" > "$out/ollama/live/plain_json.jsonl"
  recorded+=("$out/ollama/live/plain_sse.jsonl" "$out/ollama/live/plain_json.jsonl")
fi

if [ ${#recorded[@]} -eq 0 ]; then
  echo "nothing recorded: set WATCHTOWER_LIVE_CLAUDE=1, WATCHTOWER_LIVE_CODEX=1 or WATCHTOWER_LIVE_OLLAMA=1" >&2
  exit 1
fi
python3 "$scrub" --transport "$work" "${recorded[@]}"
echo "recorded:"; wc -l "${recorded[@]}"
