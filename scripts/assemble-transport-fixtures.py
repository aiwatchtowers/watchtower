#!/usr/bin/env python3
"""Assembles internal/transporttest/testdata/<transport>/<scenario>[.<level>].jsonl
from the scrubbed live recordings (testdata/<transport>/live/) and hand-made
lines (each carrying "synthetic": true), and testdata/never_started.jsonl.
Usage, from the repo root: python3 scripts/assemble-transport-fixtures.py .
It rewrites every assembled fixture; the session transcripts' .zst copies
are made by hand (see writeTranscript in sessions_test.go)."""
import copy
import json
import os
import sys

ROOT = sys.argv[1]
TD = os.path.join(ROOT, "internal/transporttest/testdata")
Z = "00000000-0000-0000-0000-000000000000"
PAD = "{{pad:2097152}}"
RESET = 4102444800  # 2100-01-01: far future, only "non-zero" is asserted


def live(transport, name):
    with open(os.path.join(TD, transport, "live", name)) as f:
        return [l.rstrip("\n") for l in f if l.strip()]


def j(d):
    return json.dumps(d, separators=(",", ":"), ensure_ascii=False)


def syn(d):
    d = copy.deepcopy(d)
    d["synthetic"] = True
    return j(d)


def write(transport, name, lines, header=()):
    path = os.path.join(TD, transport, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for h in header:
            f.write(h + "\n")
        for l in lines:
            f.write(l + "\n")


# ---------------------------------------------------------------- claude
CL_PLAIN = live("claude", "plain_stream.jsonl")
CL_INIT = json.loads(CL_PLAIN[0])
CL_RESULT = json.loads(CL_PLAIN[-1])
CL_MODEL = CL_INIT["model"]


def cl_usage(fresh=2, read=0, w5=0, w1=0, out=5):
    return {"input_tokens": fresh, "cache_read_input_tokens": read, "cache_creation_input_tokens": w5 + w1,
            "cache_creation": {"ephemeral_5m_input_tokens": w5, "ephemeral_1h_input_tokens": w1}, "output_tokens": out}


def cl_result(**kw):
    r = copy.deepcopy(CL_RESULT)
    r.pop("modelUsage", None)
    r.pop("model_usage_since_last_result", None)
    r.update({"usage": cl_usage(), "is_error": False, "subtype": "success", "result": "ok"})
    r.update(kw)
    return r


def cl_assistant(msg_id, content, usage=None):
    return {"type": "assistant", "message": {"model": CL_MODEL, "id": msg_id, "type": "message", "role": "assistant",
                                             "content": content, "usage": usage or cl_usage()},
            "parent_tool_use_id": None, "session_id": Z}


def cl_text(msg_id, text):
    return cl_assistant(msg_id, [{"type": "text", "text": text}])


def cl_tool_use(msg_id, tid, name, inp):
    return cl_assistant(msg_id, [{"type": "tool_use", "id": tid, "name": name, "input": inp}])


def cl_tool_result(tid, text, is_error=False):
    block = {"type": "tool_result", "tool_use_id": tid, "content": [{"type": "text", "text": text}]}
    if is_error:
        block["is_error"] = True
    return {"type": "user", "message": {"role": "user", "content": [block]}, "parent_tool_use_id": None, "session_id": Z}


def cl_fail(code, msg):
    return cl_result(is_error=True, subtype="success", result=msg, error={"type": code, "message": msg})


# warm-chat stream events
def se(event):
    return {"type": "stream_event", "event": event, "session_id": Z, "parent_tool_use_id": None}


def se_text(index, text):
    return [se({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}}),
            se({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": text}}),
            se({"type": "content_block_stop", "index": index})]


def se_tool(index, tid, name, inp):
    return [se({"type": "content_block_start", "index": index,
                "content_block": {"type": "tool_use", "id": tid, "name": name, "input": {}}}),
            se({"type": "content_block_delta", "index": index,
                "delta": {"type": "input_json_delta", "partial_json": json.dumps(inp)}}),
            se({"type": "content_block_stop", "index": index})]


def se_msg_start(msg_id):
    return se({"type": "message_start", "message": {"model": CL_MODEL, "id": msg_id, "type": "message",
                                                     "role": "assistant", "content": [], "usage": cl_usage()}})


def se_msg_end():
    return [se({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 5}}),
            se({"type": "message_stop"})]


WAIT_USER = '#! stdin-has "type":"user"'
WAIT_INTERRUPT = '#! stdin-has "subtype":"interrupt"'
INIT = syn(CL_INIT)


def chat_turn(*events):
    return [WAIT_USER, INIT] + [syn(e) for e in events]


def cl_interrupted():
    return [syn({"type": "control_response", "response": {"subtype": "success", "request_id": "interrupt-t2",
                                                          "response": {"still_queued": []}}}),
            syn(cl_result(is_error=True, subtype="error_during_execution", result="",
                          errors=["[Request interrupted by user]"], usage=cl_usage(out=1)))]


def claude():
    t = "claude"
    # plain answer: the live recordings as they are
    write(t, "plain_answer.stream.jsonl", CL_PLAIN)
    write(t, "plain_answer.batch.jsonl", live(t, "plain_json.jsonl"))
    write(t, "plain_answer.chat.jsonl",
          chat_turn(se_msg_start("msg_a"), *se_text(0, "Three words exactly."), *se_msg_end(), cl_result(result="Three words exactly.")) + ["#! hang"])
    # two messages around a tool call
    two_stream = [INIT, syn(cl_text("msg_a", "First message.")),
                  syn(cl_tool_use("msg_a", "toolu_fixture_1", "mcp__watchtower__list_targets", {})),
                  syn(cl_tool_result("toolu_fixture_1", "[]")), syn(cl_text("msg_b", "Second message.")),
                  syn(cl_result(result="Second message."))]
    write(t, "two_messages.stream.jsonl", two_stream)
    two_chat = chat_turn(se_msg_start("msg_a"), *se_text(0, "First message."),
                         *se_tool(1, "toolu_fixture_1", "mcp__watchtower__list_targets", {}), *se_msg_end(),
                         cl_tool_result("toolu_fixture_1", "[]"),
                         se_msg_start("msg_b"), *se_text(0, "Second message."), *se_msg_end(),
                         cl_result(result="Second message.")) + ["#! hang"]
    write(t, "two_messages.chat.jsonl", two_chat)
    # tool ok / failed
    write(t, "tool_ok.stream.jsonl", live(t, "tool_ok.jsonl"), ["# expect-first Checking your targets now."])
    write(t, "tool_ok.chat.jsonl", two_chat, ["# expect-first First message."])
    write(t, "tool_failed.stream.jsonl", live(t, "tool_failed.jsonl"))
    write(t, "tool_failed.chat.jsonl",
          chat_turn(se_msg_start("msg_a"), *se_tool(0, "toolu_fixture_2", "mcp__watchtower__get_target", {"id": 999999}),
                    *se_msg_end(), cl_tool_result("toolu_fixture_2", "no target with id 999999", True),
                    se_msg_start("msg_b"), *se_text(0, "That target does not exist."), *se_msg_end(),
                    cl_result(result="That target does not exist.")) + ["#! hang"])
    # a Quick Connection's read tool (L8): argv names the server
    qc_res = '{"key":"PAY-1","status":"open"}'
    write(t, "quick_connection.stream.jsonl",
          ["#! argv-has mcp__acme", INIT, syn(cl_tool_use("msg_a", "toolu_fixture_4", "mcp__acme__get_issue", {"key": "PAY-1"})),
           syn(cl_tool_result("toolu_fixture_4", qc_res)), syn(cl_text("msg_b", "PAY-1 is open.")), syn(cl_result(result="PAY-1 is open."))])
    write(t, "quick_connection.chat.jsonl",
          ["#! argv-has mcp__acme"] + chat_turn(se_msg_start("msg_a"), *se_tool(0, "toolu_fixture_4", "mcp__acme__get_issue", {"key": "PAY-1"}),
                                                *se_msg_end(), cl_tool_result("toolu_fixture_4", qc_res),
                                                se_msg_start("msg_b"), *se_text(0, "PAY-1 is open."), *se_msg_end(),
                                                cl_result(result="PAY-1 is open.")) + ["#! hang"])
    # a 2 MiB tool result line
    big = cl_tool_result("toolu_fixture_1", PAD)
    big["synthetic"] = True
    write(t, "oversized_line.stream.jsonl",
          [INIT, syn(cl_tool_use("msg_a", "toolu_fixture_1", "mcp__watchtower__list_targets", {})),
           "#! emit " + j(big), syn(cl_text("msg_b", "After the big line.")), syn(cl_result(result="After the big line."))])
    write(t, "oversized_line.chat.jsonl",
          [WAIT_USER, INIT] + [syn(e) for e in se_tool(0, "toolu_fixture_1", "mcp__watchtower__list_targets", {})] +
          ["#! emit " + j(big)] + [syn(e) for e in [se_msg_start("msg_b"), *se_text(0, "After the big line."), *se_msg_end(),
                                                    cl_result(result="After the big line.")]] + ["#! hang"])
    big_batch = [CL_INIT, cl_result(result=PAD + " After the big line.")]
    big_batch[1]["synthetic"] = True
    write(t, "oversized_line.batch.jsonl", ["#! emit " + j(big_batch)])
    # failures
    fails = {
        "fail_auth": [cl_fail("authentication_error", "OWNER-VISIBLE: Invalid API key · Please run /login")],
        "fail_model": [cl_fail("model_not_found", "OWNER-VISIBLE: model fixture-model not found")],
        "fail_rate_limit": [cl_fail("rate_limit_error", "OWNER-VISIBLE: rate limit exceeded, slow down")],
        "fail_overload": [cl_fail("overloaded_error", "OWNER-VISIBLE: Overloaded")],
        "fail_quota": [{"type": "rate_limit_event", "session_id": Z,
                        "rate_limit_info": {"status": "rejected", "resetsAt": RESET, "rateLimitType": "five_hour",
                                            "isUsingOverage": False, "overageStatus": "rejected"}},
                       cl_result(is_error=True, subtype="success", result="OWNER-VISIBLE: usage limit reached")],
    }
    for name, lines in fails.items():
        hdr = ["# expect-reset"] if name == "fail_quota" else []
        write(t, name + ".stream.jsonl", [INIT] + [syn(l) for l in lines] + ["#! exit 1"], hdr)
        batch = [CL_INIT] + copy.deepcopy(lines)
        for b in batch[1:]:
            b["synthetic"] = True
        write(t, name + ".batch.jsonl", [j(batch), "#! exit 1"], hdr)
        write(t, name + ".chat.jsonl", chat_turn(*lines) + ["#! hang"], hdr)
    # exit 0 with no result
    write(t, "no_completion.stream.jsonl", [INIT, syn(cl_text("msg_a", "First message.")), "#! exit 0"])
    write(t, "no_completion.batch.jsonl", [j([CL_INIT]), "#! exit 0"])
    write(t, "no_completion.chat.jsonl", chat_turn(se_msg_start("msg_a"), *se_text(0, "First message.")) + ["#! exit 0"])
    # interrupts (warm: the child answers and lives on)
    write(t, "interrupt_text.chat.jsonl",
          chat_turn(se_msg_start("msg_a"), *se_text(0, "First message.")) + [WAIT_INTERRUPT] + cl_interrupted() + ["#! hang"])
    write(t, "interrupt_tool.chat.jsonl",
          chat_turn(se_msg_start("msg_a"), *se_text(0, "First message."),
                    *se_tool(1, "toolu_fixture_1", "mcp__watchtower__list_targets", {}))
          + [WAIT_INTERRUPT] + cl_interrupted() + ["#! hang"])
    # timeout: a child and a grandchild that never finish
    write(t, "timeout_kill.stream.jsonl", ["#! spawn-grandchild", INIT, "#! hang"])
    write(t, "timeout_kill.batch.jsonl", ["#! spawn-grandchild", "#! hang"])
    write(t, "timeout_kill.chat.jsonl", ["#! spawn-grandchild", WAIT_USER, INIT,
                                         *[syn(e) for e in [se_msg_start("msg_a"), *se_text(0, "First message.")]], "#! hang"])
    # usage with cache
    u = cl_usage(fresh=7, read=1000, w5=100, w1=200, out=20)
    hdr = ["# expect-usage fresh=7 read=1000 write=300 out=20"]
    write(t, "usage_cache.stream.jsonl", [INIT, syn(cl_text("msg_a", "Three words exactly.")),
                                          syn(cl_result(result="Three words exactly.", usage=u))], hdr)
    ub = [CL_INIT, cl_result(result="Three words exactly.", usage=u)]
    ub[1]["synthetic"] = True
    write(t, "usage_cache.batch.jsonl", [j(ub)], hdr)
    write(t, "usage_cache.chat.jsonl", chat_turn(se_msg_start("msg_a"), *se_text(0, "Three words exactly."), *se_msg_end(),
                                                 cl_result(result="Three words exactly.", usage=u)) + ["#! hang"], hdr)
    # two turns on one warm child
    turn = [se_msg_start("msg_a"), *se_text(0, "Three words exactly."), *se_msg_end(), cl_result(result="Three words exactly.")]
    write(t, "multi_turn.chat.jsonl", chat_turn(*turn) + chat_turn(*turn) + ["#! hang"])
    # turn cap: (a) a tool call per response, stopped by the CLI after 2;
    # (b) three parallel calls in one response; (c) text only
    seq = live(t, "max_turns.jsonl")
    r = json.loads(seq[-1])
    r.update({"errors": ["Reached maximum number of turns (2)"], "num_turns": 3, "synthetic": True})
    write(t, "turn_cap_sequential.stream.jsonl",
          ["#! argv-has --max-turns 2", INIT,
           syn(cl_tool_use("msg_a", "toolu_fixture_1", "mcp__watchtower__list_targets", {})), syn(cl_tool_result("toolu_fixture_1", "[]")),
           syn(cl_tool_use("msg_b", "toolu_fixture_2", "mcp__watchtower__list_targets", {})), syn(cl_tool_result("toolu_fixture_2", "[]")),
           j(r), "#! exit 1"])
    par = cl_assistant("msg_a", [{"type": "tool_use", "id": "toolu_fixture_%d" % i, "name": "mcp__watchtower__list_targets", "input": {}} for i in (1, 2, 3)])
    write(t, "turn_cap_parallel.stream.jsonl",
          ["#! argv-has --max-turns 2", INIT, syn(par)] + [syn(cl_tool_result("toolu_fixture_%d" % i, "[]")) for i in (1, 2, 3)]
          + [syn(cl_text("msg_b", "Second message.")), syn(cl_result(result="Second message."))])
    write(t, "turn_cap_text.stream.jsonl",
          ["#! argv-has --max-turns 1", INIT, syn(cl_text("msg_a", "Second message.")), syn(cl_result(result="Second message."))])
    # capabilities
    ok_turn = [se_msg_start("msg_a"), *se_text(0, "Three words exactly."), *se_msg_end(), cl_result(result="Three words exactly.")]
    write(t, "image.chat.jsonl", ['#! stdin-has "type":"image"', INIT] + [syn(e) for e in ok_turn] + ["#! hang"])
    write(t, "pdf.chat.jsonl", ['#! stdin-has "type":"document"', INIT] + [syn(e) for e in ok_turn] + ["#! hang"])
    write(t, "read_folder.stream.jsonl", ["#! argv-has Read", INIT, syn(cl_text("msg_a", "Three words exactly.")),
                                          syn(cl_result(result="Three words exactly."))])
    write(t, "web_search.chat.jsonl",
          ["#! argv-has WebSearch"] + chat_turn(se_msg_start("msg_a"), *se_tool(0, "toolu_fixture_3", "WebSearch", {"query": "example"}),
                                                 *se_msg_end(), cl_tool_result("toolu_fixture_3", "Web search results for example"),
                                                 se_msg_start("msg_b"), *se_text(0, "Second message."), *se_msg_end(),
                                                 cl_result(result="Second message.")) + ["#! hang"])
    # a Claude Code transcript for the session rows
    write(t, "session_transcript.jsonl", [
        syn({"type": "user", "sessionId": "SESSION", "timestamp": "2026-11-05T12:00:00.000Z",
             "message": {"role": "user", "content": "please add a flag"}, "uuid": Z}),
        syn({"type": "assistant", "sessionId": "SESSION", "timestamp": "2026-11-05T12:00:01.000Z",
             "message": {"role": "assistant", "content": [{"type": "text", "text": "done, flag added"}]}, "uuid": Z}),
    ])


# ---------------------------------------------------------------- codex
def cx(d):
    return syn(d)


def cx_msg(i, text):
    return {"type": "item.completed", "item": {"id": "item_%d" % i, "type": "agent_message", "text": text}}


def cx_tool(i, tool, args, result="[]", status="completed", started=True):
    out = []
    if started:
        out.append({"type": "item.started", "item": {"id": "item_%d" % i, "type": "mcp_tool_call", "server": "watchtower",
                                                       "tool": tool, "arguments": args, "result": None, "error": None,
                                                       "status": "in_progress"}})
    out.append({"type": "item.completed", "item": {"id": "item_%d" % i, "type": "mcp_tool_call", "server": "watchtower",
                                                    "tool": tool, "arguments": args,
                                                    "result": {"content": [{"type": "text", "text": result}], "structured_content": None},
                                                    "error": None, "status": status}})
    return out


def cx_done(inp=1007, cached=1000, out=20):
    return {"type": "turn.completed", "usage": {"input_tokens": inp, "cached_input_tokens": cached,
                                                 "cache_write_input_tokens": 0, "output_tokens": out, "reasoning_output_tokens": 0}}


CX_START = [j({"type": "thread.started", "thread_id": Z}), j({"type": "turn.started"})]


def cx_failed(status, typ, msg, **extra):
    inner = {"type": "error", "status": status, "error": dict({"type": typ, "message": msg}, **extra)}
    return {"type": "turn.failed", "error": {"message": json.dumps(inner, separators=(",", ":"))}}


def codex():
    t = "codex"
    write(t, "plain_answer.jsonl", live(t, "plain.jsonl"))
    write(t, "two_messages.jsonl", CX_START + [cx(e) for e in [cx_msg(0, "First message."), *cx_tool(1, "list_targets", {}),
                                                                 cx_msg(2, "Second message."), cx_done()]])
    write(t, "tool_ok.jsonl", live(t, "tool_ok.jsonl"), ["# expect-first I’ll check the Watchtower targets now."])
    write(t, "tool_failed.jsonl", live(t, "tool_failed.jsonl"), ["# expect-first I’ll find the Watchtower tool"])
    qc = cx_tool(1, "get_issue", {"key": "PAY-1"}, result='{"key":"PAY-1","status":"open"}')
    for e in qc:
        e["item"]["server"] = "acme"
    write(t, "quick_connection.jsonl", ["#! argv-has acme"] + CX_START + [cx(e) for e in qc + [cx_msg(2, "PAY-1 is open."), cx_done()]])
    big = cx_tool(1, "list_targets", {}, result=PAD)
    write(t, "oversized_line.jsonl", CX_START + [cx(big[0]), "#! emit " + syn(big[1]), cx(cx_msg(2, "After the big line.")), cx(cx_done())])
    # failures: the captured shapes of internal/codex/testdata/turn_failures.json
    caps = {c["name"]: c for c in json.load(open(os.path.join(ROOT, "internal/codex/testdata/turn_failures.json")))}
    model = [l for l in caps["model not offered on ChatGPT sign-in"]["jsonl"].splitlines() if l.strip()]
    rate = [l for l in caps["rate limit keeps the envelope's type and status"]["jsonl"].splitlines() if l.strip()]
    write(t, "fail_model.jsonl", model + ["#! exit 1"], ["# expect-owner isn't available on your Codex account"])
    write(t, "fail_rate_limit.jsonl", CX_START + rate + ["#! exit 1"], ["# expect-owner slow down"])
    write(t, "fail_auth.jsonl", CX_START + [cx(cx_failed(401, "authentication_error", "OWNER-VISIBLE: unauthorized")), "#! exit 1"])
    write(t, "fail_overload.jsonl", CX_START + [cx(cx_failed(529, "overloaded_error", "OWNER-VISIBLE: overloaded")), "#! exit 1"])
    write(t, "fail_quota.jsonl", CX_START + [cx(cx_failed(429, "usage_limit_reached", "OWNER-VISIBLE: You have hit your usage limit.",
                                                          resets_at=RESET)), "#! exit 1"], ["# expect-reset"])
    write(t, "no_completion.jsonl", CX_START + [cx(cx_msg(0, "First message.")), "#! exit 0"])
    write(t, "interrupt_text.jsonl", ["#! spawn-grandchild"] + CX_START + [cx(cx_msg(0, "First message.")), "#! hang"])
    write(t, "interrupt_tool.jsonl", ["#! spawn-grandchild"] + CX_START + [cx(cx_msg(0, "First message.")),
                                                                           cx(cx_tool(1, "list_targets", {})[0]), "#! hang"])
    write(t, "timeout_kill.jsonl", ["#! spawn-grandchild"] + CX_START + ["#! hang"])
    write(t, "usage_cache.jsonl", CX_START + [cx(cx_msg(0, "Three words exactly.")), cx(cx_done(1007, 1000, 20))],
          ["# expect-usage fresh=7 read=1000 write=0 out=20"])
    write(t, "multi_turn.jsonl", ["#! stdin-has the refunds launch slipped"] + live(t, "plain.jsonl"))
    write(t, "turn_cap_sequential.jsonl", CX_START + [cx(e) for e in [*cx_tool(1, "list_targets", {}), *cx_tool(2, "list_targets", {}),
                                                                       cx_msg(3, "THIRD RESPONSE"), cx_done()]])
    par = cx_tool(1, "list_targets", {}) + cx_tool(2, "list_targets", {}) + cx_tool(3, "list_targets", {})
    par = [par[0], par[2], par[4], par[1], par[3], par[5]]  # three starts, then three results
    write(t, "turn_cap_parallel.jsonl", CX_START + [cx(e) for e in par + [cx_msg(4, "Second message."), cx_done()]])
    write(t, "turn_cap_text.jsonl", CX_START + [cx(cx_msg(0, "Second message.")), cx(cx_done())])
    write(t, "image.jsonl", ["#! argv-has --image"] + live(t, "plain.jsonl"))
    write(t, "read_folder.jsonl", ["#! argv-has --sandbox read-only"] + live(t, "plain.jsonl"))
    write(t, "web_search.jsonl", CX_START + [cx(e) for e in [
        {"type": "item.started", "item": {"id": "item_0", "type": "web_search", "query": "example"}},
        {"type": "item.completed", "item": {"id": "item_0", "type": "web_search", "query": "example"}},
        cx_msg(1, "Second message."), cx_done()]])
    # rollouts for the session rows
    def ro(ts, typ, payload):
        return syn({"timestamp": ts, "type": typ, "payload": payload})
    head = [ro("2026-11-05T12:00:00.000Z", "session_meta", {"id": "SESSION", "cwd": "/work"}),
            ro("2026-11-05T12:00:01.000Z", "event_msg", {"type": "task_started", "turn_id": "t1"}),
            ro("2026-11-05T12:00:02.000Z", "event_msg", {"type": "user_message", "message": "please add a flag"}),
            ro("2026-11-05T12:00:03.000Z", "event_msg", {"type": "agent_message", "message": "done, flag added"})]
    write(t, "session_rollout_ok.jsonl", head + [ro("2026-11-05T12:00:04.000Z", "event_msg",
                                                    {"type": "task_complete", "turn_id": "t1", "last_agent_message": "done, flag added"})])
    write(t, "session_rollout_failed.jsonl", head + [ro("2026-11-05T12:00:04.000Z", "event_msg",
                                                        {"type": "task_complete", "turn_id": "t1", "last_agent_message": None,
                                                         "error": {"message": "You have hit your usage limit.",
                                                                   "codex_error_info": "usage_limit_exceeded"}})])
    write(t, "session_rollout_aborted.jsonl", head + [ro("2026-11-05T12:00:04.000Z", "event_msg",
                                                         {"type": "turn_aborted", "turn_id": "t1", "reason": "interrupted"})])
    write(t, "session_rollout_missing.jsonl", head)  # never written: the row names a file that does not exist


# ---------------------------------------------------------------- HTTP
def oa_resp(content=None, tool_calls=None, usage=(50, 5)):
    msg = {"role": "assistant", "content": content or ""}
    if tool_calls:
        msg["tool_calls"] = [{"id": "call_%d" % i, "type": "function", "function": {"name": n, "arguments": json.dumps(a)}}
                             for i, (n, a) in enumerate(tool_calls, 1)]
    d = {"id": "chatcmpl-fixture", "object": "chat.completion", "model": "fixture-model",
         "choices": [{"index": 0, "message": msg, "finish_reason": "tool_calls" if tool_calls else "stop"}]}
    if usage:
        d["usage"] = {"prompt_tokens": usage[0], "completion_tokens": usage[1], "total_tokens": usage[0] + usage[1]}
    return syn(d)


def sse(*texts, usage=(50, 5), done=True):
    out = []
    for txt in texts:
        out.append("data: " + syn({"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": txt}}]}))
    if done:
        out.append("data: " + syn({"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}))
        if usage:
            out.append("data: " + syn({"object": "chat.completion.chunk", "choices": [],
                                       "usage": {"prompt_tokens": usage[0], "completion_tokens": usage[1],
                                                 "total_tokens": usage[0] + usage[1]}}))
        out.append("data: [DONE]")
    return out


HTTP_FAILS = {
    "fail_auth": (401, {"error": {"message": "OWNER-VISIBLE: unauthorized", "type": "authentication_error"}}),
    "fail_model": (404, {"error": {"message": "OWNER-VISIBLE: model 'fixture-model' not found", "type": "model_not_found"}}),
    "fail_rate_limit": (429, {"error": {"message": "OWNER-VISIBLE: rate limit exceeded", "type": "rate_limit_exceeded"}}),
    "fail_quota": (429, {"error": {"message": "OWNER-VISIBLE: you exceeded your current quota", "type": "insufficient_quota"}}),
    "fail_overload": (503, {"error": {"message": "OWNER-VISIBLE: server overloaded", "type": "server_overloaded"}}),
}


def ollama():
    t = "ollama"
    write(t, "plain_answer.batch.jsonl", [oa_resp("Three words exactly.")])
    write(t, "plain_answer.stream.jsonl", sse("Three ", "words ", "exactly."))
    for name, (status, body) in HTTP_FAILS.items():
        write(t, name + ".jsonl", ["#! status %d" % status, syn(body)])
    write(t, "no_completion.batch.jsonl", [syn({"id": "chatcmpl-fixture", "object": "chat.completion", "choices": []})])
    write(t, "no_completion.stream.jsonl", sse("First message.", done=False))
    write(t, "timeout_kill.jsonl", ["#! hang"])
    write(t, "usage_cache.batch.jsonl", [oa_resp("Three words exactly.", usage=(1007, 20))],
          ["# expect-usage fresh=1007 read=0 write=0 out=20"])
    write(t, "usage_cache.stream.jsonl", sse("Three words exactly.", usage=(1007, 20)),
          ["# expect-usage fresh=1007 read=0 write=0 out=20"])


def runtime_b():
    t = "runtime-b"
    nxt = "#! next-invocation"
    write(t, "plain_answer.jsonl", [oa_resp("Three words exactly.")])
    write(t, "two_messages.jsonl", [oa_resp("First message.", [("list_targets", {})]), nxt, oa_resp("Second message.")])
    write(t, "tool_ok.jsonl", [oa_resp("First message.", [("list_targets", {})]), nxt, oa_resp("Second message.")],
          ["# expect-first First message."])
    write(t, "tool_failed.jsonl", [oa_resp("", [("get_target", {"id": 999999})]), nxt, oa_resp("That target does not exist.")])
    write(t, "quick_connection.jsonl", [oa_resp("", [("mcp__acme__get_issue", {"key": "PAY-1"})]), nxt, oa_resp("PAY-1 is open.")])
    for name, (status, body) in HTTP_FAILS.items():
        write(t, name + ".jsonl", ["#! status %d" % status, syn(body)])
    write(t, "no_completion.jsonl", [syn({"id": "chatcmpl-fixture", "object": "chat.completion", "choices": []})])
    write(t, "interrupt_text.jsonl", ["#! hang"])
    write(t, "interrupt_tool.jsonl", [oa_resp("First message.", [("list_targets", {})]), nxt, "#! hang"])
    write(t, "timeout_kill.jsonl", ["#! hang"])
    write(t, "usage_cache.jsonl", [oa_resp("Three words exactly.", usage=(1007, 20))],
          ["# expect-usage fresh=1007 read=0 write=0 out=20"])
    write(t, "multi_turn.jsonl", [oa_resp("Three words exactly.")])
    calls = [("list_targets", {})]
    write(t, "turn_cap_sequential.jsonl", [oa_resp("", calls), nxt, oa_resp("", calls), nxt, oa_resp("THIRD RESPONSE")])
    write(t, "turn_cap_parallel.jsonl", [oa_resp("", calls * 3), nxt, oa_resp("Second message.")])
    write(t, "turn_cap_text.jsonl", [oa_resp("Second message.")])


claude()
codex()
ollama()
runtime_b()
write("", "never_started.jsonl", ["# An unsupported cell must start nothing: any launch of this fixture fails.",
                                   "#! stderr fakecli: an unsupported cell started a child", "#! exit 99"])
