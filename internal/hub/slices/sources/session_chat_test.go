package sources

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
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
func (r *chatRig) source(fetch ChatFetch, timing ChatTiming) *SessionChatSource {
	if fetch == nil {
		fetch = func(_ context.Context, id int64, toolUseID string) ([]sessionfeed.Entry, error) {
			return []sessionfeed.Entry{{ID: "e1", Kind: sessionfeed.KindOwner, At: time.Unix(1_700_000_000, 0), Text: "Hello"}}, nil
		}
	}
	return SessionChat(r.watches, nil, SessionChatOptions{
		Timing: timing,
		Fetch: func(ctx context.Context, id int64, toolUseID string) ([]sessionfeed.Entry, error) {
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
		Now: r.clock.Now,
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

func encodeChatJSON(t *testing.T, entries []sessionfeed.Entry, agent string) ([]byte, map[string]any) {
	t.Helper()
	b, err := encodeChat(entries, 7, agent, true)
	if err != nil {
		t.Fatal(err)
	}
	return b, decode(t, b)
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
	s := r.source(func(_ context.Context, _ int64, _ string) ([]sessionfeed.Entry, error) {
		if failing {
			return nil, errors.New("unreadable")
		}
		return []sessionfeed.Entry{feedEntry(0, "hi")}, nil
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
	hs := hung.source(func(ctx context.Context, _ int64, _ string) ([]sessionfeed.Entry, error) {
		<-block
		return nil, nil
	}, ChatTiming{Every: 3 * time.Second, Timeout: 50 * time.Millisecond, Wake: time.Second})
	hung.watch(7, "", "")
	hs.RunDue(ctx)
	if len(chatItems(t, hs)) != 0 {
		t.Fatal("a hung read stored a payload")
	}
}

func TestSessionChatReadCutByStopOrExpiryStoresNothing(t *testing.T) {
	r := newChatRig(t)
	s := r.source(func(context.Context, int64, string) ([]sessionfeed.Entry, error) {
		r.clock.advance(301 * time.Second)
		return []sessionfeed.Entry{feedEntry(0, "hi")}, nil
	}, ChatTiming{})
	r.watch(7, "", "")
	s.RunDue(context.Background())
	if len(chatItems(t, s)) != 0 || len(s.runs) != 0 {
		t.Fatal("a read that outlived its watch stored a payload")
	}

	r2 := newChatRig(t)
	ctx, cancel := context.WithCancel(context.Background())
	s2 := r2.source(func(context.Context, int64, string) ([]sessionfeed.Entry, error) {
		cancel()
		return []sessionfeed.Entry{feedEntry(0, "hi")}, nil
	}, ChatTiming{})
	r2.watch(7, "", "")
	s2.RunDue(ctx)
	if len(chatItems(t, s2)) != 0 {
		t.Fatal("the read cut by the hub's stop stored a payload")
	}
}

func TestSessionChatRunDropsEverythingOnStop(t *testing.T) {
	r := newChatRig(t)
	s := r.source(nil, ChatTiming{Every: 3 * time.Second, Timeout: time.Second, Wake: 10 * time.Millisecond})
	r.watch(7, "", "")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	deadline := time.Now().Add(5 * time.Second)
	for len(chatItems(t, s)) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the loop never stored the payload")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done
	if len(chatItems(t, s)) != 0 || len(r.watches.Active(r.clock.Now())) != 0 {
		t.Fatal("the chat outlived the hub")
	}
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
	s = r.source(func(context.Context, int64, string) ([]sessionfeed.Entry, error) {
		s.dropAll()
		return []sessionfeed.Entry{feedEntry(0, "hi")}, nil
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
