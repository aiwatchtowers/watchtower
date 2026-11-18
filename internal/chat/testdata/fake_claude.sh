#!/bin/sh
# Fake `claude` for internal/chat backend tests; behaviour by $FAKE_MODE.
# Most tests run its Go twin in process (fakeCLI, fake_claude_test.go): a
# change here goes there too (the twin also has a Go-only quota mode, and
# refuses stubborn's group and grandchild modes it cannot model). The script
# itself runs only in the tests of the process wiring (useRealProcess). The
# grandchild sleeps a day: it never ends on its own within a test run, so
# only the group kill can end it.
#   normal (default) · slow (first turn never finishes until interrupted)
#   ignore_interrupt (first turn never finishes and ignores the interrupt)
#   crash_once (dies on the first user message ever)
#   crash_always (dies on every user message; stderr = $FAKE_CRASH or a panic)
#   stubborn (ignores SIGTERM and stdin EOF; writes its pid to $FAKE_PID) · grandchild (leaves a child behind)
#   (both modes' child writes its pid to the FIFO $FAKE_CHILD_FIFO, so the
#   test sees it start — the line — and then waits for its exit by pid)
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
#     interrupt withdraws the open ones with control_cancel_request; with
#     $FAKE_GATE_DIE_ON_ALLOW set it dies on an allow instead.)
# Every mode answers an mcp_status control request with the k-th line of the
# file $FAKE_MCP_STATUS (an mcpServers JSON list; the last line repeats; no
# file = []).
# An interrupt with no turn open (the turn already ended — e.g. a gate turn
# finished on a deny that reached it before the interrupt) is answered with
# its control_response only, no result, as the real CLI does (2.1.302).
# The error results carry $FAKE_ERROR (default "request too large").
# With $FAKE_INIT_SID set, every user message is first answered by a
# system/init line carrying that session id (as the real CLI does), and
# $FAKE_API_KEY_SOURCE as its apiKeySource when set.
# Appends argv (one arg per line, runs separated by "--") to $FAKE_ARGV and
# every stdin line to $FAKE_STDIN (and its physical cwd to $FAKE_CWD). "Once" modes key on the $FAKE_MARK file.
{ for a in "$@"; do printf '%s\n' "$a"; done; echo "--"; } >> "$FAKE_ARGV"
# With $FAKE_PROMPT / $FAKE_MCP set, copies what it reads from the paths after
# --system-prompt-file / --mcp-config there (one run per line pair, "--" after).
prev=""
for a in "$@"; do
  [ "$prev" = "--system-prompt-file" ] && [ -n "$FAKE_PROMPT" ] && { cat "$a"; echo; echo "--"; } >> "$FAKE_PROMPT"
  [ "$prev" = "--mcp-config" ] && [ -n "$FAKE_MCP" ] && { cat "$a"; echo; echo "--"; } >> "$FAKE_MCP"
  prev=$a
done
[ -n "$FAKE_CWD" ] && pwd -P >> "$FAKE_CWD"

if [ "$FAKE_MODE" = "stubborn" ]; then
  trap '' TERM
  echo $$ > "$FAKE_PID"
  sh -c 'echo $$; exec sleep 86400' > "$FAKE_CHILD_FIFO" &
  while :; do sleep 1; done
fi
if [ "$FAKE_MODE" = "noread" ]; then
  while :; do sleep 1; done
fi
if [ "$FAKE_MODE" = "grandchild" ]; then
  sh -c 'echo $$; exec sleep 86400' > "$FAKE_CHILD_FIFO" &
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

status_n=0
# mcp_status_answer answers the mcp_status request line $1.
mcp_status_answer() {
  status_n=$((status_n+1))
  list='[]'
  if [ -n "$FAKE_MCP_STATUS" ] && [ -s "$FAKE_MCP_STATUS" ]; then
    list=$(sed -n "${status_n}p" "$FAKE_MCP_STATUS")
    [ -z "$list" ] && list=$(tail -n 1 "$FAKE_MCP_STATUS")
  fi
  printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"mcpServers":%s}}}\n' "$(field "$1" request_id)" "$list"
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
      *'"subtype":"mcp_status"'*)
        mcp_status_answer "$line"
        continue ;;
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
            *'"behavior":"allow"'*)
              [ -n "$FAKE_GATE_DIE_ON_ALLOW" ] && exit 3
              tool_result "${p#*:}" "${FAKE_GATE_RESULT:-ran}" false ;;
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
open=no # a turn was left unfinished (slow, ignore_interrupt)
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$FAKE_STDIN"
  case "$line" in
    *'"subtype":"mcp_status"'*)
      mcp_status_answer "$line" ;;
    *'"subtype":"interrupt"'*)
      [ "$FAKE_MODE" = "ignore_interrupt" ] && continue
      printf '%s\n' '{"type":"control_response","response":{"subtype":"success"}}'
      [ "$open" = yes ] && printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-fake","usage":{"input_tokens":1,"output_tokens":0}}'
      open=no
      ;;
    *'"type":"user"'*)
      n=$((n+1))
      if [ -n "$FAKE_INIT_SID$FAKE_API_KEY_SOURCE" ]; then
        auth=""; [ -n "$FAKE_API_KEY_SOURCE" ] && auth=",\"apiKeySource\":\"$FAKE_API_KEY_SOURCE\""
        printf '{"type":"system","subtype":"init","session_id":"%s"%s}\n' "${FAKE_INIT_SID:-sess-fake}" "$auth"
      fi
      case "$FAKE_MODE" in
        crash_once)
          if first_time; then exit 3; fi ;;
        exit_clean)
          # Exit 0 mid-turn with partial text and no result line (L12).
          printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}'
          printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}}'
          [ -n "$FAKE_STDERR" ] && printf '%s\n' "$FAKE_STDERR" >&2
          exit 0 ;;
        long_line)
          # A stdout line longer than the reader takes, of type
          # $FAKE_LONG_TYPE (default user, a huge tool result), in the middle
          # of a turn, which then finishes as usual — or, when that line was
          # the result itself, waits for the next message as claude does.
          printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}'
          printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"before "}}}'
          printf '{"type":"%s","pad":"' "${FAKE_LONG_TYPE:-user}"
          head -c "${FAKE_LONG_BYTES:-4096}" /dev/zero | tr '\0' 'x'
          printf '"}\n'
          [ "${FAKE_LONG_TYPE:-user}" = result ] && continue
          printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"after"}}}'
          printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_stop","index":0}}'
          printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"sess-fake","usage":{"input_tokens":3,"output_tokens":2}}'
          continue ;;
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
            open=yes
            continue
          fi ;;
      esac
      reply "turn $n"
      ;;
  esac
done
