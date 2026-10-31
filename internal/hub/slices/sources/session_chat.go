package sources

import (
	"bytes"
	"cmp"
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"sync"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions/handlers"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionfeed"
)

// The session_chat payload's caps (SessionChatPayload, FEED-05).
const (
	MaxChatEntries = 300
	MaxChatText    = 4000
	MaxChatBytes   = 600_000
	maxChatLabel   = 200
)

// phoneFeedKinds are the FEED-02 kinds a session_chat payload carries
// (SessionFeedEntry.phoneKinds): no tool calls, thinking, events or kinds a
// newer reader adds.
var phoneFeedKinds = []sessionfeed.Kind{
	sessionfeed.KindOwner, sessionfeed.KindAgent, sessionfeed.KindAskAnswer, sessionfeed.KindWatchtower,
	sessionfeed.KindBrief, sessionfeed.KindSubagent, sessionfeed.KindSeparator,
}

// ChatTiming is the session chat runner's cadence (SessionChatRunner.Timing;
// the watch length is handlers.ChatWatchLength).
type ChatTiming struct {
	// Every is the regular run of a live session.
	Every time.Duration
	// Timeout bounds one feed read.
	Timeout time.Duration
	// Wake is how often the loop looks for due watches.
	Wake time.Duration
}

// StandardChatTiming is SessionChatRunner.Timing.standard.
var StandardChatTiming = ChatTiming{Every: 3 * time.Second, Timeout: 30 * time.Second, Wake: 2 * time.Second}

// ChatFetch reads a session's whole feed (toolUseID "") or one subagent's.
type ChatFetch func(ctx context.Context, sessionID int64, toolUseID string) ([]sessionfeed.Entry, error)

// SessionChatOptions wires the session_chat source. Timing zero is
// StandardChatTiming; Fetch nil reads the feed in-process with
// sessionfeed.ReadSession (what `workbench session-feed --json` prints)
// under Dirs (zero = ~/.claude/projects and the Codex home); Liveness nil is
// nothing live; Active nil is always (the hub's linked-phone gate); OnChange
// (nil = none) is called after a run stored a payload that differs from the
// previous one — the hub nudges the publisher's fast lane with it; Now nil
// is time.Now and must be the clock the session_chat_request handler stamps
// the watches with.
type SessionChatOptions struct {
	Timing   ChatTiming
	Fetch    ChatFetch
	Dirs     sessionfeed.Dirs
	Liveness func() Liveness
	Active   func() bool
	OnChange func()
	Now      func() time.Time
}

// SessionChatSource is the `session_chat` slice (FEED-05), record
// `session_chat-<session id>` or, for a subagent's feed,
// `session_chat-<session id>-<agent id>`: the capped chat of a workbench
// session the phone watches (handlers.ChatWatches, opened by
// session_chat_request for 5 minutes). Per watch it reads the feed once
// when the watch opens, every 3 s while the session is live, and once more
// after it stopped being live; a finished session runs once per watch.
//
// The payloads live in this source's memory only: never in watchtower.db
// (FEED-01) nor the hub sidecar, sealed only when the publisher pushes them.
// A watch that expires loses its payload (the publisher deletes the record);
// with no linked phone every watch and payload is dropped for good, and so
// when Run returns. A failed, undecodable or hung read keeps the last
// payload. Wire shape: the Kit mirror WatchtowerKit.SessionChat.
type SessionChatSource struct {
	w    handlers.ChatWatches
	d    *db.DB
	o    SessionChatOptions
	mu   sync.Mutex
	runs map[chatKey]*chatRun
	// generation is bumped when everything is dropped: a read that began
	// under another generation stores nothing.
	generation int
}

// chatKey is one watched feed.
type chatKey struct {
	session          int64
	agent, toolUseID string
}

// id is the record id: "<session>" or "<session>-<agent>".
func (k chatKey) id() string {
	if k.agent == "" {
		return strconv.FormatInt(k.session, 10)
	}
	return strconv.FormatInt(k.session, 10) + "-" + k.agent
}

type chatRun struct {
	last       time.Time
	payload    []byte
	storedLive bool
}

// SessionChat builds the session_chat source over the phone's watches.
func SessionChat(w handlers.ChatWatches, d *db.DB, o SessionChatOptions) *SessionChatSource {
	if o.Timing == (ChatTiming{}) {
		o.Timing = StandardChatTiming
	}
	if o.Liveness == nil {
		o.Liveness = func() Liveness { return Liveness{} }
	}
	if o.Active == nil {
		o.Active = func() bool { return true }
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	s := &SessionChatSource{w: w, d: d, o: o, runs: map[chatKey]*chatRun{}}
	if s.o.Fetch == nil {
		dirs := o.Dirs
		if dirs == (sessionfeed.Dirs{}) {
			dirs = defaultFeedDirs()
		}
		s.o.Fetch = func(ctx context.Context, id int64, toolUseID string) ([]sessionfeed.Entry, error) {
			return sessionfeed.ReadSession(ctx, d, id, toolUseID, dirs)
		}
	}
	return s
}

// defaultFeedDirs is the CLI's transcript dirs: ~/.claude/projects (never
// CLAUDE_CONFIG_DIR) and $CODEX_HOME when absolute, else ~/.codex.
func defaultFeedDirs() sessionfeed.Dirs {
	dirs := sessionfeed.Dirs{ClaudeProjects: filepath.Join(agentlog.DefaultClaudeDir(), "projects")}
	if dir := os.Getenv("CODEX_HOME"); filepath.IsAbs(dir) {
		dirs.CodexHome = dir
	} else if home, err := os.UserHomeDir(); err == nil {
		dirs.CodexHome = filepath.Join(home, ".codex")
	}
	return dirs
}

// Kind is "session_chat".
func (s *SessionChatSource) Kind() hubslices.Kind { return hubslices.KindSessionChat }

// Items is the watched feeds that have a payload. With no linked phone it
// drops every watch and payload and publishes nothing, so a phone that
// links later never sees an old chat.
func (s *SessionChatSource) Items(context.Context) ([]hubslices.Item, error) {
	if !s.o.Active() {
		s.dropAll()
		return nil, nil
	}
	active := s.activeKeys()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prune(active)
	var items []hubslices.Item
	for k, r := range s.runs {
		if r.payload != nil {
			// The publisher owns (and clears) what Items returns.
			items = append(items, hubslices.Item{ID: k.id(), Payload: bytes.Clone(r.payload)})
		}
	}
	slices.SortFunc(items, func(a, b hubslices.Item) int { return cmp.Compare(a.ID, b.ID) })
	return items, nil
}

// Run is the runner's loop until ctx ends; on return every watch and
// payload is dropped (nothing transcript-derived outlives the hub).
func (s *SessionChatSource) Run(ctx context.Context) error {
	defer s.dropAll()
	t := time.NewTicker(s.o.Timing.Wake)
	defer t.Stop()
	for {
		if s.o.Active() {
			s.RunDue(ctx)
		} else {
			s.dropAll()
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
		}
	}
}

// RunDue is one pass: the due watches, one after the other. A ctx that ends
// during the pass stops it before its next read and the read in flight
// stores nothing. It returns the record ids whose read was started.
func (s *SessionChatSource) RunDue(ctx context.Context) []string {
	gen, due := s.takeDue()
	var attempted []string
	for _, k := range due {
		if ctx.Err() != nil {
			break
		}
		attempted = append(attempted, k.id())
		s.run(ctx, k, gen)
	}
	return attempted
}

// activeKeys is the open watches.
func (s *SessionChatSource) activeKeys() map[chatKey]bool {
	out := map[chatKey]bool{}
	for _, w := range s.w.Active(s.o.Now()) {
		out[chatKey{session: w.SessionID, agent: w.AgentID, toolUseID: w.ToolUseID}] = true
	}
	return out
}

// prune drops the runs of watches no longer open; s.mu held.
func (s *SessionChatSource) prune(active map[chatKey]bool) {
	for k := range s.runs {
		if !active[k] {
			delete(s.runs, k)
		}
	}
}

// takeDue drops the runs of expired watches and stamps the due ones as
// attempted now, by session then agent id.
func (s *SessionChatSource) takeDue() (int, []chatKey) {
	active := s.activeKeys()
	live := s.o.Liveness().Runs
	now := s.o.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prune(active)
	var due []chatKey
	for k := range active {
		r, ok := s.runs[k]
		if !ok {
			r = &chatRun{}
			s.runs[k] = r
		}
		_, isLive := live[k.session]
		if !r.last.IsZero() && (now.Sub(r.last) < s.o.Timing.Every || !isLive && r.payload != nil && !r.storedLive) {
			continue
		}
		r.last = now
		due = append(due, k)
	}
	slices.SortFunc(due, func(a, b chatKey) int {
		return cmp.Or(cmp.Compare(a.session, b.session), cmp.Compare(a.agent, b.agent))
	})
	return s.generation, due
}

// run reads one feed and stores its payload, unless the watch expired, the
// source was dropped or ctx ended meanwhile.
func (s *SessionChatSource) run(ctx context.Context, k chatKey, gen int) {
	entries, err := bounded(ctx, s.o.Timing.Timeout, func(ctx context.Context) ([]sessionfeed.Entry, error) {
		return s.o.Fetch(ctx, k.session, k.toolUseID)
	})
	if ctx.Err() != nil {
		return
	}
	switch {
	case errors.Is(err, errRunTimedOut):
		log.Printf("hub slices: session chat of session %d timed out; keeping the last payload", k.session)
		return
	case err != nil:
		log.Printf("hub slices: session chat of session %d failed (%s); keeping the last payload", k.session, errClass(err))
		return
	}
	_, live := s.o.Liveness().Runs[k.session]
	payload, err := encodeChat(entries, k.session, k.agent, live)
	if err != nil {
		log.Printf("hub slices: encoding the session chat of session %d failed", k.session)
		return
	}
	active := s.activeKeys()
	s.mu.Lock()
	r, ok := s.runs[k]
	stored := ok && active[k] && s.generation == gen
	changed := stored && !bytes.Equal(r.payload, payload)
	if stored {
		r.payload, r.storedLive = payload, live
	}
	s.mu.Unlock()
	if changed && s.o.OnChange != nil {
		s.o.OnChange()
	}
}

// dropAll forgets every watch and payload (no phone linked, or the hub
// stopped).
func (s *SessionChatSource) dropAll() {
	s.w.DropAll()
	s.mu.Lock()
	clear(s.runs)
	s.generation++
	s.mu.Unlock()
}

type chatSubagent struct {
	AgentID     string `json:"agent_id"`
	ToolUseID   string `json:"tool_use_id"`
	Type        string `json:"type"`
	Description string `json:"description"`
	Status      string `json:"status"`
}

type chatEntry struct {
	ID          string        `json:"id"`
	Kind        string        `json:"kind"`
	At          *wire.Time    `json:"at,omitempty"`
	Text        string        `json:"text"`
	TextClipped *bool         `json:"text_clipped,omitempty"`
	AskID       *int64        `json:"ask_id,omitempty"`
	Title       *string       `json:"title,omitempty"`
	Via         *string       `json:"via,omitempty"`
	Subagent    *chatSubagent `json:"subagent,omitempty"`
}

type chatPayload struct {
	SessionID   int64       `json:"session_id"`
	AgentID     *string     `json:"agent_id,omitempty"`
	Live        bool        `json:"live"`
	EntriesMore int         `json:"entries_more"`
	Entries     []chatEntry `json:"entries"`
}

// encodeChat is SessionChatPayload.encode: the FEED-02 kinds only, cut to
// the newest MaxChatEntries (oldest first), texts clipped at MaxChatText and
// labels at 200, then trimmed from the oldest end until the encoded size
// fits MaxChatBytes; everything dropped but the other kinds is counted in
// entries_more. The payload carries no clock, so an unchanged feed encodes
// to the same bytes.
func encodeChat(feed []sessionfeed.Entry, sessionID int64, agentID string, live bool) ([]byte, error) {
	known := make([]sessionfeed.Entry, 0, len(feed))
	for _, e := range feed {
		if slices.Contains(phoneFeedKinds, e.Kind) {
			known = append(known, e)
		}
	}
	more := max(len(known)-MaxChatEntries, 0)
	tail := known[more:]
	entries := make([]chatEntry, len(tail))
	sizes := make([]int, len(tail))
	for i, e := range tail {
		entries[i] = chatEntryOf(e)
		b, err := wire.Marshal(entries[i])
		if err != nil {
			return nil, err
		}
		sizes[i] = len(b)
	}
	var agent *string
	if agentID != "" {
		agent = &agentID
	}
	envelope, err := wire.Marshal(chatPayload{SessionID: sessionID, AgentID: agent, Live: live, EntriesMore: len(known), Entries: []chatEntry{}})
	if err != nil {
		return nil, err
	}
	// The envelope is measured with the largest entries_more it can carry.
	kept := len(entries)
	total := len(envelope) + max(0, kept-1)
	for _, n := range sizes {
		total += n
	}
	dropped := 0
	for total > MaxChatBytes && kept > 0 {
		total -= sizes[dropped]
		if kept > 1 {
			total-- // its comma
		}
		dropped++
		kept--
	}
	return wire.Marshal(chatPayload{
		SessionID: sessionID, AgentID: agent, Live: live,
		EntriesMore: more + dropped, Entries: entries[dropped:],
	})
}

func chatEntryOf(e sessionfeed.Entry) chatEntry {
	text, clipped := clipText(e.Text, MaxChatText)
	out := chatEntry{ID: e.ID, Kind: string(e.Kind), Text: text, TextClipped: clipped}
	if !e.At.IsZero() {
		out.At = &wire.Time{Time: e.At}
	}
	if e.AskID != 0 {
		out.AskID = int64Ptr(e.AskID)
	}
	if e.Title != "" {
		title, _ := clipText(e.Title, maxChatLabel)
		out.Title = &title
	}
	if e.Via != "" {
		via := e.Via
		out.Via = &via
	}
	if sub := e.Subagent; sub != nil {
		desc, _ := clipText(sub.Description, maxChatLabel)
		out.Subagent = &chatSubagent{
			AgentID: sub.AgentID, ToolUseID: sub.ToolUseID, Type: sub.Type, Description: desc, Status: sub.Status,
		}
	}
	return out
}
