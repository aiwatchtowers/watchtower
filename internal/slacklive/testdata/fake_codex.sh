#!/bin/sh
# Fake codex exec --json child. SCENARIO: ok fail none. PIDFILE as in fake_claude.sh.
[ -n "$PIDFILE" ] && echo $$ > "$PIDFILE"
cat > /dev/null
echo '{"type":"thread.started","thread_id":"x"}'
case "$SCENARIO" in
  ok) echo '{"type":"item.completed","item":{"type":"mcp_tool_call","server":"codex_apps","tool":"slack.slack_list_workspaces","status":"completed","result":{"content":[{"type":"text","text":"workspace TACME12345 Acme"}]}}}' ;;
  fail) echo '{"type":"item.completed","item":{"type":"mcp_tool_call","server":"codex_apps","tool":"slack.slack_list_workspaces","status":"failed","error":{"message":"Unknown tool"}}}' ;;
  hang) [ -n "$READY" ] && echo ready > "$READY"; sleep 60 ;;
esac
echo '{"type":"turn.completed"}'
