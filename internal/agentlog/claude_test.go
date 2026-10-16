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
	s := line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o1", "timestamp": "2026-10-01T09:59:00Z", "cwd": "/w",
		"message": map[string]any{"role": "user", "content": "SENTINEL-PROMPT"}}) + line(t, assistant("s1", "u1", "m1", "r1", 5,
		toolUse("t1", "Bash", map[string]any{"command": "cd /SENTINEL_DIR && make test SENTINEL_ARG"})))
	r := parse(t, s, ParseOptions{})
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
