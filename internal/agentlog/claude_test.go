package agentlog

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func line(t *testing.T, m map[string]any) string {
	t.Helper()
	b, err := json.Marshal(m)
	require.NoError(t, err)
	return string(b) + "\n"
}

func assistant(sid, uuid, msgID, req string, out int64, content ...map[string]any) map[string]any {
	if content == nil {
		content = []map[string]any{{"type": "text", "text": "SENTINEL-REPLY"}}
	}
	return map[string]any{"type": "assistant", "sessionId": sid, "uuid": uuid, "parentUuid": "p-" + uuid,
		"timestamp": "2026-10-01T10:00:00.000Z", "cwd": "/w/app", "gitBranch": "main", "requestId": req,
		"message": map[string]any{"id": msgID, "model": "claude-opus-5-5", "role": "assistant", "content": content,
			"usage": map[string]any{"input_tokens": 10, "output_tokens": out, "cache_read_input_tokens": 100,
				"cache_creation_input_tokens": 50, "speed": "standard", "service_tier": "standard",
				"cache_creation": map[string]any{"ephemeral_5m_input_tokens": 20, "ephemeral_1h_input_tokens": 30}}}}
}

func parse(t *testing.T, s string, o ParseOptions) *ParseResult {
	t.Helper()
	if o.Path == "" {
		o.Path = "/h/.claude/projects/-w/s1.jsonl"
	}
	if o.Folder == "" {
		o.Folder = "/w"
	}
	r, err := ParseClaude(strings.NewReader(s), 0, o)
	require.NoError(t, err)
	return r
}

func TestParseClaude_StreamingChunksFoldIntoOneCall(t *testing.T) {
	s := line(t, assistant("s1", "u1", "m1", "r1", 5)) + line(t, assistant("s1", "u2", "m1", "r1", 42))
	r := parse(t, s, ParseOptions{})
	var calls []string
	for _, e := range r.Events {
		if e.Kind == "api_call" {
			calls = append(calls, e.Key)
			assert.Equal(t, int64(42), e.OutputTokens)
			assert.Equal(t, int64(20), e.CacheWrite5mTokens)
			assert.Equal(t, int64(30), e.CacheWrite1hTokens)
			assert.Equal(t, PriceVersion, e.PriceVersion)
			assert.False(t, e.CostEstimated)
		}
	}
	assert.Equal(t, []string{"m1:r1"}, calls)
}

func TestParseClaude_SessionMetaHomeIsFirstCWD(t *testing.T) {
	a := assistant("s1", "u1", "m1", "r1", 5)
	b := assistant("s1", "u2", "m2", "r2", 5)
	b["cwd"], b["timestamp"] = "/elsewhere", "2026-10-01T11:00:00.000Z"
	r := parse(t, line(t, a)+line(t, b), ParseOptions{})
	s := r.Sessions["s1"]
	require.NotNil(t, s)
	assert.Equal(t, "/w/app", s.HomeCWD)
	assert.Equal(t, "main", s.GitBranch)
	assert.Equal(t, "2026-10-01T10:00:00.000Z", s.StartedAt)
	assert.Equal(t, "2026-10-01T11:00:00.000Z", s.EndedAt)
}

func TestParseClaude_PartialLastLineNotConsumed(t *testing.T) {
	full := line(t, assistant("s1", "u1", "m1", "r1", 5))
	half := `{"type":"assistant","sessionId":"s1"`
	r := parse(t, full+half, ParseOptions{})
	assert.Equal(t, int64(len(full)), r.Consumed)
	assert.Len(t, r.Events, 1)
}

func TestParseClaude_UnknownTypesCountedSyntheticSkipped(t *testing.T) {
	syn := assistant("s1", "u9", "m9", "r9", 5)
	syn["message"].(map[string]any)["model"] = "<synthetic>"
	s := line(t, map[string]any{"type": "brand-new-record", "sessionId": "s1"}) + line(t, syn) + "not json\n"
	r := parse(t, s, ParseOptions{})
	assert.Equal(t, 1, r.Unknown["brand-new-record"])
	assert.Equal(t, 1, r.Unknown["<invalid>"])
	assert.Empty(t, r.Events)
}

func TestParseClaude_OwnerTurnCompactionAPIErrorPRLinkCost(t *testing.T) {
	s := line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o1", "timestamp": "2026-10-01T09:59:00Z", "cwd": "/w",
		"promptId": "pr1", "message": map[string]any{"role": "user", "content": "SENTINEL-PROMPT"}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o2", "isMeta": true, "timestamp": "2026-10-01T09:59:01Z",
			"message": map[string]any{"role": "user", "content": "meta"}}) +
		line(t, map[string]any{"type": "system", "subtype": "compact_boundary", "sessionId": "s1", "uuid": "c1", "timestamp": "2026-10-01T10:01:00Z"}) +
		line(t, map[string]any{"type": "assistant", "isApiErrorMessage": true, "sessionId": "s1", "uuid": "e1", "timestamp": "2026-10-01T10:02:00Z",
			"message": map[string]any{"model": "<synthetic>", "content": []any{}}}) +
		line(t, map[string]any{"type": "pr-link", "sessionId": "s1", "prUrl": "https://example.com/acme/app/pull/7", "prNumber": 7, "timestamp": "2026-10-01T10:03:00Z"}) +
		line(t, map[string]any{"type": "cost-state", "sessionId": "s1", "totalCostUSD": 1.5})
	r := parse(t, s, ParseOptions{})
	kinds := map[string]int{}
	for _, e := range r.Events {
		kinds[e.Kind]++
		if e.Kind == "owner_turn" {
			assert.Equal(t, "pr1", e.PromptID)
		}
		if e.Kind == "pr_link" {
			assert.Equal(t, "https://example.com/acme/app/pull/7", e.Target)
		}
	}
	assert.Equal(t, map[string]int{"owner_turn": 1, "compaction": 1, "api_error": 1, "pr_link": 1}, kinds)
	require.NotNil(t, r.Sessions["s1"].ReportedCostUSD)
	assert.InDelta(t, 1.5, *r.Sessions["s1"].ReportedCostUSD, 1e-9)
}

func TestParseClaude_StoresNoText(t *testing.T) {
	s := attachLine(t, "s1", "instructions", nil, "SENTINEL-CLAUDE-MD") +
		attachLine(t, "s1", "skill_listing", map[string]any{"names": []string{"review"}}, "SENTINEL-SKILL-DESCRIPTION") +
		attachLine(t, "s1", "hook_blocking_error", nil, "SENTINEL-HOOK") +
		attachLine(t, "s1", "SENTINEL-TYPE", nil, "x") +
		shapeLine(t, "s1", []map[string]any{{"type": "text", "text": "SENTINEL-SYSTEM"}}, []map[string]any{{"name": "SENTINEL-TOOL"}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o1", "timestamp": "2026-10-01T09:59:00Z", "cwd": "/w",
			"message": map[string]any{"role": "user", "content": "SENTINEL-PROMPT"}}) + line(t, assistant("s1", "u1", "m1", "r1", 5,
		toolUse("t1", "Bash", map[string]any{"command": "cd /SENTINEL_DIR && make test SENTINEL_ARG"}))) +
		toolResultLine(t, "s1", "r1", "t1", "SENTINEL-OUTPUT exit code 1", true, nil) +
		line(t, map[string]any{"type": "system", "subtype": "compact_boundary", "sessionId": "s1", "uuid": "c1", "content": "SENTINEL-COMPACT",
			"compactMetadata": map[string]any{"trigger": "SENTINEL-TRIGGER", "preTokens": 10, "postTokens": 2}}) +
		line(t, map[string]any{"type": "assistant", "isApiErrorMessage": true, "apiErrorStatus": "SENTINEL-STATUS", "sessionId": "s1", "uuid": "e2",
			"message": map[string]any{"model": "<synthetic>", "content": []any{}}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "cs1", "isCompactSummary": true,
			"message": map[string]any{"role": "user", "content": "SENTINEL-SUMMARY"}}) +
		line(t, map[string]any{"type": "assistant", "isApiErrorMessage": true, "apiErrorStatus": 529, "sessionId": "s1", "uuid": "e1",
			"message": map[string]any{"model": "<synthetic>", "content": []map[string]any{{"type": "text", "text": "SENTINEL-API-ERROR"}}}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "i1", "message": map[string]any{"role": "user",
			"content": "[Request interrupted by user] SENTINEL-INTERRUPT"}})
	r := parse(t, s, ParseOptions{})
	require.Equal(t, int64(len("SENTINEL-CLAUDE-MD")), partsOf(r)["s1//instructions"], "the rendered text was measured")
	require.NotEmpty(t, r.SkillListing)
	b, err := json.Marshal(r)
	require.NoError(t, err)
	assert.NotContains(t, string(b), "SENTINEL")
}

func TestParseClaude_SessionlessRecordProducesNothing(t *testing.T) {
	a := assistant("", "u1", "m1", "r1", 5)
	delete(a, "sessionId")
	s := line(t, a) + line(t, map[string]any{"type": "user", "uuid": "o1", "message": map[string]any{"role": "user", "content": "hi"}})
	r := parse(t, s, ParseOptions{})
	assert.Empty(t, r.Events)
	assert.Empty(t, r.Sessions)
	assert.Equal(t, 2, r.Unknown["<no-session>"])
}

func TestParseClaude_UUIDLessRecordsKeepDistinctKeys(t *testing.T) {
	owner := func(text string) string {
		return line(t, map[string]any{"type": "user", "sessionId": "s1", "message": map[string]any{"role": "user", "content": text}})
	}
	compact := line(t, map[string]any{"type": "system", "subtype": "compact_boundary", "sessionId": "s1"})
	s := owner("one") + owner("two") + compact + compact
	r := parse(t, s, ParseOptions{})
	keys := map[string]bool{}
	for _, e := range r.Events {
		keys[e.Key] = true
	}
	require.Len(t, r.Events, 4)
	assert.Len(t, keys, 4, "uuid-less events must not share a key: %v", keys)
	assert.Equal(t, "owner_turn:/h/.claude/projects/-w/s1.jsonl:0", r.Events[0].Key)
}

func TestParseClaude_OwnerTurnTriggers(t *testing.T) {
	cases := []struct {
		content any
		want    string
	}{
		{"hello", "owner"},
		{"<task-notification>x</task-notification>", "notification"},
		{"<agent-message from=\"a\">x", "notification"},
		{"<system-reminder>x</system-reminder>", "hook"},
		{"Stop hook feedback: x", "hook"},
		{"\n  <task-notification>x</task-notification>", "notification"},
		{"\t<system-reminder>x", "hook"},
		{"<command-name>/foo</command-name>", "owner"},
		{[]map[string]any{{"type": "text", "text": "<task-notification>x"}}, "notification"},
		{[]map[string]any{{"type": "text", "text": "hi"}}, "owner"},
	}
	for i, c := range cases {
		s := line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o1", "timestamp": "2026-10-01T09:59:00Z", "cwd": "/w",
			"message": map[string]any{"role": "user", "content": c.content}})
		r := parse(t, s, ParseOptions{})
		var got []string
		for _, e := range r.Events {
			if e.Kind == "owner_turn" {
				got = append(got, e.Trigger)
			}
		}
		assert.Equal(t, []string{c.want}, got, "case %d", i)
	}
}

func attachLine(t *testing.T, sid, typ string, extra map[string]any, contents ...string) string {
	t.Helper()
	a := map[string]any{"type": typ}
	for k, v := range extra {
		a[k] = v
	}
	rec := map[string]any{"type": "attachment", "sessionId": sid, "timestamp": "2026-10-01T09:00:00Z", "attachment": a}
	if contents != nil { // rendered sits at record level, next to attachment
		var rendered []map[string]any
		for _, c := range contents {
			rendered = append(rendered, map[string]any{"type": "text", "content": c})
		}
		rec["rendered"] = rendered
	}
	return line(t, rec)
}

func shapeLine(t *testing.T, sid string, system, tools any) string {
	t.Helper()
	return line(t, map[string]any{"type": "api-request-shape", "sessionId": sid, "shape": map[string]any{"system": system, "tools": tools}})
}

func jsonLen(t *testing.T, v any) int64 {
	t.Helper()
	b, err := json.Marshal(v)
	require.NoError(t, err)
	return int64(len(b))
}

func partsOf(r *ParseResult) map[string]int64 {
	got := map[string]int64{}
	for _, p := range r.ContextParts {
		got[p.SessionUUID+"/"+p.AgentID+"/"+p.Part] = p.Bytes
	}
	return got
}

func TestParseClaude_CompactionMeta(t *testing.T) {
	s := line(t, map[string]any{"type": "system", "subtype": "compact_boundary", "sessionId": "s1", "uuid": "c1",
		"timestamp": "2026-10-01T10:01:00Z", "content": "Conversation compacted",
		"compactMetadata": map[string]any{"trigger": "auto", "preTokens": 167000, "postTokens": 12000, "durationMs": 9000}}) +
		line(t, map[string]any{"type": "system", "subtype": "compact_boundary", "sessionId": "s1", "uuid": "c2"})
	r := parse(t, s, ParseOptions{})
	require.Len(t, r.Events, 2)
	e := r.Events[0]
	assert.Equal(t, "compaction", e.Kind)
	assert.Equal(t, "auto", e.Trigger)
	require.NotNil(t, e.PreTokens)
	require.NotNil(t, e.PostTokens)
	assert.Equal(t, int64(167000), *e.PreTokens)
	assert.Equal(t, int64(12000), *e.PostTokens)
	assert.Nil(t, r.Events[1].PreTokens, "no metadata = not measured")
	assert.Empty(t, r.Events[1].Trigger)
}

func TestParseClaude_InterruptIsOwnerTurn(t *testing.T) {
	s := line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "i1", "timestamp": "2026-10-01T09:59:00Z",
		"message": map[string]any{"role": "user", "content": "[Request interrupted by user]"}}) +
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "i2", "timestamp": "2026-10-01T09:59:01Z",
			"message": map[string]any{"role": "user", "content": []map[string]any{{"type": "text", "text": "[Request interrupted by user for tool use]"}}}})
	r := parse(t, s, ParseOptions{})
	var got []string
	for _, e := range r.Events {
		got = append(got, e.Key+"/"+e.Kind+"/"+e.Trigger)
	}
	assert.Equal(t, []string{"owner_turn:i1/owner_turn/interrupt", "owner_turn:i2/owner_turn/interrupt"}, got)
}

func TestParseClaude_ContextPartsBeforeFirstCall(t *testing.T) {
	system := []map[string]any{{"type": "text", "text": "system prompt"}}
	tools := []map[string]any{{"name": "Bash"}, {"name": "Read"}}
	before := attachLine(t, "s1", "instructions", nil, "1234567890", "12345") +
		attachLine(t, "s1", "skill_listing", map[string]any{"names": []string{"a", "b"}}, "abcdef") +
		attachLine(t, "s1", "agent_listing_delta", nil, "xyz") +
		attachLine(t, "s1", "mcp_instructions_delta", nil, "mm") +
		attachLine(t, "s1", "deferred_tools_record", nil, "dddd") +
		attachLine(t, "s1", "deferred_tools_delta", nil, "d") +
		attachLine(t, "s1", "hook_success", nil, "hh") +
		attachLine(t, "s1", "hook_additional_context", nil, "h") +
		attachLine(t, "s1", "brand_new_kind", nil, "ooo") +
		attachLine(t, "s1", "instructions", nil) + // no rendered: 0 bytes
		shapeLine(t, "s1", system, tools)
	after := attachLine(t, "s1", "instructions", nil, "LATER-LATER-LATER") + shapeLine(t, "s1", system, append(tools, map[string]any{"name": "X"}))
	s := before + line(t, assistant("s1", "u1", "m1", "r1", 5)) + after + line(t, assistant("s1", "u2", "m2", "r2", 5))
	r := parse(t, s, ParseOptions{})
	assert.Equal(t, map[string]int64{"s1//instructions": 15, "s1//skills": 6, "s1//agents": 3, "s1//mcp": 2,
		"s1//deferred_tools": 5, "s1//hooks": 3, "s1//other": 3,
		"s1//system": jsonLen(t, system), "s1//tools": jsonLen(t, tools)}, partsOf(r))

	sub := parse(t, attachLine(t, "s1", "instructions", nil, "1234")+line(t, assistant("s1", "u1", "m9", "r9", 5)),
		ParseOptions{Path: "/h/.claude/projects/-w/s1/subagents/agent-a1.jsonl", Subagent: true, AgentID: "a1"})
	assert.Equal(t, map[string]int64{"s1/a1/instructions": 4}, partsOf(sub))

	// A lane whose first call is not in the read stores nothing yet.
	assert.Empty(t, parse(t, before, ParseOptions{}).ContextParts)

	// An incremental read never emits parts: the read from 0 stored them.
	inc, err := ParseClaude(strings.NewReader(before), 100, ParseOptions{Path: "/h/.claude/projects/-w/s1.jsonl", Folder: "/w"})
	require.NoError(t, err)
	assert.Empty(t, inc.ContextParts)
}

func TestParseClaude_SkillListingRows(t *testing.T) {
	s := attachLine(t, "s1", "skill_listing", map[string]any{"names": []string{"review", "pdf", "brainstorming"}}, "0123456789", "0") +
		line(t, assistant("s1", "u1", "m1", "r1", 5)) +
		attachLine(t, "s1", "skill_listing", map[string]any{"names": []string{"late"}}, "1234")
	r := parse(t, s, ParseOptions{})
	got := map[string]int64{}
	for _, k := range r.SkillListing {
		assert.Equal(t, "s1", k.SessionUUID)
		got[k.Skill] = k.Bytes
	}
	assert.Equal(t, map[string]int64{"review": 3, "pdf": 3, "brainstorming": 3, "late": 4}, got)
}

func TestParseClaude_APIErrorStatus(t *testing.T) {
	s := line(t, map[string]any{"type": "assistant", "isApiErrorMessage": true, "apiErrorStatus": 429, "sessionId": "s1", "uuid": "e1",
		"timestamp": "2026-10-01T10:02:00Z", "message": map[string]any{"model": "<synthetic>", "content": []any{}}}) +
		line(t, map[string]any{"type": "assistant", "isApiErrorMessage": true, "sessionId": "s1", "uuid": "e2",
			"timestamp": "2026-10-01T10:02:01Z", "message": map[string]any{"model": "<synthetic>", "content": []any{}}})
	r := parse(t, s, ParseOptions{})
	require.Len(t, r.Events, 2)
	assert.Equal(t, "api_error", r.Events[0].Kind)
	assert.Equal(t, "429", r.Events[0].ErrorClass)
	assert.Empty(t, r.Events[1].ErrorClass)
}
