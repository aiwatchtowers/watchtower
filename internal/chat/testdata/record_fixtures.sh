#!/usr/bin/env bash
# Records the Claude stream-json fixtures replayed by claude_translate_test.go.
# Needs a logged-in `claude` CLI (2.1.x) and Go. Run from the repo root:
#   bash internal/chat/testdata/record_fixtures.sh
# The output is scrubbed at the end (scrub_fixtures.py: the public repo gets no
# connectors, skills, home paths or account details); still eyeball the diff.
set -euo pipefail
repo=$(pwd)
out="$repo/internal/chat/testdata"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The production isolation (internal/chat/claude_backend.go): only the MCP
# servers passed here, and an empty cwd so no project CLAUDE.md is loaded.
flags=(-p --input-format stream-json --output-format stream-json
  --include-partial-messages --verbose --setting-sources project,local --strict-mcp-config)

# user <text> — one stream-json user message (texts here contain no quotes).
user() { printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}\n' "$1"; }

mkdir -p "$work/cwd0" && cd "$work/cwd0"

# 1. Plain text, one turn.
user "Reply with exactly three words." | claude "${flags[@]}" --model haiku > "$out/claude_text.jsonl"

# 2. Extended thinking: MAX_THINKING_TOKENS turns thinking blocks on.
user "What is 17 times 23? Think first, then answer with the number only." \
  | MAX_THINKING_TOKENS=2048 claude "${flags[@]}" --model sonnet > "$out/claude_thinking.jsonl"

# 3. One MCP tool call against `watchtower mcp` on an empty temp database.
(cd "$repo" && go build -o "$work/watchtower" .)
cat > "$work/mcp.json" <<JSON
{"mcpServers":{"watchtower":{"command":"$work/watchtower","args":["mcp","--db-path","$work/wt.db"]}}}
JSON
user "Call the list_targets tool once with no arguments, then say how many targets it returned." \
  | claude "${flags[@]}" --model haiku --mcp-config "$work/mcp.json" \
      --allowedTools mcp__watchtower \
      --disallowedTools "Bash,Read,Grep,Glob,LS,WebFetch,WebSearch,Edit,Write,Task" \
  > "$out/claude_tool.jsonl"

# 4. Interrupt mid-turn, then a second turn in the same process.
{
  user "Write a 600-word essay about lighthouses."
  sleep 4
  printf '{"type":"control_request","request_id":"r1","request":{"subtype":"interrupt"}}\n'
  sleep 3
  user "Now reply with just: ok"
  sleep 20
} | claude "${flags[@]}" --model haiku > "$out/claude_interrupt.jsonl"

# 5. --resume of a session that does not exist (the session_lost signal).
user "hi" | claude "${flags[@]}" --model haiku --resume 00000000-0000-4000-8000-000000000000 \
  > "$out/claude_resume_missing.jsonl" 2> "$out/claude_resume_missing.stderr" || true

# Scrub the recording environment out of every fixture.
python3 "$out/scrub_fixtures.py" "$out"/claude_*.jsonl
sed -i '' "s#$HOME#/HOME#g" "$out"/claude_*.jsonl "$out"/claude_*.stderr
echo "recorded:"; wc -l "$out"/claude_*
