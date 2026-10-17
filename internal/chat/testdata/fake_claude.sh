#!/bin/sh
# Fake `claude` for internal/chat backend tests; behaviour by $FAKE_MODE:
#   normal (default) · slow (first turn never finishes until interrupted)
#   ignore_interrupt (first turn never finishes and ignores the interrupt)
#   crash_once (dies on the first user message ever)
#   crash_always (dies on every user message; stderr = $FAKE_CRASH or a panic)
#   lost (--resume rejected on stderr)
#   lost_result (--resume rejected only in the result's "errors")
#   lost_result_linger (lost_result, but the child stays alive until stdin closes)
#   stubborn (ignores SIGTERM and stdin EOF) · grandchild (leaves a child behind)
#   internal_tool (runs Claude's ToolSearch before a watchtower tool)
#   noread (never reads stdin, so a large turn blocks the writer)
#   error_once (the first user message ever ends in an error result)
#   error_always (every user message ends in an error result)
#   gate (every user message runs the can_use_tool requests in the file
#     $FAKE_CLAUDE_GATE_REQUESTS, one JSON line each with "request_id",
#     "tool_name", then "input" right before a closing "tool_use_id": each is
#     preceded by its tool_use block carrying that input, all are sent before any answer is awaited, and each
#     answer gets the tool_result the CLI gives — $FAKE_GATE_RESULT (default
#     "ran") for an allow, the deny message as an error for a deny. An
#     interrupt withdraws the open ones with control_cancel_request. Writes
#     its pid to $FAKE_PID.)
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
  # Lingers until stdin closes (never reading a turn as one).
  [ "$FAKE_MODE" = "lost_result_linger" ] && cat > /dev/null
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
[ "$FAKE_MODE" = "gate" ] && echo $$ > "$FAKE_PID"
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

field() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }

tool_result() { # tool_use_id, content (JSON-string-safe), is_error
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s","is_error":%s}]}}\n' "$1" "$2" "$3"
}

# gate_turn runs the scripted permission requests; false when interrupted.
gate_turn() {
  pending=""
  while IFS= read -r req <&3; do
    rid=$(field "$req" request_id); tuid=$(field "$req" tool_use_id); tname=$(field "$req" tool_name)
    printf '{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"%s","name":"%s"}}}\n' "$tuid" "$tname"
    input=$(printf '%s' "$req" | sed -n 's/.*"input":\(.*\),"tool_use_id".*/\1/p' | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"%s"}}}\n' "$input"
    printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_stop","index":1}}'
    printf '%s\n' "$req"
    pending="$pending $rid:$tuid"
  done 3< "$FAKE_CLAUDE_GATE_REQUESTS"
  while [ -n "$pending" ] && IFS= read -r line; do
    printf '%s\n' "$line" >> "$FAKE_STDIN"
    case "$line" in
      *'"subtype":"interrupt"'*)
        for p in $pending; do
          printf '{"type":"control_cancel_request","request_id":"%s"}\n' "${p%%:*}"
          tool_result "${p#*:}" "The user doesn't want to proceed with this tool use." true
        done
        printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"interrupt","response":{"still_queued":[]}}}'
        printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-fake","usage":{"input_tokens":1,"output_tokens":0}}'
        return 1 ;;
    esac
    rest=""
    for p in $pending; do
      case "$line" in
        *"\"request_id\":\"${p%%:*}\""*)
          case "$line" in
            *'"behavior":"allow"'*) tool_result "${p#*:}" "${FAKE_GATE_RESULT:-ran}" false ;;
            *) tool_result "${p#*:}" "$(printf '%s' "$line" | sed -n 's/.*"message":"\(.*\)"}}}$/\1/p')" true ;;
          esac ;;
        *) rest="$rest $p" ;;
      esac
    done
    pending=$(printf '%s' "$rest" | sed 's/^ *//')
  done
  return 0
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
        crash_always)
          printf '%b\n' "${FAKE_CRASH:-panic: cannot decode content block}" >&2
          exit 3 ;;
        error_once|error_always)
          if [ "$FAKE_MODE" = error_always ] || first_time; then
            printf '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-fake","usage":{"input_tokens":0,"output_tokens":0},"errors":["%s"]}\n' "${FAKE_ERROR:-request too large}"
            continue
          fi ;;
        gate)
          gate_turn && reply "turn $n"
          continue ;;
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
