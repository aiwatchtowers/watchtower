package sources

import (
	"context"
	"database/sql"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/rivo/uniseg"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
)

// chatNow is the chat tests' fake clock: every lease heartbeat and request
// is stamped from it, nothing waits on the wall clock.
var chatNow = time.Unix(1_700_000_500, 0)

func chatGranted() (bool, error) { return true, nil }

type fakeLive struct {
	conv    int64
	text    string
	steps   []chatstore.Step
	waiting bool
}

func (f fakeLive) Live(conv int64) (string, []chatstore.Step, bool, bool) {
	if conv != f.conv {
		return "", nil, false, false
	}
	return f.text, f.steps, f.waiting, true
}

// chatSeed writes chat rows as the Swift and Go turn stores leave them.
type chatSeed struct {
	t *testing.T
	d *db.DB
}

func (s chatSeed) conversation(title string, updated float64, extra string, args ...any) int64 {
	s.t.Helper()
	id := execID(s.t, s.d, `INSERT INTO chat_conversations (title, created_at, updated_at) VALUES (?, ?, ?)`, title, updated, updated)
	if extra != "" {
		exec(s.t, s.d, `UPDATE chat_conversations SET `+extra+` WHERE id = ?`, append(args, id)...)
	}
	return id
}

func (s chatSeed) message(conv int64, parent int64, role, text, status, turn string, created float64) int64 {
	s.t.Helper()
	var p any
	if parent != 0 {
		p = parent
	}
	id := execID(s.t, s.d, `INSERT INTO chat_messages (conversation_id, parent_id, role, text, status, turn_id, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, conv, p, role, text, status, turn, created)
	exec(s.t, s.d, `UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, id, conv)
	return id
}

func (s chatSeed) lease(conv int64, owner, turn string, heartbeat time.Time) {
	exec(s.t, s.d, `INSERT INTO chat_turn_leases (conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms)
		VALUES (?, ?, 'x', ?, ?, ?)`, conv, owner, turn, heartbeat.UnixMilli(), heartbeat.UnixMilli())
}

func (s chatSeed) action(conv int64, turn, status, args, reason string) int64 {
	return execID(s.t, s.d, `INSERT INTO agent_actions (tool, args_json, reason, surface, conversation_id, turn_id, status)
		VALUES ('send_slack_message', ?, ?, 'main', ?, ?, ?)`, args, reason, conv, turn, status)
}

func chatRecords(t *testing.T, src slices.Source) map[string]map[string]any {
	t.Helper()
	items, err := src.Items(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]map[string]any{}
	for _, it := range items {
		out[it.ID] = decode(t, it.Payload)
	}
	return out
}

func chatFeedOpts(w *ChatWatches, live LiveText) ChatFeedOptions {
	return ChatFeedOptions{Watches: w, Grant: chatGranted, Live: live, Now: func() time.Time { return chatNow }}
}

func TestChatList_PayloadMatchesKitFixture(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	project := execID(t, d, `INSERT INTO chat_projects (name, created_at, updated_at) VALUES ('Acme launch', 1, 1)`)
	conv := s.conversation("Payments rollout", 1_700_000_300, "pinned = 1, project_id = ?", project)
	s.message(conv, 0, "assistant", "## The rollout slipped to **Friday**.\nMore.", "complete", "turn-1", 1_700_000_010)
	s.lease(conv, "hub", "turn-2", chatNow.Add(-time.Second))
	src := ChatList(d, ChatListOptions{Grant: chatGranted, Models: func() []ChatModel {
		return []ChatModel{{Provider: "claude", Model: "opus", DisplayName: "Claude", Images: true, PDF: true}}
	}, Now: func() time.Time { return chatNow }})
	got := chatRecords(t, src)[ChatListID]
	if got == nil {
		t.Fatal("no chat_list record")
	}
	assertWireShape(t, got, kitFixture(t, "workbench/chat_list.json"), "error")
	c := got["conversations"].([]any)[0].(map[string]any)
	if c["last_line"] != "The rollout slipped to Friday." || c["state"] != ChatStateAnswering || c["lease_owner"] != "hub" {
		t.Errorf("row = %v", c)
	}
}

// waiting > answering > unread > read (ChatPanelRowState).
func TestChatList_StatePrecedence(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	all := s.conversation("all", 1, "")
	s.message(all, 0, "assistant", "a", "complete", "turn-a", 10)
	s.lease(all, "desktop", "turn-a", chatNow)
	s.action(all, "turn-a", "pending", "{}", "")

	oldTurn := s.conversation("old turn pending", 2, "")
	s.message(oldTurn, 0, "assistant", "a", "complete", "turn-b", 10)
	s.lease(oldTurn, "hub", "turn-b", chatNow.Add(-59*time.Second))
	s.action(oldTurn, "turn-old", "pending", "{}", "") // any pending row waits, as on the Mac

	answering := s.conversation("answering", 2, "")
	s.message(answering, 0, "assistant", "a", "complete", "turn-f", 10)
	s.lease(answering, "hub", "turn-f", chatNow.Add(-59*time.Second))
	s.action(answering, "turn-f", "applied", "{}", "")

	unread := s.conversation("unread", 3, "read_at = 5")
	s.message(unread, 0, "assistant", "a", "complete", "turn-c", 10)
	s.lease(unread, "hub", "turn-c", chatNow.Add(-61*time.Second)) // stale

	read := s.conversation("read", 4, "read_at = 10")
	s.message(read, 0, "assistant", "a", "complete", "turn-d", 10)
	s.action(read, "turn-d", "applied", "{}", "")

	never := s.conversation("no answer", 5, "")
	s.message(never, 0, "user", "q", "complete", "turn-e", 10)

	s.conversation("archived", 6, "archived_at = 1")
	s.conversation("discuss", 7, "context_type = 'target'")

	got := chatRecords(t, ChatList(d, ChatListOptions{Grant: chatGranted, Models: func() []ChatModel { return nil }, Now: func() time.Time { return chatNow }}))[ChatListID]
	states := map[string]string{}
	for _, c := range got["conversations"].([]any) {
		m := c.(map[string]any)
		states[m["title"].(string)] = m["state"].(string)
	}
	want := map[string]string{"all": "waiting", "old turn pending": "waiting", "answering": "answering", "unread": "unread", "read": "read", "no answer": "read"}
	if len(states) != len(want) {
		t.Fatalf("listed %v", states)
	}
	for k, v := range want {
		if states[k] != v {
			t.Errorf("%s: state %s, want %s", k, states[k], v)
		}
	}
}

func TestChatList_ReadFailurePublishesError(t *testing.T) {
	d := openDB(t)
	src := ChatList(d, ChatListOptions{Grant: chatGranted, Models: func() []ChatModel { return nil }})
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	got := chatRecords(t, src)[ChatListID]
	if got["error"] != chatListReadFailed || len(got["conversations"].([]any)) != 0 {
		t.Fatalf("payload = %v", got)
	}
}

// feedRig is the conversation chat_feed.json shows.
func feedRig(t *testing.T) (*db.DB, chatSeed, int64) {
	t.Helper()
	d := openDB(t)
	s := chatSeed{t, d}
	project := execID(t, d, `INSERT INTO chat_projects (name, created_at, updated_at) VALUES ('Acme launch', 1, 1)`)
	conv := s.conversation("Payments rollout", 1_700_000_300,
		"project_id = ?, routing_mode = 'pinned', provider = 'claude', model = 'opus', actual_provider = 'claude', actual_model = 'opus'", project)
	u1 := s.message(conv, 0, "user", "When does the payments rollout start?", "complete", "turn-1", 1_700_000_010)
	exec(t, d, `INSERT INTO chat_attachments (conversation_id, message_id, name, mime, size, path, sha256, created_at)
		VALUES (?, ?, 'plan.pdf', 'application/pdf', 2048, 'x', 'y', 1)`, conv, u1)
	s.message(conv, u1, "assistant", "An older answer.", "complete", "turn-0", 1_700_000_015)
	a1 := s.message(conv, u1, "assistant", "It slipped to Friday.", "complete", "turn-1", 1_700_000_020)
	exec(t, d, `INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, ok, summary, sources_json, started_at)
		VALUES (?, 1, 't1', 'search_knowledge', 1, '2 results', ?, 1)`, a1, `[{"kind":"slack","title":"#payments","url":"https://example.com/p1","ref":"msg-1"}]`)
	exec(t, d, `UPDATE chat_conversations SET live_slack_since = ? WHERE id = ?`, a1, conv)
	u2 := s.message(conv, a1, "user", "Tell the team.", "complete", "turn-2", 1_700_000_030)
	a2 := s.message(conv, u2, "assistant", "I will post it once you approve.", "partial", "turn-2", 1_700_000_040)
	exec(t, d, `UPDATE chat_messages SET error_code = 'session_lost', error_message = 'The session ended.' WHERE id = ?`, a2)
	s.lease(conv, "hub", "turn-2", chatNow)
	s.action(conv, "turn-2", "pending", `{"text":"The rollout moved to Friday."}`, "Tell the team about the new date")
	s.action(conv, "turn-other", "pending", `{}`, "") // another turn: not in this feed
	exec(t, d, `INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, created_at)
		VALUES (?, ?, 'rollout-plan', 1, 'document', 'Rollout plan', 'old', 1),
		       (?, ?, 'rollout-plan', 2, 'document', 'Rollout plan', '# Rollout plan', 2)`, conv, a1, conv, a2)
	return d, s, conv
}

func TestChatFeed_PayloadMatchesKitFixture(t *testing.T) {
	d, _, conv := feedRig(t)
	w := NewChatWatches()
	w.Watch(conv, ChatPurposeOpen, chatNow.Add(ChatOpenWatch))
	got := chatRecords(t, ChatFeed(d, chatFeedOpts(w, nil)))
	feed := got[idStr(conv)]
	if feed == nil {
		t.Fatalf("records %v", got)
	}
	assertWireShape(t, feed, kitFixture(t, "workbench/chat_feed.json"))
	msgs := feed["messages"].([]any)
	if len(msgs) != 4 || feed["has_more"] != false {
		t.Fatalf("%d messages, has_more %v", len(msgs), feed["has_more"])
	}
	answer := msgs[1].(map[string]any)
	if sib := answer["siblings"].(map[string]any); num(sib["index"]) != 2 || num(sib["count"]) != 2 {
		t.Errorf("siblings %v", sib)
	}
	actions := feed["actions"].([]any)
	if len(actions) != 1 || actions[0].(map[string]any)["args_sha256"] == "" {
		t.Errorf("actions %v", actions)
	}
	arts := feed["artifacts"].([]any)
	if len(arts) != 1 || num(arts[0].(map[string]any)["version"]) != 2 {
		t.Errorf("artifacts %v", arts)
	}
}

func TestChatFeed_CapsDropOldestThenArtifacts(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	conv := s.conversation("big", 1, "")
	var parent, last int64
	for i := range 60 {
		role := "user"
		if i%2 == 1 {
			role = "assistant"
		}
		parent = s.message(conv, parent, role, strings.Repeat("x", 30_000), "complete", "turn", float64(i))
		last = parent
	}
	for i := range 4 {
		exec(t, d, `INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, created_at)
			VALUES (?, ?, ?, 1, 'document', 'A', ?, 1)`, conv, last, "k"+idStr(int64(i)), strings.Repeat("y", 200_000))
	}
	w := NewChatWatches()
	w.Watch(conv, ChatPurposeOpen, chatNow.Add(ChatOpenWatch))
	items, err := ChatFeed(d, chatFeedOpts(w, nil)).Items(context.Background())
	if err != nil || len(items) != 1 {
		t.Fatalf("%d items, %v", len(items), err)
	}
	if n := len(items[0].Payload); n > MaxChatFeedBytes {
		t.Fatalf("payload %d bytes", n)
	}
	feed := decode(t, items[0].Payload)
	msgs := feed["messages"].([]any)
	if feed["has_more"] != true || len(msgs) == 0 || num(msgs[len(msgs)-1].(map[string]any)["id"]) != last {
		t.Fatalf("has_more %v, %d messages", feed["has_more"], len(msgs))
	}
	cut := 0
	for _, a := range feed["artifacts"].([]any) {
		if a.(map[string]any)["content_cut"] == true {
			cut++
			if _, ok := a.(map[string]any)["content"]; ok {
				t.Error("a cut artifact keeps its content")
			}
		}
	}
	if cut == 0 || cut == 4 {
		t.Errorf("%d of 4 artifacts cut", cut)
	}
}

func TestChatFeed_MessageTextCut40000(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	conv := s.conversation("long", 1, "")
	s.message(conv, 0, "assistant", strings.Repeat("é", 40_001), "complete", "turn", 1)
	w := NewChatWatches()
	w.Watch(conv, ChatPurposeOpen, chatNow.Add(ChatOpenWatch))
	m := chatRecords(t, ChatFeed(d, chatFeedOpts(w, nil)))[idStr(conv)]["messages"].([]any)[0].(map[string]any)
	if m["text_cut"] != true || runes(m["text"]) != MaxChatMessageText {
		t.Fatalf("text_cut %v, %d runes", m["text_cut"], runes(m["text"]))
	}
}

func liveFeedRig(t *testing.T, owner string) (*db.DB, int64, int64) {
	t.Helper()
	d := openDB(t)
	s := chatSeed{t, d}
	conv := s.conversation("live", 1, "")
	u := s.message(conv, 0, "user", "q", "complete", "turn-9", 1)
	a := s.message(conv, u, "assistant", "flushed", "partial", "turn-9", 2)
	exec(t, d, `INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, summary, started_at) VALUES (?, 1, 't', 'old_step', '', 1)`, a)
	s.lease(conv, owner, "turn-9", chatNow)
	return d, conv, a
}

func TestChatFeed_HubTurnUsesLiveText(t *testing.T) {
	d, conv, _ := liveFeedRig(t, "hub")
	live := fakeLive{conv: conv, text: "streaming now", waiting: true, steps: []chatstore.Step{
		{Name: "search_knowledge", State: chatstore.StepSucceeded, Summary: "1 result", Sources: []chat.Source{{Kind: "kb", Title: "Doc", Ref: "r"}}},
		{Name: "list_messages", State: chatstore.StepRunning},
	}}
	w := NewChatWatches()
	w.Watch(conv, ChatPurposeOpen, chatNow.Add(ChatOpenWatch))
	feed := chatRecords(t, ChatFeed(d, chatFeedOpts(w, live)))[idStr(conv)]
	m := feed["messages"].([]any)[1].(map[string]any)
	steps := m["steps"].([]any)
	if m["text"] != "streaming now" || len(steps) != 2 || steps[0].(map[string]any)["ok"] != true {
		t.Fatalf("message %v", m)
	}
	if _, ok := steps[1].(map[string]any)["ok"]; ok {
		t.Error("a running step has no ok")
	}
	if lease := feed["conversation"].(map[string]any)["lease"].(map[string]any); lease["waiting_slot"] != true {
		t.Errorf("lease %v", lease)
	}
}

func TestChatFeed_DesktopTurnReadsDB(t *testing.T) {
	d, conv, _ := liveFeedRig(t, "desktop")
	w := NewChatWatches()
	w.Watch(conv, ChatPurposeOpen, chatNow.Add(ChatOpenWatch))
	feed := chatRecords(t, ChatFeed(d, chatFeedOpts(w, fakeLive{conv: conv, text: "not this"})))[idStr(conv)]
	m := feed["messages"].([]any)[1].(map[string]any)
	if m["text"] != "flushed" || m["steps"].([]any)[0].(map[string]any)["name"] != "old_step" {
		t.Fatalf("message %v", m)
	}
}

// With no phone holding the chat grant (unlinked, or the grant turned off)
// every watch, page and search is dropped, so they are not back once a
// phone is granted again.
func TestChatFeed_UnlinkDropsWatches(t *testing.T) {
	d, _, conv := feedRig(t)
	granted := true
	w := NewChatWatches()
	o := chatFeedOpts(w, nil)
	o.Grant = func() (bool, error) { return granted, nil }
	feed, page, search := ChatFeed(d, o), ChatPage(d, o), ChatSearch(d, o)
	w.Watch(conv, ChatPurposeOpen, chatNow.Add(ChatOpenWatch))
	w.Pages.Request(ChatPageKey{Conversation: conv, Before: 12}, chatNow.Add(ChatRequestHold))
	w.Searches.Request("payments", chatNow.Add(ChatRequestHold))
	for _, src := range []slices.Source{feed, page, search} {
		if len(chatRecords(t, src)) != 1 {
			t.Fatalf("%s: not published while granted", src.Kind())
		}
	}
	granted = false
	for _, src := range []slices.Source{feed, page, search} {
		if len(chatRecords(t, src)) != 0 {
			t.Fatalf("%s: published without a chat phone", src.Kind())
		}
	}
	granted = true
	for _, src := range []slices.Source{feed, page, search} {
		if len(chatRecords(t, src)) != 0 {
			t.Fatalf("%s: a dropped request came back", src.Kind())
		}
	}
	if w.Open(conv, chatNow.Add(-time.Minute)) {
		t.Error("the open watch survived")
	}
}

func TestChatFeed_PrefetchRecordGoneAfter2Min(t *testing.T) {
	d, _, conv := feedRig(t)
	now := chatNow
	w := NewChatWatches()
	o := chatFeedOpts(w, nil)
	o.Now = func() time.Time { return now }
	src := ChatFeed(d, o)
	w.Watch(conv, ChatPurposePrefetch, chatNow.Add(ChatPrefetchHold))
	if w.Open(conv, chatNow.Add(-time.Minute)) {
		t.Fatal("a prefetch counts as looking")
	}
	now = chatNow.Add(ChatPrefetchHold - time.Second)
	if len(chatRecords(t, src)) != 1 {
		t.Fatal("the prefetched feed is not published")
	}
	now = chatNow.Add(ChatPrefetchHold)
	if len(chatRecords(t, src)) != 0 {
		t.Fatal("the prefetched feed outlived 2 minutes")
	}
}

func TestChatWatches_OpenAndRepeat(t *testing.T) {
	w := NewChatWatches()
	w.Watch(4, "", chatNow.Add(ChatOpenWatch)) // a missing purpose is open
	if !w.Open(4, chatNow) || w.Open(4, chatNow.Add(time.Second)) || w.Open(5, chatNow) {
		t.Fatal("open request time")
	}
	w.Watch(4, ChatPurposePrefetch, chatNow.Add(time.Hour))
	if w.Open(4, chatNow.Add(time.Second)) {
		t.Fatal("a later prefetch moved the open time")
	}
	w.Watch(4, ChatPurposeOpen, chatNow.Add(-time.Hour)) // an old repeat never shortens
	if got := w.activeFeeds(chatNow.Add(time.Hour - time.Second)); len(got) != 1 {
		t.Fatalf("active %v", got)
	}
}

func TestChatPage_SixtyBeforeID(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	conv := s.conversation("long", 1, "")
	var ids []int64
	var parent int64
	for i := range 150 {
		parent = s.message(conv, parent, "user", "m"+idStr(int64(i)), "complete", "t", float64(i))
		ids = append(ids, parent)
	}
	w := NewChatWatches()
	page := ChatPage(d, chatFeedOpts(w, nil))
	k := ChatPageKey{Conversation: conv, Before: ids[90]}
	w.Pages.Request(k, chatNow.Add(ChatRequestHold))
	w.Pages.Request(ChatPageKey{Conversation: conv, Before: ids[30]}, chatNow.Add(ChatRequestHold))
	got := chatRecords(t, page)
	p := got[ChatPageID(k)]
	msgs := p["messages"].([]any)
	if len(msgs) != 60 || num(msgs[0].(map[string]any)["id"]) != ids[30] || num(msgs[59].(map[string]any)["id"]) != ids[89] || p["has_more"] != true {
		t.Fatalf("page of %d, has_more %v", len(msgs), p["has_more"])
	}
	assertWireShape(t, p, kitFixture(t, "workbench/chat_page.json"))
	first := got[ChatPageID(ChatPageKey{Conversation: conv, Before: ids[30]})]
	if len(first["messages"].([]any)) != 30 || first["has_more"] != false {
		t.Fatalf("first page %v", first["has_more"])
	}
}

func TestChatSearch_RecordShape(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	conv := s.conversation("Rollout", 1, "")
	s.message(conv, 0, "assistant", "The payments rollout slipped to Friday. "+strings.Repeat("filler words here ", 30), "complete", "t", 1_700_000_020)
	notes := s.conversation("Weekly notes", 1_700_000_200, "")
	s.message(notes, 0, "user", "payments again", "complete", "t", 1)
	w := NewChatWatches()
	w.Searches.Request("payments", chatNow.Add(ChatRequestHold))
	got := chatRecords(t, ChatSearch(d, chatFeedOpts(w, nil)))[ChatSearchID("payments")]
	if got == nil {
		t.Fatal("no chat_search record")
	}
	assertWireShape(t, got, kitFixture(t, "workbench/chat_search.json"))
	hits := got["hits"].([]any)
	if len(hits) != 2 || got["query"] != "payments" {
		t.Fatalf("hits %v", hits)
	}
	for _, h := range hits {
		if runes(h.(map[string]any)["snippet"]) > MaxChatSearchSnippet {
			t.Errorf("snippet over the cap: %v", h)
		}
	}
	if ChatSearchID("payments") != "df384ae97c77ad30" {
		t.Errorf("ChatSearchID = %s (the Kit's ChatSearch.recordName must agree)", ChatSearchID("payments"))
	}
}

// Every chat source publishes only while a linked phone holds the chat
// grant (state.Store.AnyChatPhone).
func TestChatSources_OnlyWithChatGrant(t *testing.T) {
	d, _, conv := feedRig(t)
	dir := filepath.Join(t.TempDir(), "hub")
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	w := NewChatWatches()
	o := ChatFeedOptions{Watches: w, Grant: st.AnyChatPhone, Now: func() time.Time { return chatNow }}
	list := ChatList(d, ChatListOptions{Grant: st.AnyChatPhone, Models: func() []ChatModel { return nil }, Now: o.Now})
	srcs := []slices.Source{list, ChatFeed(d, o), ChatPage(d, o), ChatSearch(d, o)}
	request := func() {
		w.Watch(conv, ChatPurposeOpen, chatNow.Add(ChatOpenWatch))
		w.Pages.Request(ChatPageKey{Conversation: conv, Before: 12}, chatNow.Add(ChatRequestHold))
		w.Searches.Request("payments", chatNow.Add(ChatRequestHold))
	}
	published := func() int {
		n := 0
		for _, s := range srcs {
			n += len(chatRecords(t, s))
		}
		return n
	}
	request()
	if n := published(); n != 0 {
		t.Fatalf("no phone linked: %d records", n)
	}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{ID: "AAAAAAAA-0000-4000-8000-0000000000C1", Name: "p", Scope: "private", LinkedAt: time.Unix(1, 0)})
	}); err != nil {
		t.Fatal(err)
	}
	request()
	if n := published(); n != 4 {
		t.Fatalf("a chat phone linked: %d records, want 4", n)
	}
	raw, err := sql.Open("sqlite3", filepath.Join(dir, state.FileName))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = raw.Close() }()
	if _, err := raw.Exec(`UPDATE devices SET chat_allowed = 0`); err != nil {
		t.Fatal(err)
	}
	if n := published(); n != 0 {
		t.Fatalf("the grant turned off: %d records", n)
	}
}

func idStr(v int64) string { return strconv.FormatInt(v, 10) }

// zwj is one grapheme of 25 UTF-8 bytes (a family emoji).
const zwj = "👩‍👩‍👧‍👦"

func feedRecord(t *testing.T, d *db.DB, conv int64) []byte {
	t.Helper()
	w := NewChatWatches()
	w.Watch(conv, ChatPurposeOpen, chatNow.Add(ChatOpenWatch))
	items, err := ChatFeed(d, chatFeedOpts(w, nil)).Items(context.Background())
	if err != nil || len(items) != 1 {
		t.Fatalf("%d items, %v", len(items), err)
	}
	if n := len(items[0].Payload); n > MaxChatFeedBytes {
		t.Fatalf("feed record %d bytes, over %d", n, MaxChatFeedBytes)
	}
	return items[0].Payload
}

// A newest message of 40 000 wide graphemes (~1 MB) alone is over the cap:
// its text is cut further by encoded bytes, never the record refused.
func TestChatFeed_WideGraphemesStayUnderCap(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	conv := s.conversation("wide", 1, "")
	u := s.message(conv, 0, "user", strings.Repeat(zwj, 1000), "complete", "turn-1", 1)
	a := s.message(conv, u, "assistant", strings.Repeat(zwj, 40_001), "complete", "turn-1", 2)
	feed := decode(t, feedRecord(t, d, conv))
	msgs := feed["messages"].([]any)
	last := msgs[len(msgs)-1].(map[string]any)
	if num(last["id"]) != a || last["text_cut"] != true || runes(last["text"]) == 0 {
		t.Fatalf("newest message %v cut %v", last["id"], last["text_cut"])
	}
}

// Escaped control characters (6 bytes each) in the text, the actions and
// the steps of one turn: the actions of dropped turns go, then the text is
// cut, the steps emptied and actions dropped until the record fits.
func TestChatFeed_EscapedTextActionsAndStepsStayUnderCap(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	conv := s.conversation("escaped", 1, "")
	ctl := strings.Repeat("\x01", 40_000)
	old := s.message(conv, 0, "user", ctl, "complete", "turn-old", 1)
	s.action(conv, "turn-old", "applied", `{"text":"old"}`, "")
	oldAnswer := s.message(conv, old, "assistant", ctl, "complete", "turn-old", 2)
	u := s.message(conv, oldAnswer, "user", ctl, "complete", "turn-new", 3)
	a := s.message(conv, u, "assistant", ctl, "partial", "turn-new", 4)
	for i := range 60 {
		exec(t, d, `INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, summary, started_at) VALUES (?, ?, ?, 'step', ?, 1)`,
			a, i, "t"+idStr(int64(i)), strings.Repeat("\x02", 3000))
		s.action(conv, "turn-new", "pending", `{"text":"`+strings.Repeat(`\u0003`, 4000)+`"}`, "")
	}
	feed := decode(t, feedRecord(t, d, conv))
	msgs := feed["messages"].([]any)
	if feed["has_more"] != true || num(msgs[len(msgs)-1].(map[string]any)["id"]) != a {
		t.Fatalf("has_more %v, %d messages", feed["has_more"], len(msgs))
	}
	for _, x := range feed["actions"].([]any) {
		if strings.Contains(x.(map[string]any)["args_display"].(string), "old") {
			t.Error("an action of a dropped turn stayed")
		}
	}
}

func TestChatPage_WideGraphemesStayUnderCap(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	conv := s.conversation("wide page", 1, "")
	var parent int64
	var ids []int64
	for i := range 4 {
		parent = s.message(conv, parent, "user", strings.Repeat(zwj, 40_001), "complete", "t", float64(i))
		ids = append(ids, parent)
	}
	w := NewChatWatches()
	k := ChatPageKey{Conversation: conv, Before: ids[3]}
	w.Pages.Request(k, chatNow.Add(ChatRequestHold))
	items, err := ChatPage(d, chatFeedOpts(w, nil)).Items(context.Background())
	if err != nil || len(items) != 1 || len(items[0].Payload) > MaxChatFeedBytes {
		t.Fatalf("%d items, %v", len(items), err)
	}
	p := decode(t, items[0].Payload)
	msgs := p["messages"].([]any)
	if p["has_more"] != true || num(msgs[len(msgs)-1].(map[string]any)["id"]) != ids[2] {
		t.Fatalf("page %v", p["has_more"])
	}
}

func TestChatSearch_WideTitlesStayUnderCap(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	for i := range 60 {
		conv := s.conversation("payments "+strings.Repeat(zwj, 5000), float64(i), "")
		s.message(conv, 0, "user", "payments "+strings.Repeat(zwj+" \x01", 2000), "complete", "t", 1)
	}
	w := NewChatWatches()
	w.Searches.Request("payments", chatNow.Add(ChatRequestHold))
	items, err := ChatSearch(d, chatFeedOpts(w, nil)).Items(context.Background())
	if err != nil || len(items) != 1 || len(items[0].Payload) > MaxChatFeedBytes {
		t.Fatalf("%d items, %v, %d bytes", len(items), err, len(items[0].Payload))
	}
	for _, h := range decode(t, items[0].Payload)["hits"].([]any) {
		if uniseg.GraphemeClusterCount(h.(map[string]any)["title"].(string)) > maxChatLabel {
			t.Fatal("title not clipped")
		}
	}
}

// 200 conversations with very long titles of wide graphemes: titles and
// project names are clipped at 200 and the record stays within the cap.
func TestChatList_WideTitlesStayUnderCap(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	project := execID(t, d, `INSERT INTO chat_projects (name, created_at, updated_at) VALUES (?, 1, 1)`, strings.Repeat(zwj, 5000))
	for i := range 210 {
		conv := s.conversation(strings.Repeat(zwj, 5000), float64(i), "project_id = ?", project)
		s.message(conv, 0, "assistant", strings.Repeat(zwj, 500), "complete", "t", 1)
	}
	src := ChatList(d, ChatListOptions{Grant: chatGranted, Models: func() []ChatModel { return nil }, Now: func() time.Time { return chatNow }})
	items, err := src.Items(context.Background())
	if err != nil || len(items) != 1 {
		t.Fatalf("%d items, %v", len(items), err)
	}
	if n := len(items[0].Payload); n > MaxChatFeedBytes {
		t.Fatalf("chat_list record %d bytes, over %d", n, MaxChatFeedBytes)
	}
	list := decode(t, items[0].Payload)
	convs := list["conversations"].([]any)
	if len(convs) == 0 {
		t.Fatal("no conversation kept")
	}
	first := convs[0].(map[string]any)
	if uniseg.GraphemeClusterCount(first["title"].(string)) > maxChatLabel ||
		uniseg.GraphemeClusterCount(first["project"].(map[string]any)["name"].(string)) > maxChatLabel ||
		uniseg.GraphemeClusterCount(first["last_line"].(string)) > MaxChatLastLine {
		t.Fatal("a text is not clipped")
	}
	if num(first["id"]) != 210 {
		t.Errorf("the newest conversation must stay first, got %v", first["id"])
	}
}

// TestChatRequests_RepeatRebuilds: a chat_page or chat_search asked again
// within its hold (a Retry, a reopened screen) is built anew from the
// database, never the first request's copy (T5 handoff item 12).
func TestChatRequests_RepeatRebuilds(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	conv := s.conversation("Rollout", 1, "")
	s.message(conv, 0, "user", "payments first", "complete", "t", 1_700_000_020)
	w := NewChatWatches()
	src := ChatSearch(d, chatFeedOpts(w, nil))
	w.Searches.Request("payments", chatNow.Add(ChatRequestHold))
	hits := func() int {
		return len(chatRecords(t, src)[ChatSearchID("payments")]["hits"].([]any))
	}
	if n := hits(); n != 1 {
		t.Fatalf("first build: %d hits", n)
	}
	other := s.conversation("Notes", 2, "")
	s.message(other, 0, "user", "payments second", "complete", "t", 1_700_000_030)
	if n := hits(); n != 1 {
		t.Fatalf("a publish of the same request rebuilt it: %d hits", n)
	}
	w.Searches.Request("payments", chatNow.Add(ChatRequestHold))
	if n := hits(); n != 2 {
		t.Fatalf("the repeated request served the old record: %d hits", n)
	}
}

// TestChatRequests_ExpiredThenRepeatedRebuilds: a key that expired (its
// generation dropped by an Active read, e.g. the hub's chat timer) and is
// asked again before the source prunes its cache gets a new record, never
// the expired request's copy.
func TestChatRequests_ExpiredThenRepeatedRebuilds(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	conv := s.conversation("Rollout", 1, "")
	s.message(conv, 0, "user", "payments first", "complete", "t", 1_700_000_020)
	w := NewChatWatches()
	now := chatNow
	o := chatFeedOpts(w, nil)
	o.Now = func() time.Time { return now }
	src := ChatSearch(d, o)
	w.Searches.Request("payments", now.Add(ChatRequestHold))
	if n := len(chatRecords(t, src)[ChatSearchID("payments")]["hits"].([]any)); n != 1 {
		t.Fatalf("first build: %d hits", n)
	}
	other := s.conversation("Notes", 2, "")
	s.message(other, 0, "user", "payments second", "complete", "t", 1_700_000_030)
	now = now.Add(ChatRequestHold)
	if got := w.Searches.Active(now); len(got) != 0 { // expired: its generation goes
		t.Fatalf("still active: %v", got)
	}
	w.Searches.Request("payments", now.Add(ChatRequestHold))
	if n := len(chatRecords(t, src)[ChatSearchID("payments")]["hits"].([]any)); n != 2 {
		t.Fatalf("the repeat after expiry served the old record: %d hits", n)
	}
}
