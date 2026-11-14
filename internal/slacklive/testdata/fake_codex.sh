#!/bin/sh
# Fake codex exec --json child. SCENARIO: ok fail none hang. ARGSFILE: one line of argv per run. WARM_FIXTURE: cache file the warm-up run writes. PIDFILE as in fake_claude.sh.
[ -n "$PIDFILE" ] && echo $$ > "$PIDFILE"
cat > /dev/null
[ -n "$ARGSFILE" ] && echo "$*" >> "$ARGSFILE"
case "$*" in
  *tools.slack_list_workspaces.enabled=true*) ;;
  *)  # the warm-up run: no tool callable; WARM_FIXTURE stands in for Codex filling its apps cache
    if [ -n "$WARM_FIXTURE" ] && [ -n "$CODEX_HOME" ]; then
      mkdir -p "$CODEX_HOME/cache/codex_apps_tools" && cp "$WARM_FIXTURE" "$CODEX_HOME/cache/codex_apps_tools/warm.json"
    fi
    echo '{"type":"turn.completed"}'; exit 0 ;;
esac
echo '{"type":"thread.started","thread_id":"x"}'
case "$SCENARIO" in
  ok) echo '{"type":"item.completed","item":{"type":"mcp_tool_call","server":"codex_apps","tool":"slack.slack_list_workspaces","status":"completed","result":{"content":[{"type":"text","text":"Action completed."}],"structured_content":{"ok":true,"teams":[{"id":"TACME12345","name":"Acme"}],"response_metadata":{"next_cursor":""}}}}}' ;;
  fail) echo '{"type":"item.completed","item":{"type":"mcp_tool_call","server":"codex_apps","tool":"slack.slack_list_workspaces","status":"failed","error":{"message":"Unknown tool"}}}' ;;
  hang) [ -n "$READY" ] && echo ready > "$READY"; sleep 60 ;;
esac
echo '{"type":"turn.completed"}'
