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
# Each recording is made in a temp dir, scrubbed there by
# internal/chat/testdata/scrub_fixtures.py --transport (zero UUIDs, /work,
# example.com; no account, path or session id), and only then copied into
# internal/transporttest/testdata/<transport>/live/: nothing unscrubbed ever
# lands in the repo. An empty recording (a CLI that is not logged in, a bad
# flag) fails the run with its stderr. codex runs on a temp CODEX_HOME
# holding only a copy of the login (auth.json), so the owner's own MCP
# servers, profiles and AGENTS.md never reach a recording.
#
# scripts/assemble-transport-fixtures.py then builds the scenario fixtures
# one level up from these recordings: a line copied as recorded stays as it
# is, an edited or made-up line carries "synthetic": true. Run the leak check
# and read the diff before committing.
set -euo pipefail
repo=$(pwd)
out="$repo/internal/transporttest/testdata"
scrub="$repo/internal/chat/testdata/scrub_fixtures.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rec_dir="$work/rec"
recorded=()
failed=()

# check <file> <stderr file>: an empty recording is a failure, named with
# its stderr (a non-zero exit alone is not: claude's max-turns run exits 1).
check() {
  recorded+=("$1")
  if [ ! -s "$1" ]; then
    failed+=("$(basename "$1"): $(head -c 300 "$2" 2>/dev/null)")
  fi
}

# An empty cwd: no project instructions are loaded and no repo path leaks.
mkdir -p "$work/cwd0"

# The watchtower MCP server on an empty temp database, for the tool runs.
if [ -n "${WATCHTOWER_LIVE_CLAUDE:-}${WATCHTOWER_LIVE_CODEX:-}" ]; then
  (cd "$repo" && go build -o "$work/watchtower" .)
fi

# ---- claude: the one-shot (ai.Client) and batch (digest) shapes ----------
if [ -n "${WATCHTOWER_LIVE_CLAUDE:-}" ]; then
  mkdir -p "$rec_dir/claude"
  cat > "$work/mcp.json" <<JSON
{"mcpServers":{"watchtower":{"command":"$work/watchtower","args":["mcp","--db-path","$work/wt.db"]}}}
JSON
  base=(-p --model haiku --setting-sources project,local --strict-mcp-config --no-session-persistence)
  tools=(--mcp-config "$work/mcp.json" --allowedTools mcp__watchtower --tools "")
  rec() { # rec <name> <prompt> <claude args...>
    local name=$1 prompt=$2; shift 2
    local f="$rec_dir/claude/$name.jsonl"
    (cd "$work/cwd0" && printf '%s' "$prompt" | claude "$@" > "$f" 2> "$f.err") || true
    check "$f" "$f.err"
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
  mkdir -p "$rec_dir/codex" "$work/codex_home"
  cp "${CODEX_HOME:-$HOME/.codex}/auth.json" "$work/codex_home/auth.json"
  exec_args=(exec --json --ephemeral --skip-git-repo-check -c approval_policy=never -c sandbox_mode=read-only)
  mcp=(-c "mcp_servers.watchtower={command=\"$work/watchtower\",args=[\"mcp\",\"--db-path\",\"$work/wt.db\"],default_tools_approval_mode=\"approve\"}")
  rec_codex() { # rec_codex <name> <prompt> <codex args...>
    local name=$1 prompt=$2; shift 2
    local f="$rec_dir/codex/$name.jsonl"
    (cd "$work/cwd0" && printf '%s' "$prompt" | CODEX_HOME="$work/codex_home" "$codex_bin" "$@" - > "$f" 2> "$f.err") || true
    check "$f" "$f.err"
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
  mkdir -p "$rec_dir/ollama"
  body() { printf '{"model":"%s","stream":%s,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"Reply with exactly three words."}]}' "$model" "$1"; }
  for kind in sse json; do
    f="$rec_dir/ollama/plain_$kind.jsonl"
    stream=false; [ "$kind" = sse ] && stream=true
    curl -fsSN "$url/v1/chat/completions" -d "$(body $stream)" > "$f" 2> "$f.err" || true
    check "$f" "$f.err"
  done
fi

if [ ${#recorded[@]} -eq 0 ]; then
  echo "nothing recorded: set WATCHTOWER_LIVE_CLAUDE=1, WATCHTOWER_LIVE_CODEX=1 or WATCHTOWER_LIVE_OLLAMA=1" >&2
  exit 1
fi
if [ ${#failed[@]} -gt 0 ]; then
  printf 'recording failed: %s\n' "${failed[@]}" >&2
  exit 1
fi
python3 "$scrub" --transport "$work" "${recorded[@]}"
for f in "${recorded[@]}"; do
  transport=$(basename "$(dirname "$f")")
  mkdir -p "$out/$transport/live"
  cp "$f" "$out/$transport/live/"
done
echo "recorded:"; (cd "$out" && wc -l */live/*.jsonl)
