package sources

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions/handlers"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/sessionfeed"
)

// Go twins of SessionChatSliceTests, SessionChatRunnerTests and
// SessionChatPayloadTests (FEED-05). The watch lives in
// handlers.ChatWatchRegistry; the source reads the feed in-process.

// chatClock is a settable clock shared by the registry's stamps and the
// source.
type chatClock struct {
	mu  sync.Mutex
	now time.Time
}

func newChatClock() *chatClock { return &chatClock{now: time.Unix(1_800_000_000, 0)} }

func (c *chatClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *chatClock) advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

type chatRig struct {
	t       *testing.T
	clock   *chatClock
	watches *handlers.ChatWatchRegistry
	mu      sync.Mutex
	calls   []string // "<session>/<tool use id>"
	live    map[int64]time.Time
	active  bool
	nudges  int
}

func newChatRig(t *testing.T) *chatRig {
	return &chatRig{t: t, clock: newChatClock(), watches: handlers.NewChatWatchRegistry(), live: map[int64]time.Time{}, active: true}
}

func feedEntry(i int, text string) sessionfeed.Entry {
	return sessionfeed.Entry{ID: "e" + itoa(i), Kind: sessionfeed.KindAgent, At: time.Unix(1_700_000_000+int64(i), 0), Text: text}
}

func itoa(i int) string { return strconv.Itoa(i) }

// source builds the session_chat source; fetch nil returns one owner entry.
// Its chats cannot be watched (NewWatcher fails), so a live one reads on the
// Every tick (the fallback): these tests drive reads by the clock; the
// file-event reads are chat_files_test.go's.
func (r *chatRig) source(fetch ChatFetch, timing ChatTiming) *SessionChatSource {
	if fetch == nil {
		fetch = func(_ context.Context, id int64, toolUseID string) (ChatRead, error) {
			return ChatRead{Entries: []sessionfeed.Entry{{ID: "e1", Kind: sessionfeed.KindOwner, At: time.Unix(1_700_000_000, 0), Text: "Hello"}}}, nil
		}
	}
	return SessionChat(r.watches, nil, SessionChatOptions{
		Timing: timing,
		Fetch: func(ctx context.Context, id int64, toolUseID string) (ChatRead, error) {
			r.mu.Lock()
			r.calls = append(r.calls, itoa(int(id))+"/"+toolUseID)
			r.mu.Unlock()
			return fetch(ctx, id, toolUseID)
		},
		Liveness: func() Liveness {
			r.mu.Lock()
			defer r.mu.Unlock()
			return Liveness{Runs: r.live}
		},
		Active: func() bool {
			r.mu.Lock()
			defer r.mu.Unlock()
			return r.active
		},
		OnChange: func() {
			r.mu.Lock()
			r.nudges++
			r.mu.Unlock()
		},
		Conversations: func(context.Context, int64) ([]sessionfeed.Conversation, error) {
			return []sessionfeed.Conversation{{Path: "/conversation.jsonl"}}, nil
		},
		NewWatcher: func() (FileWatcher, error) { return nil, errors.New("no watcher in this test") },
		Now:        r.clock.Now,
	})
}

func (r *chatRig) watch(session int64, agent, toolUseID string) {
	r.watches.Watch(handlers.ChatWatch{SessionID: session, AgentID: agent, ToolUseID: toolUseID, Expires: r.clock.Now().Add(handlers.ChatWatchLength)})
}

func (r *chatRig) callCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.calls)
}

func chatItems(t *testing.T, s *SessionChatSource) map[string]map[string]any {
	t.Helper()
	items, err := s.Items(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]map[string]any{}
	for _, it := range items {
		out[it.ID] = decode(t, it.Payload)
	}
	return out
}

func chatEntries(t *testing.T, p map[string]any) []map[string]any {
	t.Helper()
	raw, ok := p["entries"].([]any)
	if !ok {
		t.Fatalf("entries = %v", p["entries"])
	}
	out := make([]map[string]any, len(raw))
	for i, e := range raw {
		out[i] = e.(map[string]any)
	}
	return out
}

// encodeChatJSON encodes a live payload of session 7 with sampleLive's
// block. The main feed also carries a live_error (every key of the Kit
// fixture session_chat.json); an agent record carries none, as the fixture
// session_chat_subagent.json (a live subagent's record).
func encodeChatJSON(t *testing.T, entries []sessionfeed.Entry, agent string) ([]byte, map[string]any) {
	t.Helper()
	liveErr := ""
	if agent == "" {
		liveErr = liveErrUnavailable
	}
	b, err := encodeChat(entries, 7, agent, true, phoneLive(sampleLive()), liveErr)
	if err != nil {
		t.Fatal(err)
	}
	return b, decode(t, b)
}

// sampleLive is a live snapshot with every key set: a running Bash step, a
// finished Read step and a running subagent.
func sampleLive() *sessionfeed.Live {
	at := time.Unix(1_700_000_060, 0).UTC()
	read := sessionfeed.LiveAction{ID: "toolu_01", Tool: "Read", Summary: "internal/db/db.go", StartedAt: at, CompletedAt: at.Add(time.Second)}
	bash := sessionfeed.LiveAction{ID: "toolu_02", Tool: "Bash", Summary: "go test ./internal/db", StartedAt: at.Add(2 * time.Second)}
	return &sessionfeed.Live{
		ObservedAt: at.Add(5 * time.Second), Conversation: "conv-1", TurnAt: at, TurnActive: true,
		Current: &bash, Latest: &read, AgentsState: "known",
		Agents: []sessionfeed.LiveAgent{{
			Ref:       sessionfeed.SubagentRef{ToolUseID: "toolu_01a", AgentID: "a1b2", Type: "Explore", Description: "Check the fixtures", Status: "running"},
			StartedAt: at, Action: &read, CanOpen: true,
		}},
		Steps: []sessionfeed.LiveAction{read, bash},
	}
}

// FEED-05 guards.

func TestFeed05_NoWatchPublishesNothing(t *testing.T) {
	r := newChatRig(t)
	s := r.source(nil, ChatTiming{})
	if s.Kind() != hubslices.KindSessionChat {
		t.Fatalf("kind %s", s.Kind())
	}
	s.RunDue(context.Background())
	if got := chatItems(t, s); len(got) != 0 || r.callCount() != 0 {
		t.Fatalf("no watch: items %v, %d reads", got, r.callCount())
	}
	r.watch(7, "", "")
	r.watch(7, "a1b2", "toolu_01a")
	s.RunDue(context.Background())
	got := chatItems(t, s)
	if len(got) != 2 || got["7"] == nil || got["7-a1b2"] == nil {
		t.Fatalf("records %v, want 7 and 7-a1b2", got)
	}
	if num(got["7"]["session_id"]) != 7 {
		t.Fatalf("session_id %v", got["7"]["session_id"])
	}
	if !slices.Contains(r.calls, "7/toolu_01a") {
		t.Fatalf("the subagent read gets the tool_use id: %v", r.calls)
	}
}

func TestFeed05_ExpiredWatchLeavesWindow(t *testing.T) {
	r := newChatRig(t)
	s := r.source(nil, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(context.Background())
	r.clock.advance(299 * time.Second)
	if n := len(chatItems(t, s)); n != 1 {
		t.Fatalf("%d records before the watch ends", n)
	}
	r.clock.advance(2 * time.Second)
	if got := chatItems(t, s); len(got) != 0 {
		t.Fatalf("an expired watch still publishes %v: the publisher would not delete the record", got)
	}
	if len(s.runs) != 0 {
		t.Fatal("the watch's payload is not freed")
	}
	// A new request after expiry reads again.
	r.watch(7, "", "")
	s.RunDue(context.Background())
	if r.callCount() != 2 || len(chatItems(t, s)) != 1 {
		t.Fatalf("after a new request: %d reads", r.callCount())
	}
}

func TestFeed05_UnlinkedPhoneDropsPayloadsForGood(t *testing.T) {
	r := newChatRig(t)
	s := r.source(nil, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(context.Background())
	if len(chatItems(t, s)) != 1 {
		t.Fatal("no payload while linked")
	}
	r.active = false
	if got := chatItems(t, s); len(got) != 0 {
		t.Fatalf("unlinked: %v", got)
	}
	r.active = true
	if got := chatItems(t, s); len(got) != 0 {
		t.Fatalf("the old payload is resurrected: %v", got)
	}
	if w := r.watches.Active(r.clock.Now()); len(w) != 0 {
		t.Fatalf("the watches survived the unlink: %v", w)
	}
}

func TestFeed05_MatchesKitFixtureKeys(t *testing.T) {
	fixture := kitFixture(t, "workbench/session_chat.json")
	_, main := encodeChatJSON(t, []sessionfeed.Entry{feedEntry(0, "hi")}, "")
	assertWireShape(t, main, fixture, "agent_id")
	if _, ok := main["agent_id"]; ok {
		t.Fatal("the main feed carries agent_id")
	}
	sub := kitFixture(t, "workbench/session_chat_subagent.json")
	_, subPayload := encodeChatJSON(t, []sessionfeed.Entry{feedEntry(0, "hi")}, "a1b2")
	assertWireShape(t, subPayload, sub)
	fixtureEntry := fixture["entries"].([]any)[0].(map[string]any)
	allowed := map[string]bool{"text_clipped": true, "title": true, "via": true, "ask_id": true, "subagent": true}
	for k := range fixtureEntry {
		allowed[k] = true
	}
	for k := range chatEntries(t, main)[0] {
		if !allowed[k] {
			t.Errorf("entry key %s is not in the Kit fixture", k)
		}
	}
	// A separator without a time carries id, kind and text only; dates are
	// unix seconds.
	_, sep := encodeChatJSON(t, []sessionfeed.Entry{{ID: "sep", Kind: sessionfeed.KindSeparator, Text: "Context compacted"}}, "")
	e := chatEntries(t, sep)[0]
	if len(e) != 3 || e["id"] == nil || e["kind"] == nil || e["text"] == nil {
		t.Fatalf("separator keys %v", e)
	}
	if float(chatEntries(t, main)[0]["at"]) != 1_700_000_000 {
		t.Fatalf("at %v", chatEntries(t, main)[0]["at"])
	}
	// The subagent marker keeps its selector, labels clipped at 200.
	long := strings.Repeat("b", 500)
	_, marker := encodeChatJSON(t, []sessionfeed.Entry{{ID: "s", Kind: sessionfeed.KindSubagent, Title: long,
		Subagent: &sessionfeed.SubagentRef{ToolUseID: "t", AgentID: "a1", Type: "Explore", Description: long, Status: "running"}}}, "")
	m := chatEntries(t, marker)[0]
	sa := m["subagent"].(map[string]any)
	if runes(sa["description"]) != 200 || runes(m["title"]) != 200 || sa["tool_use_id"] != "t" {
		t.Fatalf("marker %v", m)
	}
}

func TestFeed05_OnlyFeedKindsPublished(t *testing.T) {
	var entries []sessionfeed.Entry
	for i, k := range []string{"owner", "tool_use", "agent", "thinking", "hologram", "subagent", "event"} {
		entries = append(entries, sessionfeed.Entry{ID: "k" + itoa(i), Kind: sessionfeed.Kind(k), At: time.Unix(1_700_000_000+int64(i), 0), Text: k})
	}
	_, p := encodeChatJSON(t, entries, "")
	var kinds []string
	for _, e := range chatEntries(t, p) {
		kinds = append(kinds, e["kind"].(string))
	}
	if !slices.Equal(kinds, []string{"owner", "agent", "subagent"}) {
		t.Fatalf("kinds %v", kinds)
	}
	if num(p["entries_more"]) != 0 {
		t.Fatalf("dropped kinds counted as older entries: %v", p["entries_more"])
	}
	var many []sessionfeed.Entry
	for i := range 350 {
		many = append(many, feedEntry(i, "x"), sessionfeed.Entry{ID: "t" + itoa(i), Kind: "tool_use", Text: "x"})
	}
	_, capped := encodeChatJSON(t, many, "")
	if len(chatEntries(t, capped)) != 300 || num(capped["entries_more"]) != 50 {
		t.Fatalf("capped %d, more %v", len(chatEntries(t, capped)), capped["entries_more"])
	}
}

// liveRead is a fetch returning one agent entry and the snapshot l.
func liveRead(l *sessionfeed.Live) ChatFetch {
	return func(context.Context, int64, string) (ChatRead, error) {
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}, Live: l}, nil
	}
}

// liveBlockKeys is every key the live block may carry, by object.
var liveBlockKeys = map[string][]string{
	"live":   {"observed_at", "conversation", "turn_at", "turn_active", "current", "latest", "agents", "agents_state", "agents_more", "steps", "steps_more"},
	"action": {"id", "tool", "summary", "started_at", "completed_at", "more"},
	"agent":  {"ref", "started_at", "action", "can_open"},
	"ref":    {"tool_use_id", "agent_id", "type", "description", "status"},
}

func assertOnlyKeys(t *testing.T, what string, obj any) map[string]any {
	t.Helper()
	m, ok := obj.(map[string]any)
	if !ok {
		t.Fatalf("%s is %T", what, obj)
	}
	for k := range m {
		if !slices.Contains(liveBlockKeys[what], k) {
			t.Errorf("%s carries %q: only one-line summaries may reach the phone", what, k)
		}
	}
	return m
}

// The live block reaches the phone as summaries only: the sessionfeed.Live
// keys and nothing else (no tool output, thinking or hook text), every
// summary and description cut at 200, at most 40 steps and 32 agents, the
// cut counted.
func TestFeed05_LiveBlockSummariesOnly(t *testing.T) {
	long := strings.Repeat("é", 500)
	at := time.Unix(1_700_000_060, 0).UTC()
	in := &sessionfeed.Live{ObservedAt: at, TurnAt: at, TurnActive: true, AgentsState: "known", StepsMore: 3, AgentsMore: 1}
	for i := range 50 {
		in.Steps = append(in.Steps, sessionfeed.LiveAction{ID: "s" + itoa(i), Tool: "Bash", Summary: long, StartedAt: at, CompletedAt: at})
	}
	in.Current, in.Latest = &in.Steps[49], &in.Steps[48]
	for i := range 40 {
		in.Agents = append(in.Agents, sessionfeed.LiveAgent{
			Ref:    sessionfeed.SubagentRef{ToolUseID: "t" + itoa(i), AgentID: "a" + itoa(i), Type: "Explore", Description: long, Status: "running", ParentReport: "the report"},
			Action: &sessionfeed.LiveAction{ID: "x", Tool: "Read", Summary: long, StartedAt: at},
		})
	}
	r := newChatRig(t)
	r.live[7] = time.Now()
	s := r.source(liveRead(in), ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(context.Background())
	items, err := s.Items(context.Background())
	if err != nil || len(items) != 1 {
		t.Fatalf("items %v, %v", items, err)
	}
	if strings.Contains(string(items[0].Payload), "the report") {
		t.Fatal("a subagent's report reached the payload")
	}
	block := assertOnlyKeys(t, "live", decode(t, items[0].Payload)["activity_live"])
	summaries := 0
	checkAction := func(v any) {
		a := assertOnlyKeys(t, "action", v)
		if n := runes(a["summary"]); n > maxLiveSummary {
			t.Errorf("summary of %d runes", n)
		}
		summaries++
	}
	checkAction(block["current"])
	checkAction(block["latest"])
	steps := block["steps"].([]any)
	agents := block["agents"].([]any)
	if len(steps) != 40 || num(block["steps_more"]) != 13 || len(agents) != 32 || num(block["agents_more"]) != 9 {
		t.Fatalf("steps %d (+%v), agents %d (+%v)", len(steps), block["steps_more"], len(agents), block["agents_more"])
	}
	for _, st := range steps {
		checkAction(st)
	}
	for _, v := range agents {
		a := assertOnlyKeys(t, "agent", v)
		ref := assertOnlyKeys(t, "ref", a["ref"])
		if n := runes(ref["description"]); n > maxLiveSummary {
			t.Errorf("description of %d runes", n)
		}
		checkAction(a["action"])
	}
	if summaries != 2+40+32 {
		t.Fatalf("%d summaries checked", summaries)
	}
	if in.Steps[0].Summary != long || in.Agents[0].Ref.Description != long || len(in.Steps) != 50 {
		t.Fatal("phoneLive changed the snapshot it was given")
	}
}

// Secrets in a tool summary or an agent description reach the payload as
// [secret]: a token, an Authorization header, a PASSWORD= env and a
// user:pass@ URL.
func TestFeed05_LiveBlockRedactsSecrets(t *testing.T) {
	at := time.Unix(1_700_000_060, 0).UTC()
	curl := sessionfeed.LiveAction{ID: "s1", Tool: "Bash", Summary: `curl -H "Authorization: Bearer abcdEFGH12345678" https://u:p4ss@x`, StartedAt: at}
	env := sessionfeed.LiveAction{ID: "s2", Tool: "Bash", Summary: "PASSWORD=hunter2hunter2 go run .", StartedAt: at}
	in := &sessionfeed.Live{
		ObservedAt: at, TurnAt: at, TurnActive: true, AgentsState: "known", Current: &env, Latest: &curl,
		Steps: []sessionfeed.LiveAction{curl, env},
		Agents: []sessionfeed.LiveAgent{{
			Ref:    sessionfeed.SubagentRef{ToolUseID: "t", AgentID: "a", Type: "general-purpose", Description: "deploy with TOKEN=abc123def", Status: "running"},
			Action: &curl,
		}},
	}
	r := newChatRig(t)
	r.live[7] = time.Now()
	s := r.source(liveRead(in), ChatTiming{})
	r.watch(7, "", "")
	r.watch(7, "a", "t")
	s.RunDue(context.Background())
	items, err := s.Items(context.Background())
	if err != nil || len(items) != 2 {
		t.Fatalf("items %v, %v", items, err)
	}
	for _, it := range items {
		payload := string(it.Payload)
		for _, raw := range []string{"abcdEFGH12345678", "p4ss", "hunter2hunter2", "abc123def"} {
			if strings.Contains(payload, raw) {
				t.Errorf("record %s carries %q", it.ID, raw)
			}
		}
		block := decode(t, it.Payload)["activity_live"].(map[string]any)
		for _, v := range block["steps"].([]any) {
			if !strings.Contains(v.(map[string]any)["summary"].(string), "[secret]") {
				t.Errorf("record %s: step %v not marked", it.ID, v)
			}
		}
		ref := block["agents"].([]any)[0].(map[string]any)["ref"].(map[string]any)
		if !strings.Contains(ref["description"].(string), "[secret]") {
			t.Errorf("record %s: description %v not marked", it.ID, ref["description"])
		}
	}

	// Through the real transcript reader, whose own summary cut (120 runes)
	// comes first: a URL whose "@" lies past the cut and a GitHub token
	// straddling it are redacted before that cut, never leak as a prefix.
	pad := strings.Repeat("a", 90)
	url := "echo " + pad + " https://deploy:hunter2hunter2hunter2@example.com/x" // leak-check:allow
	ghp := "echo " + pad + " ghp_abcdefghijklmnopqrstuvwxyz0123456789"           // leak-check:allow
	// A JWT whose second dot lies past the reader's redaction window (64 KiB):
	// its prefix runs into the window's end and is masked whole.
	jwt := "echo " + pad + " eyJhbGciOiJIUzI1NiJ9" + strings.Repeat("A", 70_000) + ".eyJzdWIiOiIxIn0.c2ln" // leak-check:allow
	conv := filepath.Join(t.TempDir(), "conv.jsonl")
	if err := os.WriteFile(conv, []byte(bashToolUses(t, url, ghp, jwt)), 0o600); err != nil {
		t.Fatal(err)
	}
	viaReader := newChatRig(t)
	viaReader.live[7] = time.Now()
	rs := viaReader.source(func(context.Context, int64, string) (ChatRead, error) {
		l, err := sessionfeed.LiveOf(sessionfeed.Conversation{Path: conv, AgentSessionID: "conv"}, false, at)
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}, Live: l, LiveErr: err}, nil
	}, ChatTiming{})
	viaReader.watch(7, "", "")
	rs.RunDue(context.Background())
	items, err = rs.Items(context.Background())
	if err != nil || len(items) != 1 {
		t.Fatalf("real path: items %v, %v", items, err)
	}
	payload := string(items[0].Payload)
	for _, raw := range []string{"hunter2", "deploy:", "ghp_abc", "abcdefghijklmnop", "eyJhbGci"} {
		if strings.Contains(payload, raw) {
			t.Errorf("the real path leaks %q", raw)
		}
	}
	steps := decode(t, items[0].Payload)["activity_live"].(map[string]any)["steps"].([]any)
	if len(steps) != 3 {
		t.Fatalf("real path steps %v", steps)
	}
	for _, v := range steps {
		if !strings.Contains(v.(map[string]any)["summary"].(string), "[secret]") {
			t.Errorf("real path: step %v not marked", v)
		}
	}
}

// bashToolUses is a Claude transcript with one open Bash call per command.
func bashToolUses(t *testing.T, commands ...string) string {
	t.Helper()
	var b strings.Builder
	for i, c := range commands {
		raw, err := json.Marshal(map[string]any{"type": "assistant", "uuid": "b" + itoa(i), "timestamp": "2026-10-01T10:00:06Z", "message": map[string]any{
			"id": "mb" + itoa(i), "role": "assistant", "content": []map[string]any{{"type": "tool_use", "id": "toolu_b" + itoa(i), "name": "Bash", "input": map[string]any{"command": c}}}}})
		if err != nil {
			t.Fatal(err)
		}
		b.Write(raw)
		b.WriteByte('\n')
	}
	return b.String()
}

func TestSessionChatCaps(t *testing.T) {
	var entries []sessionfeed.Entry
	for i := range 301 {
		entries = append(entries, feedEntry(i, "hi"))
	}
	_, p := encodeChatJSON(t, entries, "")
	list := chatEntries(t, p)
	if len(list) != 300 || list[0]["id"] != "e1" || list[299]["id"] != "e300" || num(p["entries_more"]) != 1 {
		t.Fatalf("301 entries: %d kept, first %v, more %v", len(list), list[0]["id"], p["entries_more"])
	}

	_, clipped := encodeChatJSON(t, []sessionfeed.Entry{feedEntry(0, strings.Repeat("a", 4001))}, "")
	e := chatEntries(t, clipped)[0]
	if runes(e["text"]) != 4000 || e["text_clipped"] != true {
		t.Fatalf("4001-char text: %d runes, clipped %v", runes(e["text"]), e["text_clipped"])
	}

	big := strings.Repeat("x", 4000)
	entries = entries[:0]
	for i := range 300 {
		entries = append(entries, feedEntry(i, big))
	}
	b, fit := encodeChatJSON(t, entries, "")
	list = chatEntries(t, fit)
	if len(b) > MaxChatBytes || len(list) >= 300 {
		t.Fatalf("payload %d bytes, %d entries", len(b), len(list))
	}
	if list[len(list)-1]["id"] != "e299" || num(fit["entries_more"]) != int64(300-len(list)) {
		t.Fatalf("the oldest are dropped and counted: last %v, more %v", list[len(list)-1]["id"], fit["entries_more"])
	}
	again, _ := encodeChatJSON(t, entries, "")
	if string(again) != string(b) {
		t.Fatal("identical feeds encode differently")
	}
}

// The source holds no sidecar handle (its options have none) and the feed
// read only reads: a pass and a publish change no row of watchtower.db.
func TestSessionChatNeverWritesTheSidecarOrDB(t *testing.T) {
	fx := newFeedFixture(t)
	before := rowCounts(t, fx.d)
	r := newChatRig(t)
	s := SessionChat(r.watches, fx.d, SessionChatOptions{Dirs: fx.dirs, Now: r.clock.Now})
	t.Cleanup(s.dropAll) // closes its file watcher
	r.watch(fx.session, "", "")
	s.RunDue(context.Background())
	got := chatItems(t, s)
	if len(got) != 1 || len(chatEntries(t, got[itoa(int(fx.session))])) != 2 {
		t.Fatalf("in-process feed read: %v", got)
	}
	if after := rowCounts(t, fx.d); !mapsEqual(before, after) {
		t.Fatalf("the chat wrote the database: %v -> %v", before, after)
	}
}

func TestSessionChatCadence(t *testing.T) {
	ctx := context.Background()
	r := newChatRig(t)
	r.live[7] = time.Now()
	s := r.source(nil, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(ctx)
	r.clock.advance(2 * time.Second)
	s.RunDue(ctx)
	if r.callCount() != 1 {
		t.Fatal("a live session ran before 3 s")
	}
	r.clock.advance(time.Second)
	s.RunDue(ctx)
	if r.callCount() != 2 {
		t.Fatal("a live session did not run at 3 s")
	}
	if r.nudges != 1 {
		t.Fatalf("an unchanged feed nudged: %d", r.nudges)
	}
	// It stopped being live: one more run publishes the end, then none.
	delete(r.live, 7)
	r.clock.advance(3 * time.Second)
	s.RunDue(ctx)
	r.clock.advance(60 * time.Second)
	s.RunDue(ctx)
	if r.callCount() != 3 {
		t.Fatalf("a finished session ran %d times, want 3", r.callCount())
	}
}

func TestSessionChatFailureAndTimeoutKeepTheLastPayload(t *testing.T) {
	ctx := context.Background()
	r := newChatRig(t)
	r.live[7] = time.Now()
	failing := false
	s := r.source(func(_ context.Context, _ int64, _ string) (ChatRead, error) {
		if failing {
			return ChatRead{}, errors.New("unreadable")
		}
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}}, nil
	}, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(ctx)
	first := chatItems(t, s)["7"]
	failing = true
	r.clock.advance(10 * time.Second)
	if n := len(s.RunDue(ctx)); n != 1 {
		t.Fatalf("%d attempted", n)
	}
	if got := chatItems(t, s)["7"]; !reflect.DeepEqual(got, first) {
		t.Fatal("a failure dropped the last payload")
	}

	hung := newChatRig(t)
	block := make(chan struct{})
	t.Cleanup(func() { close(block) })
	hs := hung.source(func(ctx context.Context, _ int64, _ string) (ChatRead, error) {
		<-block
		return ChatRead{}, nil
	}, ChatTiming{Every: 3 * time.Second, Timeout: 50 * time.Millisecond, Wake: time.Second})
	hung.watch(7, "", "")
	hs.RunDue(ctx)
	if len(chatItems(t, hs)) != 0 {
		t.Fatal("a hung read stored a payload")
	}
}

func TestSessionChatReadCutByStopOrExpiryStoresNothing(t *testing.T) {
	r := newChatRig(t)
	s := r.source(func(context.Context, int64, string) (ChatRead, error) {
		r.clock.advance(301 * time.Second)
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}}, nil
	}, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(context.Background())
	if len(chatItems(t, s)) != 0 || len(s.runs) != 0 {
		t.Fatal("a read that outlived its watch stored a payload")
	}

	r2 := newChatRig(t)
	ctx, cancel := context.WithCancel(context.Background())
	s2 := r2.source(func(context.Context, int64, string) (ChatRead, error) {
		cancel()
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}}, nil
	}, ChatTiming{})
	r2.watch(7, "", "")
	s2.RunDue(ctx)
	if len(chatItems(t, s2)) != 0 {
		t.Fatal("the read cut by the hub's stop stored a payload")
	}
}

func TestSessionChatRunDropsEverythingOnStop(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newChatRig(t)
		s := r.source(nil, ChatTiming{Every: 3 * time.Second, Timeout: time.Second, Wake: 10 * time.Millisecond})
		r.watch(7, "", "")
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() { done <- s.Run(ctx) }()
		for len(chatItems(t, s)) == 0 { // bubble time: one wake per step
			time.Sleep(10 * time.Millisecond)
			synctest.Wait()
		}
		cancel()
		<-done
		if len(chatItems(t, s)) != 0 || len(r.watches.Active(r.clock.Now())) != 0 {
			t.Fatal("the chat outlived the hub")
		}
	})
}

func TestSessionChatIsUrgentAfterTheAskKinds(t *testing.T) {
	if !slices.Contains(hubslices.UrgentKinds, hubslices.KindSessionChat) {
		t.Fatal("session_chat is not urgent")
	}
	if StandardChatTiming.Every != 3*time.Second || handlers.ChatWatchLength != 5*time.Minute {
		t.Fatal("the chat cadence changed")
	}
}

// feedFixture is a workbench with one Claude session whose transcript holds
// an owner line and an agent line.
type feedFixture struct {
	d       *db.DB
	dirs    sessionfeed.Dirs
	session int64
}

func newFeedFixture(t *testing.T) feedFixture {
	t.Helper()
	d := db.OpenTestDB(t)
	folder, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	claude := t.TempDir()
	dir := filepath.Join(claude, "projects", agentlog.Slug(folder))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	project := insertWorkbench(t, d, "acme", folder)
	conv := "00000000-0000-4000-8000-00000000f00d"
	session := lastID(t, exec(t, d, `INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'T', ?, ?)`, project, folder, conv))
	lines := []map[string]any{
		{"type": "user", "uuid": "u1", "timestamp": "2026-10-01T10:00:00Z", "message": map[string]any{"role": "user", "content": "hello"}},
		{"type": "assistant", "uuid": "a1", "timestamp": "2026-10-01T10:00:05Z", "message": map[string]any{
			"id": "m1", "role": "assistant", "content": []map[string]any{{"type": "text", "text": "hi there"}}}},
	}
	var b strings.Builder
	for _, l := range lines {
		raw, _ := json.Marshal(l)
		b.Write(raw)
		b.WriteByte('\n')
	}
	if err := os.WriteFile(filepath.Join(dir, conv+".jsonl"), []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return feedFixture{d: d, dirs: sessionfeed.Dirs{ClaudeProjects: filepath.Join(claude, "projects"), CodexHome: t.TempDir()}, session: session}
}

// rowCounts is every table's row count.
func rowCounts(t *testing.T, d *db.DB) map[string]int64 {
	t.Helper()
	out := map[string]int64{}
	for _, n := range tableNames(t, d) {
		var c int64
		if err := d.QueryRow(`SELECT COUNT(*) FROM "` + n + `"`).Scan(&c); err != nil {
			continue // a virtual table without its module
		}
		out[n] = c
	}
	return out
}

func tableNames(t *testing.T, d *db.DB) []string {
	t.Helper()
	rows, err := d.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		names = append(names, n)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return names
}

func mapsEqual(a, b map[string]int64) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

// The pass stops at the next feed once everything was dropped mid-pass
// (Swift runDue's isCurrent check).
func TestSessionChatPassStopsWhenDroppedMidPass(t *testing.T) {
	r := newChatRig(t)
	var s *SessionChatSource
	s = r.source(func(context.Context, int64, string) (ChatRead, error) {
		s.dropAll()
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}}, nil
	}, ChatTiming{})
	r.watch(7, "", "")
	r.watch(8, "", "")
	if got := s.RunDue(context.Background()); len(got) != 1 || r.callCount() != 1 {
		t.Fatalf("attempted %v, %d reads: the pass went on after the drop", got, r.callCount())
	}
	if len(chatItems(t, s)) != 0 {
		t.Fatal("the cut read stored a payload")
	}
}

// twin of SessionChatRunnerTests.testAChangedFeedNudgesTheChatKind: the
// first payload is a change, and a feed that changed nudges again.
func TestSessionChatAChangedFeedNudges(t *testing.T) {
	ctx := context.Background()
	r := newChatRig(t)
	r.live[7] = time.Now()
	text := "Hello"
	s := r.source(func(context.Context, int64, string) (ChatRead, error) {
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, text)}}, nil
	}, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(ctx)
	if r.nudges != 1 {
		t.Fatalf("the first payload nudged %d times, want 1", r.nudges)
	}
	text = "Hello again"
	r.clock.advance(3 * time.Second)
	s.RunDue(ctx)
	if r.nudges != 2 {
		t.Fatalf("a changed feed: %d nudges, want 2", r.nudges)
	}
}

// twin of SessionChatRunnerTests.testRepeatRequestExtendsWatch: a repeated
// request extends the 5-minute watch from the last request.
func TestSessionChatRepeatRequestExtendsTheWatch(t *testing.T) {
	r := newChatRig(t)
	s := r.source(nil, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(context.Background())
	r.clock.advance(200 * time.Second)
	r.watch(7, "", "")
	r.clock.advance(200 * time.Second)
	if n := len(chatItems(t, s)); n != 1 {
		t.Fatalf("400 s after the first request, 200 s after the last: %d records, want 1", n)
	}
	r.clock.advance(101 * time.Second)
	if got := chatItems(t, s); len(got) != 0 {
		t.Fatalf("the extended watch outlived its 5 minutes: %v", got)
	}
}

// twin of SessionChatRunnerTests.testLoopRunsOnlyWhilePhoneIsLinked: with no
// linked phone the loop wakes but reads no feed.
func TestSessionChatLoopReadsNothingWhileUnlinked(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newChatRig(t)
		var checks atomic.Int32
		s := SessionChat(r.watches, nil, SessionChatOptions{
			Timing: ChatTiming{Every: 10 * time.Second, Timeout: 5 * time.Second, Wake: 10 * time.Millisecond},
			Fetch: func(context.Context, int64, string) (ChatRead, error) {
				r.mu.Lock()
				r.calls = append(r.calls, "read")
				r.mu.Unlock()
				return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}}, nil
			},
			Active: func() bool {
				checks.Add(1)
				return false
			},
			Now: r.clock.Now,
		})
		r.watch(7, "", "")
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() { done <- s.Run(ctx) }()
		for checks.Load() < 3 { // bubble time: one wake per step
			time.Sleep(10 * time.Millisecond)
			synctest.Wait()
		}
		cancel()
		<-done
		if n := r.callCount(); n != 0 {
			t.Fatalf("the loop read %d feeds with no linked phone", n)
		}
	})
}

// Runners on request (#1996): a watch the phone opens through the source's
// RequestWatches wakes the loop at once, not on its next 2 s tick.
func TestSessionChatARequestWakesTheLoopAtOnce(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newChatRig(t)
		s := r.source(nil, ChatTiming{})
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() { done <- s.Run(ctx) }()
		defer func() { cancel(); <-done }()
		synctest.Wait() // the first pass: no watch, nothing read
		s.RequestWatches().Watch(handlers.ChatWatch{SessionID: 7, Expires: r.clock.Now().Add(handlers.ChatWatchLength)})
		synctest.Wait()
		if n := r.callCount(); n != 1 {
			t.Fatalf("%d reads right after the request, want 1", n)
		}
		if len(r.watches.Active(r.clock.Now())) != 1 {
			t.Fatal("the request opened no watch")
		}
		// A burst of requests while nothing is due reads nothing more.
		for range 5 {
			s.RequestWatches().Watch(handlers.ChatWatch{SessionID: 7, Expires: r.clock.Now().Add(handlers.ChatWatchLength)})
		}
		synctest.Wait()
		if n := r.callCount(); n != 1 {
			t.Fatalf("%d reads after a burst inside Every, want 1", n)
		}
	})
}

// Every payload of this hub says live_version 1: live or not, main or agent
// record, with or without a block.
func TestSessionChat_LiveVersionAlways(t *testing.T) {
	r := newChatRig(t)
	s := r.source(nil, ChatTiming{})
	r.watch(7, "", "")
	r.watch(8, "", "")
	r.watch(8, "a1b2", "toolu_01a")
	r.live[8] = time.Now()
	s.RunDue(context.Background())
	got := chatItems(t, s)
	if len(got) != 3 {
		t.Fatalf("records %v", got)
	}
	for id, p := range got {
		if num(p["live_version"]) != 1 {
			t.Errorf("record %s: live_version %v", id, p["live_version"])
		}
	}
}

// A session that is not live carries no live block and no live_error, even
// when the read produced one.
func TestSessionChat_NoLiveWhenFinished(t *testing.T) {
	r := newChatRig(t)
	s := r.source(liveRead(sampleLive()), ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(context.Background())
	p := chatItems(t, s)["7"]
	if _, ok := p["activity_live"]; ok || p["live"] != false {
		t.Fatalf("a finished session published a live block: %v", p)
	}
	failing := newChatRig(t)
	fs := failing.source(func(context.Context, int64, string) (ChatRead, error) {
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}, LiveErr: errors.New("gone")}, nil
	}, ChatTiming{})
	failing.watch(7, "", "")
	fs.RunDue(context.Background())
	if p := chatItems(t, fs)["7"]; p["live_error"] != nil || p["activity_live"] != nil {
		t.Fatalf("a finished session published a live error: %v", p)
	}
}

// A live read that fails while the feed read succeeds updates the entries,
// keeps the last block and says so in live_error; the next good read clears
// it. A whole read that fails keeps the payload and marks its block.
func TestSessionChat_LiveErrorKeepsLastLive(t *testing.T) {
	ctx := context.Background()
	r := newChatRig(t)
	r.live[7] = time.Now()
	read := ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}, Live: sampleLive()}
	var readErr error
	s := r.source(func(context.Context, int64, string) (ChatRead, error) { return read, readErr }, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(ctx)
	first := chatItems(t, s)["7"]
	if first["activity_live"] == nil || first["live_error"] != nil {
		t.Fatalf("first read: %v", first)
	}
	read = ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi"), feedEntry(1, "more")}, LiveErr: errors.New("unreadable")}
	r.clock.advance(3 * time.Second)
	s.RunDue(ctx)
	p := chatItems(t, s)["7"]
	if len(chatEntries(t, p)) != 2 {
		t.Fatalf("the entries did not update: %v", p["entries"])
	}
	if !reflect.DeepEqual(p["activity_live"], first["activity_live"]) || p["live_error"] != liveErrUnavailable {
		t.Fatalf("live %v, error %v: want the last block and the error", p["activity_live"], p["live_error"])
	}
	if r.nudges != 2 {
		t.Fatalf("%d nudges, want 2", r.nudges)
	}
	read = ChatRead{Entries: read.Entries, Live: sampleLive()}
	r.clock.advance(3 * time.Second)
	s.RunDue(ctx)
	if p := chatItems(t, s)["7"]; p["live_error"] != nil || p["activity_live"] == nil {
		t.Fatalf("a good read did not clear the error: %v", p)
	}
	readErr = errors.New("unreadable")
	r.clock.advance(3 * time.Second)
	s.RunDue(ctx)
	p = chatItems(t, s)["7"]
	if len(chatEntries(t, p)) != 2 || p["activity_live"] == nil || p["live_error"] != liveErrUnavailable {
		t.Fatalf("a failed read: %v", p)
	}
}

// A read that hangs past Timeout leaves the last block with live_error (a
// stuck read never looks current) and nudges once.
func TestSessionChat_HungLiveReadSetsError(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx := context.Background()
		r := newChatRig(t)
		r.live[7] = time.Now()
		block := make(chan struct{})
		defer close(block)
		hang := false
		s := r.source(func(context.Context, int64, string) (ChatRead, error) {
			if hang {
				<-block
			}
			return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}, Live: sampleLive()}, nil
		}, ChatTiming{Every: 3 * time.Second, Timeout: 30 * time.Second, Wake: time.Second})
		r.watch(7, "", "")
		s.RunDue(ctx)
		first := chatItems(t, s)["7"]
		hang = true
		r.clock.advance(3 * time.Second)
		start := time.Now()
		s.RunDue(ctx)
		if waited := time.Since(start); waited != 30*time.Second {
			t.Fatalf("the hung read was given up after %v", waited)
		}
		p := chatItems(t, s)["7"]
		if !reflect.DeepEqual(p["activity_live"], first["activity_live"]) || p["live_error"] != liveErrTimedOut {
			t.Fatalf("after a hung read: live %v, error %v", p["activity_live"], p["live_error"])
		}
		if !reflect.DeepEqual(p["entries"], first["entries"]) || r.nudges != 2 {
			t.Fatalf("entries %v, %d nudges", p["entries"], r.nudges)
		}
	})
}

// The live block is reserved first inside MaxChatBytes: the entries are
// trimmed around it, the block arrives whole, and a later failed read's
// live_error still fits.
func TestSessionChat_LiveReservedInBudget(t *testing.T) {
	at := time.Unix(1_700_000_060, 0).UTC()
	long := strings.Repeat("x", 300)
	big := &sessionfeed.Live{ObservedAt: at, TurnAt: at, TurnActive: true, AgentsState: "known"}
	for i := range 40 {
		big.Steps = append(big.Steps, sessionfeed.LiveAction{ID: "s" + itoa(i), Tool: "Bash", Summary: long, StartedAt: at})
	}
	for i := range 32 {
		big.Agents = append(big.Agents, sessionfeed.LiveAgent{
			Ref:    sessionfeed.SubagentRef{ToolUseID: "t" + itoa(i), AgentID: "a" + itoa(i), Description: long, Status: "running"},
			Action: &sessionfeed.LiveAction{ID: "x" + itoa(i), Summary: long},
		})
	}
	var entries []sessionfeed.Entry
	for i := range 300 {
		entries = append(entries, feedEntry(i, strings.Repeat("y", 4000)))
	}
	ctx := context.Background()
	r := newChatRig(t)
	r.live[7] = time.Now()
	var readErr error
	s := r.source(func(context.Context, int64, string) (ChatRead, error) {
		return ChatRead{Entries: entries, Live: big}, readErr
	}, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(ctx)
	check := func(when string) {
		t.Helper()
		items, err := s.Items(ctx)
		if err != nil || len(items) != 1 {
			t.Fatalf("%s: items %v, %v", when, items, err)
		}
		if n := len(items[0].Payload); n > MaxChatBytes {
			t.Fatalf("%s: payload %d bytes", when, n)
		}
		p := decode(t, items[0].Payload)
		kept := len(chatEntries(t, p))
		if kept >= 300 || kept == 0 || num(p["entries_more"]) != int64(300-kept) {
			t.Fatalf("%s: %d entries kept, more %v", when, kept, p["entries_more"])
		}
		block := p["activity_live"].(map[string]any)
		if len(block["steps"].([]any)) != 40 || len(block["agents"].([]any)) != 32 {
			t.Fatalf("%s: the block was cut", when)
		}
	}
	check("first read")
	readErr = errors.New("unreadable")
	r.clock.advance(3 * time.Second)
	s.RunDue(ctx)
	if p := chatItems(t, s)["7"]; p["live_error"] != liveErrUnavailable {
		t.Fatalf("the failed read did not mark the block: %v", p["live_error"])
	}
	check("after a failed read")
}

// An unchanged snapshot read again is no change: only observed_at moved,
// so nothing is published.
func TestSessionChat_ObservedAtAloneIsNoChange(t *testing.T) {
	ctx := context.Background()
	r := newChatRig(t)
	r.live[7] = time.Now()
	s := r.source(func(context.Context, int64, string) (ChatRead, error) {
		l := sampleLive()
		l.ObservedAt = r.clock.Now()
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}, Live: l}, nil
	}, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(ctx)
	first := chatItems(t, s)["7"]
	r.clock.advance(3 * time.Second)
	s.RunDue(ctx)
	if r.callCount() != 2 || r.nudges != 1 || !reflect.DeepEqual(chatItems(t, s)["7"], first) {
		t.Fatalf("%d reads, %d nudges: a moved observed_at was published", r.callCount(), r.nudges)
	}
}

// subagentFixture is newFeedFixture's session with a running Bash call and
// an Agent call in the main conversation, and that subagent's sidechain
// reading parser.go.
func subagentFixture(t *testing.T) (feedFixture, string) {
	t.Helper()
	fx := newFeedFixture(t)
	var dir string
	matches, _ := filepath.Glob(filepath.Join(fx.dirs.ClaudeProjects, "*", "*.jsonl"))
	if len(matches) != 1 {
		t.Fatalf("transcripts %v", matches)
	}
	conv := matches[0]
	dir = filepath.Join(strings.TrimSuffix(conv, ".jsonl"), "subagents")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	line := func(v map[string]any) string {
		b, _ := json.Marshal(v)
		return string(b) + "\n"
	}
	toolUse := func(uuid, id, name string, input map[string]any) string {
		return line(map[string]any{"type": "assistant", "uuid": uuid, "timestamp": "2026-10-01T10:00:06Z", "message": map[string]any{
			"id": "m" + uuid, "role": "assistant", "content": []map[string]any{{"type": "tool_use", "id": id, "name": name, "input": input}}}})
	}
	f, err := os.OpenFile(conv, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, err = f.WriteString(toolUse("a2", "toolu_sub", "Agent", map[string]any{"description": "check parser", "subagent_type": "Explore", "prompt": "look"}) +
		toolUse("a3", "toolu_bash", "Bash", map[string]any{"command": "go test ./internal/db"}))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(dir, "agent-a1b2.jsonl")
	if err := os.WriteFile(sub, []byte(toolUse("s1", "toolu_read", "Read", map[string]any{"file_path": "parser.go"})), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "agent-a1b2.meta.json"), []byte(`{"toolUseId":"toolu_sub","description":"check parser","agentType":"Explore","finished":false}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return fx, sub
}

// An agent record carries the live block of that subagent's sidechain (its
// own current step), the main record the main conversation's; the default
// read lists the files it read, the sidechain among them.
func TestSessionChat_SubagentRecordUsesSidechainLive(t *testing.T) {
	fx, sub := subagentFixture(t)
	r := newChatRig(t)
	r.live[fx.session] = time.Now()
	s := SessionChat(r.watches, fx.d, SessionChatOptions{Dirs: fx.dirs, Now: r.clock.Now, Liveness: func() Liveness { return Liveness{Runs: r.live} }})
	t.Cleanup(s.dropAll) // closes its file watcher
	r.watch(fx.session, "", "")
	r.watch(fx.session, "a1b2", "toolu_sub")
	s.RunDue(context.Background())
	got := chatItems(t, s)
	id := itoa(int(fx.session))
	current := func(rec string) string {
		t.Helper()
		block, ok := got[rec]["activity_live"].(map[string]any)
		if !ok {
			t.Fatalf("record %s has no live block: %v", rec, got[rec])
		}
		cur, ok := block["current"].(map[string]any)
		if !ok {
			t.Fatalf("record %s has no current step: %v", rec, block)
		}
		return cur["summary"].(string)
	}
	if c := current(id + "-a1b2"); c != "parser.go" {
		t.Fatalf("the agent record's current step is %q, want the sidechain's parser.go", c)
	}
	if c := current(id); c != "go test ./internal/db" {
		t.Fatalf("the main record's current step is %q", c)
	}
	read, err := s.o.Fetch(context.Background(), fx.session, "toolu_sub")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(read.Paths, sub) {
		t.Fatalf("the agent read's paths %v miss its sidechain %s", read.Paths, sub)
	}
	main, err := s.o.Fetch(context.Background(), fx.session, "")
	if err != nil || main.Live == nil || len(main.Paths) == 0 {
		t.Fatalf("main read: live %v, paths %v, %v", main.Live, main.Paths, err)
	}
}

// More than 40 steps: only the oldest finished ones are cut and counted; a
// step still running before them keeps its timer.
func TestSessionChat_PhoneLiveKeepsRunningSteps(t *testing.T) {
	at := time.Unix(1_700_000_060, 0).UTC()
	in := &sessionfeed.Live{StepsMore: 2}
	in.Steps = append(in.Steps, sessionfeed.LiveAction{ID: "open", Tool: "Bash", Summary: "sleep", StartedAt: at})
	for i := range 44 {
		in.Steps = append(in.Steps, sessionfeed.LiveAction{ID: "s" + itoa(i), Tool: "Read", Summary: "f", StartedAt: at, CompletedAt: at.Add(time.Second)})
	}
	out := phoneLive(in)
	if len(out.Steps) != 40 || out.Steps[0].ID != "open" || out.Steps[1].ID != "s5" || out.StepsMore != 2+5 {
		t.Fatalf("%d steps, first %s, second %s, more %d", len(out.Steps), out.Steps[0].ID, out.Steps[1].ID, out.StepsMore)
	}
	if len(in.Steps) != 45 {
		t.Fatal("phoneLive changed its input")
	}
}

// A failed live read is logged with its class only; its text never reaches
// the payload.
func TestSessionChat_LiveErrLoggedNotPublished(t *testing.T) {
	var buf strings.Builder
	var mu sync.Mutex
	prevOut, prevFlags := log.Writer(), log.Flags()
	log.SetOutput(writerFunc(func(p []byte) (int, error) { mu.Lock(); defer mu.Unlock(); return buf.Write(p) }))
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(prevOut); log.SetFlags(prevFlags) })
	r := newChatRig(t)
	r.live[7] = time.Now()
	s := r.source(func(context.Context, int64, string) (ChatRead, error) {
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}, LiveErr: errors.New("open /private/secret/path.jsonl: denied")}, nil
	}, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(context.Background())
	items, _ := s.Items(context.Background())
	if len(items) != 1 || strings.Contains(string(items[0].Payload), "secret/path") {
		t.Fatalf("payload %v", items)
	}
	mu.Lock()
	logged := buf.String()
	mu.Unlock()
	if !strings.Contains(logged, "live block of session 7 failed") || strings.Contains(logged, "secret/path") {
		t.Fatalf("log %q", logged)
	}
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

// Names and ids are bounded too; a block that still cannot fit the budget
// is dropped with live_error, never cut.
func TestSessionChat_LiveStringsBoundedAndOversizeDropped(t *testing.T) {
	long := strings.Repeat("n", 500)
	act := &sessionfeed.LiveAction{ID: long, Tool: long, Summary: "s"}
	out := phoneLive(&sessionfeed.Live{Conversation: long, AgentsState: long, Current: act, Steps: []sessionfeed.LiveAction{*act},
		Agents: []sessionfeed.LiveAgent{{Ref: sessionfeed.SubagentRef{ToolUseID: long, AgentID: long, Type: long, Status: long}, Action: act}}})
	ag := out.Agents[0]
	for name, n := range map[string]int{
		"tool": runes(out.Current.Tool), "step tool": runes(out.Steps[0].Tool), "type": runes(ag.Ref.Type), "status": runes(ag.Ref.Status),
		"agents_state": runes(out.AgentsState),
	} {
		if n != maxLiveName {
			t.Errorf("%s: %d runes", name, n)
		}
	}
	for name, n := range map[string]int{
		"id": runes(out.Current.ID), "conversation": runes(out.Conversation), "tool_use_id": runes(ag.Ref.ToolUseID),
		"agent_id": runes(ag.Ref.AgentID), "agent action id": runes(ag.Action.ID),
	} {
		if n != maxLiveID {
			t.Errorf("%s: %d runes", name, n)
		}
	}
	huge := &sessionfeed.Live{Conversation: strings.Repeat("x", MaxChatBytes)}
	b, err := encodeChat([]sessionfeed.Entry{feedEntry(0, "hi")}, 7, "", true, huge, "")
	if err != nil {
		t.Fatal(err)
	}
	p := decode(t, b)
	if len(b) > MaxChatBytes || p["activity_live"] != nil || p["live_error"] != liveErrUnavailable || len(chatEntries(t, p)) != 1 {
		t.Fatalf("oversize block: %d bytes, live_error %v", len(b), p["live_error"])
	}
}

// More than 40 running steps: the newest 40 stay, the current step always,
// and the rest are counted.
func TestSessionChat_PhoneLiveCapsRunningSteps(t *testing.T) {
	at := time.Unix(1_700_000_060, 0).UTC()
	in := &sessionfeed.Live{}
	for i := range 45 {
		in.Steps = append(in.Steps, sessionfeed.LiveAction{ID: "r" + itoa(i), Tool: "Bash", Summary: "x", StartedAt: at})
	}
	in.Current = &in.Steps[1]
	out := phoneLive(in)
	var ids []string
	for _, st := range out.Steps {
		ids = append(ids, st.ID)
	}
	if len(ids) != 40 || out.StepsMore != 5 || ids[0] != "r1" || ids[1] != "r6" || ids[39] != "r44" {
		t.Fatalf("%d steps %v, more %d", len(ids), ids, out.StepsMore)
	}
}

// The session stops and the last read fails: the record keeps its dialog,
// says not live, and drops the stale block without a live error; nothing is
// read after that.
func TestSessionChat_FailedReadAfterStopDropsTheBlock(t *testing.T) {
	ctx := context.Background()
	r := newChatRig(t)
	r.live[7] = time.Now()
	var readErr error
	s := r.source(func(context.Context, int64, string) (ChatRead, error) {
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}, Live: sampleLive()}, readErr
	}, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(ctx)
	first := chatItems(t, s)["7"]
	if first["activity_live"] == nil || first["live"] != true {
		t.Fatalf("first read: %v", first)
	}
	delete(r.live, 7)
	readErr = errors.New("unreadable")
	r.clock.advance(3 * time.Second)
	s.RunDue(ctx)
	p := chatItems(t, s)["7"]
	if p["live"] != false || p["activity_live"] != nil || p["live_error"] != nil || !reflect.DeepEqual(p["entries"], first["entries"]) {
		t.Fatalf("after the stop: %v", p)
	}
	if r.nudges != 2 {
		t.Fatalf("%d nudges, want 2", r.nudges)
	}
	r.clock.advance(60 * time.Second)
	s.RunDue(ctx)
	if r.callCount() != 2 {
		t.Fatalf("%d reads after the session stopped, want 2", r.callCount())
	}
}

// The first read of a live session fails: the record still arrives, with
// no entries and live_error, so the phone shows Unavailable + Retry instead
// of Loading forever; a finished session publishes nothing; the next good
// read replaces it.
func TestSessionChat_FirstReadFailsWhileLive(t *testing.T) {
	ctx := context.Background()
	r := newChatRig(t)
	r.live[7] = time.Now()
	readErr := errors.New("unreadable")
	s := r.source(func(context.Context, int64, string) (ChatRead, error) {
		return ChatRead{Entries: []sessionfeed.Entry{feedEntry(0, "hi")}, Live: sampleLive()}, readErr
	}, ChatTiming{})
	r.watch(7, "", "")
	r.watch(8, "", "")
	s.RunDue(ctx)
	got := chatItems(t, s)
	if _, ok := got["8"]; ok {
		t.Fatalf("a finished session's failed read published %v", got["8"])
	}
	p := got["7"]
	if p == nil || p["live"] != true || num(p["live_version"]) != 1 || p["live_error"] != liveErrUnavailable ||
		len(chatEntries(t, p)) != 0 || num(p["entries_more"]) != 0 || p["activity_live"] != nil {
		t.Fatalf("first failed read: %v", p)
	}
	if r.nudges != 1 {
		t.Fatalf("%d nudges, want 1", r.nudges)
	}
	readErr = nil
	r.clock.advance(3 * time.Second)
	s.RunDue(ctx)
	if p := chatItems(t, s)["7"]; p["live_error"] != nil || len(chatEntries(t, p)) != 1 || p["activity_live"] == nil {
		t.Fatalf("the good read did not replace it: %v", p)
	}
}
