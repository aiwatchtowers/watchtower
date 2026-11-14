#!/bin/sh
# Fake claude stream-json child. SCENARIO: ok unknown admin rate plan timeout absent apikey deny hang.
# PIDFILE: where to write the pid. RECORD: file collecting the host's answer to a can_use_tool.
[ -n "$PIDFILE" ] && echo $$ > "$PIDFILE"
echo '{"type":"system","subtype":"init","apiKeySource":"'"${API_KEY_SRC:-none}"'"}'
SEARCH=mcp__claude_ai_Slack__slack_search_channels
tool_use() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"%s","input":{}}]}}\n' "$1"; }
can_use() { printf '{"type":"control_request","request_id":"perm-1","request":{"subtype":"can_use_tool","tool_name":"%s","tool_use_id":"t1","input":{"limit":1}}}\n' "$1"; }
tool_result() { printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":%s,"content":[{"type":"text","text":"%s"}]}]}}\n' "$1" "$2"; }
while IFS= read -r line; do
  case "$line" in
    *'"subtype":"mcp_status"'*)
      id=$(printf '%s' "$line" | sed 's/.*"request_id":"\([^"]*\)".*/\1/')
      case "$SCENARIO" in absent|apikey) servers='[]' ;; *) servers='[{"name":"claude.ai Slack","status":"connected"}]' ;; esac
      printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"mcpServers":%s}}}\n' "$id" "$servers"
      ;;
    *'"type":"user"'*)
      case "$SCENARIO" in
        hang) [ -n "$READY" ] && echo ready > "$READY"; sleep 60 ;;
        deny)
          tool_use mcp__claude_ai_Slack__slack_send_message; can_use mcp__claude_ai_Slack__slack_send_message
          IFS= read -r resp; echo "$resp" >> "$RECORD"
          echo '{"type":"result","is_error":false,"result":"done"}'; exit 0 ;;
        *)
          if [ -n "$EXTRA_CONTROL" ]; then
            echo '{"type":"control_request","request_id":"hook-1","request":{"subtype":"hook_callback"}}'
            IFS= read -r resp; echo "$resp" >> "$RECORD"
          fi
          tool_use "$SEARCH"; can_use "$SEARCH"
          IFS= read -r resp; [ -n "$RECORD" ] && echo "$resp" >> "$RECORD"
          case "$SCENARIO" in
            ok) tool_result false 'channel https://acme.slack.com/archives/C1' ;;
            unknown) tool_result true 'Unknown tool: slack_search_channels' ;;
            admin) tool_result true 'An admin must approve this app first' ;;
            rate) tool_result true 'HTTP 429 Too Many Requests' ;;
            plan) tool_result true 'This tool is not available on your plan' ;;
            timeout) tool_result true 'request timed out' ;;
          esac
          case "$SCENARIO" in
            ok) echo '{"type":"result","is_error":false,"result":"done","total_cost_usd":0.0012,"usage":{"input_tokens":120,"cache_read_input_tokens":30,"cache_creation_input_tokens":0,"output_tokens":7},"modelUsage":{"claude-haiku-5-5":{"outputTokens":7}}}' ;;
            *) echo '{"type":"result","is_error":false,"result":"done"}' ;;
          esac
          exit 0 ;;
      esac ;;
  esac
done
