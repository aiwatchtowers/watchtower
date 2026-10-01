#!/bin/sh
# Fake `claude` for internal/chat backend tests; behaviour by $FAKE_MODE:
#   normal (default) · slow (first turn never finishes until interrupted)
#   ignore_interrupt (first turn never finishes and ignores the interrupt)
#   crash_once (dies on the first user message ever) · lost (--resume rejected
#   on stderr) · lost_result (--resume rejected only in the result's "errors";
#   lost_result_linger: the same, but the child stays alive 2 s after it)
#   stubborn (ignores SIGTERM and stdin EOF) · grandchild (leaves a child behind)
#   internal_tool (runs Claude's ToolSearch before a watchtower tool)
#   noread (never reads stdin, so a large turn blocks the writer)
#   error_once (the first user message ever ends in an error result)
#   error_always (every user message ends in an error result)
# The error results carry $FAKE_ERROR (default "request too large").
# With $FAKE_INIT_SID set, every user message is first answered by a
# system/init line carrying that session id (as the real CLI does).
# Appends argv (one arg per line, runs separated by "--") to $FAKE_ARGV and
# every stdin line to $FAKE_STDIN (and its physical cwd to $FAKE_CWD). "Once" modes key on the $FAKE_MARK file.
{ for a in "$@"; do printf '%s\n' "$a"; done; echo "--"; } >> "$FAKE_ARGV"
[ -n "$FAKE_CWD" ] && pwd -P >> "$FAKE_CWD"

resumed=no
for a in "$@"; do [ "$a" = "--resume" ] && resumed=yes; done

if [ "$FAKE_MODE" = "lost" ] && [ "$resumed" = yes ]; then
  echo "No conversation found with session ID: gone" >&2
  exit 1
fi
if { [ "$FAKE_MODE" = "lost_result" ] || [ "$FAKE_MODE" = "lost_result_linger" ]; } && [ "$resumed" = yes ]; then
  printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"00000000-0000-4000-8000-000000000000","usage":{"input_tokens":0,"output_tokens":0},"errors":["No conversation found with session ID: gone"]}'
  [ "$FAKE_MODE" = "lost_result_linger" ] && sleep 2
  exit 1
fi
if [ "$FAKE_MODE" = "stubborn" ]; then
  trap '' TERM
  echo $$ > "$FAKE_PID"
  sleep 300 &
  echo $! > "$FAKE_CHILD_PID"
  while :; do sleep 1; done
fi
if [ "$FAKE_MODE" = "noread" ]; then
  while :; do sleep 1; done
fi
if [ "$FAKE_MODE" = "grandchild" ]; then
  sleep 300 &
  echo $! > "$FAKE_CHILD_PID"
fi

first_time() {
  if [ -f "$FAKE_MARK" ]; then return 1; fi
  : > "$FAKE_MARK"
  return 0
}

tool_calls() {
  printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"ts1","name":"ToolSearch"}}}'
  printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_stop","index":1}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"ts1","content":"loaded"}]}}'
  printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"lt1","name":"mcp__watchtower__list_targets"}}}'
  printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_stop","index":1}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"lt1","content":"[]"}]}}'
}

reply() {
  printf '%s\n' '{"type":"stream_event","event":{"type":"message_start","message":{"model":"fake-model"}}}'
  [ "$FAKE_MODE" = "internal_tool" ] && tool_calls
  printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}'
  printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"%s"}}}\n' "$1"
  printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_stop","index":0}}'
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"sess-fake","usage":{"input_tokens":3,"output_tokens":2}}'
}

n=0
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$FAKE_STDIN"
  case "$line" in
    *'"subtype":"interrupt"'*)
      [ "$FAKE_MODE" = "ignore_interrupt" ] && continue
      printf '%s\n' '{"type":"control_response","response":{"subtype":"success"}}'
      printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-fake","usage":{"input_tokens":1,"output_tokens":0}}'
      ;;
    *'"type":"user"'*)
      n=$((n+1))
      [ -n "$FAKE_INIT_SID" ] && printf '{"type":"system","subtype":"init","session_id":"%s"}\n' "$FAKE_INIT_SID"
      case "$FAKE_MODE" in
        crash_once)
          if first_time; then exit 3; fi ;;
        error_once|error_always)
          if [ "$FAKE_MODE" = error_always ] || first_time; then
            printf '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-fake","usage":{"input_tokens":0,"output_tokens":0},"errors":["%s"]}\n' "${FAKE_ERROR:-request too large}"
            continue
          fi ;;
        slow|ignore_interrupt)
          if first_time; then
            printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}}'
            continue
          fi ;;
      esac
      reply "turn $n"
      ;;
  esac
done
