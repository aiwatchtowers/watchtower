package sources

import (
	"bytes"
	"cmp"
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"sync"
	"time"
	"unicode/utf8"

	"watchtower/internal/agentlog"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions/handlers"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
	"watchtower/internal/secretredact"
	"watchtower/internal/sessionagent"
	"watchtower/internal/sessionfeed"
)

// The session_chat payload's caps (SessionChatPayload, FEED-05).
const (
	MaxChatEntries = 300
	MaxChatText    = 4000
	MaxChatBytes   = 600_000
	maxChatLabel   = 200
	// maxLiveSummary cuts every summary and agent description of the live
	// block, after redaction (FEED-05).
	maxLiveSummary = 200
	// maxLiveSteps and maxLiveAgents cap the live block's lists (what
	// sessionfeed.LiveOf keeps); the cut is counted in steps_more and
	// agents_more.
	maxLiveSteps  = 40
	maxLiveAgents = 32
	// maxLiveName cuts a tool name, agent type, status or agents_state;
	// maxLiveID an id or the conversation.
	maxLiveName = 64
	maxLiveID   = 128
	// chatLiveVersion is live_version: every payload of a hub that sends the
	// live block carries it, so a phone tells "no block" from "old hub".
	chatLiveVersion = 1
)

// live_error's lines (one line, never the raw error: it could carry a path).
const (
	liveErrUnavailable = "Activity unavailable"
	liveErrTimedOut    = "Activity read timed out"
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
	// Every is the run of a live session whose files cannot be watched
	// (the fallback tick).
	Every time.Duration
	// Timeout bounds one feed read.
	Timeout time.Duration
	// Wake is how often the loop looks for due watches and re-resolves a
	// live session's conversations.
	Wake time.Duration
	// Debounce is how long after a file event a read waits for the next
	// one; MinGap is the least time between two reads of one chat, so a
	// burst of events reads about once per MinGap.
	Debounce, MinGap time.Duration
}

// StandardChatTiming is SessionChatRunner.Timing.standard.
var StandardChatTiming = ChatTiming{
	Every: 3 * time.Second, Timeout: 30 * time.Second, Wake: 2 * time.Second,
	Debounce: 250 * time.Millisecond, MinGap: time.Second,
}

// ChatRead is one read of a chat: the feed's entries, the live snapshot of
// the conversation read (the subagent's sidechain for an agent record; nil
// with LiveErr set when only that read failed) and the files and
// directories read.
type ChatRead = sessionagent.SessionRead

// ChatFetch reads a session's whole feed (toolUseID "") or one subagent's.
type ChatFetch func(ctx context.Context, sessionID int64, toolUseID string) (ChatRead, error)

// SessionChatOptions wires the session_chat source. Timing zero is
// StandardChatTiming; Fetch nil reads the feed in-process with
// sessionagent.ReadSession (what `workbench session-feed --live --json`
// prints)
// under Dirs (zero = ~/.claude/projects and the Codex home); Liveness nil is
// nothing live; Active nil is always (the hub's linked-phone gate); OnChange
// (nil = none) is called after a run stored a payload that differs from the
// previous one — the hub nudges the publisher's fast lane with it; Now nil
// is time.Now and must be the clock the session_chat_request handler stamps
// the watches with. Conversations and AgentSessions nil resolve a
// session's transcripts and list its agent-session ids in-process under
// Dirs (none without a database); NewWatcher nil is fsnotify.
type SessionChatOptions struct {
	Timing        ChatTiming
	Fetch         ChatFetch
	Conversations ChatConversations
	AgentSessions ChatAgentSessions
	NewWatcher    func() (FileWatcher, error)
	Dirs          sessionfeed.Dirs
	Liveness      func() Liveness
	Active        func() bool
	OnChange      func()
	Now           func() time.Time
}

// SessionChatSource is the `session_chat` slice (FEED-05), record
// `session_chat-<session id>` or, for a subagent's feed,
// `session_chat-<session id>-<agent id>`: the capped chat of a workbench
// session the phone watches (handlers.ChatWatches, opened by
// session_chat_request for 5 minutes), and while the session is live its
// live block (activity_live: one-line tool summaries, secrets redacted, see
// phoneLive). Per watch it reads the feed once
// when the watch opens (and again on a repeated request at least MinGap
// later), once when the session's liveness changes, and on file events: an
// fsnotify watch on files only (the conversation transcripts and the
// running subagents' transcripts, chat_files.go) marks the chat dirty, read
// Debounce after the last event and at most once per MinGap. The Wake loop
// re-resolves a live session's conversations (a database query and a stat)
// and reads once when they changed (a new conversation, a file that
// appeared). A chat whose files cannot be watched reads every Every while
// live instead.
//
// The payloads live in this source's memory only: never in watchtower.db
// (FEED-01) nor the hub sidecar, sealed only when the publisher pushes them.
// A watch that expires loses its payload (the publisher deletes the record);
// with no linked phone every watch and payload is dropped for good, and so
// when Run returns. A failed, undecodable or hung read keeps the last
// payload; when that payload has a live block, it gains live_error so the
// block never looks current. A read whose live part alone failed updates
// the entries and keeps the last block with live_error. Wire shape: the Kit
// mirror WatchtowerKit.SessionChat.
type SessionChatSource struct {
	w    handlers.ChatWatches
	d    *db.DB
	o    SessionChatOptions
	mu   sync.Mutex
	runs map[chatKey]*chatRun
	// generation is bumped when everything is dropped: a read that began
	// under another generation stores nothing.
	generation int
	// wake ends the loop's wait for its next tick (a phone request).
	wake chan struct{}
	// fw is the one file watcher of every chat (nil while none holds a
	// file); byPath is which chats hold each watched file, so a file two
	// records watch is opened once and one write marks both.
	// wmu serialises the watcher's I/O with its ownership changes (taken
	// before mu); unwatch is the files that lost their last holder, for
	// syncWatcher to remove unless held again.
	fw      FileWatcher
	byPath  map[string]map[chatKey]bool
	wmu     sync.Mutex
	unwatch map[string]bool
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
	// doc is payload before encoding: a failed read re-encodes it with
	// live_error.
	doc *chatPayload
	// openID is the newest open_id the phone's requests carried; its reads
	// echo it.
	openID string
	chatFiles
}

// SessionChat builds the session_chat source over the phone's watches.
func SessionChat(w handlers.ChatWatches, d *db.DB, o SessionChatOptions) *SessionChatSource {
	if o.Timing == (ChatTiming{}) {
		o.Timing = StandardChatTiming
	}
	if o.Timing.Debounce == 0 {
		o.Timing.Debounce = StandardChatTiming.Debounce
	}
	if o.Timing.MinGap == 0 {
		o.Timing.MinGap = StandardChatTiming.MinGap
	}
	if o.NewWatcher == nil {
		o.NewWatcher = newFSWatcher
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
	s := &SessionChatSource{w: w, d: d, o: o, runs: map[chatKey]*chatRun{}, byPath: map[string]map[chatKey]bool{}, unwatch: map[string]bool{}, wake: make(chan struct{}, 1)}
	dirs := o.Dirs
	if dirs == (sessionfeed.Dirs{}) && (s.o.Fetch == nil || s.o.Conversations == nil) {
		dirs = defaultFeedDirs()
	}
	if s.o.Conversations == nil {
		s.o.Conversations = sessionConversations(d, dirs)
	}
	if s.o.AgentSessions == nil {
		s.o.AgentSessions = sessionAgentSessions(d)
	}
	if s.o.Fetch == nil {
		s.o.Fetch = func(ctx context.Context, id int64, toolUseID string) (ChatRead, error) {
			return sessionagent.ReadSession(ctx, d, id, toolUseID, dirs, s.o.Now())
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
	done := func() {}
	defer func() { done() }() // after the unlock below
	s.mu.Lock()
	defer s.mu.Unlock()
	done = s.prune(active)
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
		// A dirty chat's read or a fallback chat's tick may be due before
		// the next Wake.
		var debounce <-chan time.Time
		var timer *time.Timer
		if at, ok := s.nextDue(); ok {
			timer = time.NewTimer(max(at.Sub(s.o.Now()), 0))
			debounce = timer.C
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
		case <-s.wake:
		case <-debounce:
		}
		if timer != nil {
			timer.Stop()
		}
	}
}

// RequestWatches is the watches the session_chat_request handler opens:
// each Watch also wakes the loop, so the pass that reads a new watch starts
// at once instead of on the next tick (runners on request). On a watch
// already open it asks for a read only when nothing is stored or the last
// live read failed (the phone's Retry), MinGap after the last read at the
// soonest; otherwise it only extends the watch. A pass in flight finishes
// first and one more follows; a burst of requests costs at most that one
// pass and one read.
func (s *SessionChatSource) RequestWatches() handlers.ChatWatches {
	return wakingWatches{ChatWatches: s.w, s: s}
}

type wakingWatches struct {
	handlers.ChatWatches
	s *SessionChatSource
}

func (w wakingWatches) Watch(cw handlers.ChatWatch) {
	w.ChatWatches.Watch(cw)
	k := chatKey{session: cw.SessionID, agent: cw.AgentID, toolUseID: cw.ToolUseID}
	w.s.mu.Lock()
	// The phone repeats the request every 60 s to keep the watch: only a
	// chat with nothing stored or a failed live read (the Retry) reads, or a
	// new open of the chat screen (a new open_id), whose read echoes it. A
	// new open after a restart or an expiry starts the run that echoes it.
	r, ok := w.s.runs[k]
	if !ok && cw.OpenID != "" {
		r, ok = &chatRun{}, true
		w.s.runs[k] = r
	}
	if ok && cw.OpenID != "" && cw.OpenID != r.openID {
		r.openID, r.requested = cw.OpenID, true
	}
	if ok && (r.payload == nil || r.doc != nil && r.doc.LiveError != "") {
		r.requested = true
	}
	w.s.mu.Unlock()
	notify(w.s.wake)
}

// RunDue is one pass: the due watches, one after the other. A ctx that ends
// during the pass stops it before its next read and the read in flight
// stores nothing. It returns the record ids whose read was started.
func (s *SessionChatSource) RunDue(ctx context.Context) []string {
	gen := s.currentGeneration()
	live := s.o.Liveness().Runs
	s.checkConversations(ctx, gen, s.activeKeys(), live)
	due := s.takeDue(gen, s.activeKeys(), live)
	var attempted []string
	for _, k := range due {
		if ctx.Err() != nil || !s.isCurrent(gen) {
			break
		}
		// An earlier read may have been slow: the watch may have expired
		// meanwhile, and MinGap counts from this read's own start.
		if !s.begin(k, gen) {
			continue
		}
		attempted = append(attempted, k.id())
		s.run(ctx, k, gen)
	}
	return attempted
}

func (s *SessionChatSource) currentGeneration() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.generation
}

// begin stamps k's read as started now, unless its watch closed or the
// source was dropped since the pass of generation gen began.
func (s *SessionChatSource) begin(k chatKey, gen int) bool {
	active := s.activeKeys()
	now := s.o.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.runs[k]
	if !ok || !active[k] || s.generation != gen {
		return false
	}
	r.last = now
	r.dirty, r.convsChanged, r.reconcile, r.requested = false, false, false, false
	return true
}

// isCurrent: nothing was dropped since the pass of generation gen began.
func (s *SessionChatSource) isCurrent(gen int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.generation == gen
}

// activeKeys is the open watches.
func (s *SessionChatSource) activeKeys() map[chatKey]bool {
	out := map[chatKey]bool{}
	for _, w := range s.w.Active(s.o.Now()) {
		out[chatKey{session: w.SessionID, agent: w.AgentID, toolUseID: w.ToolUseID}] = true
	}
	return out
}

// prune drops the runs of watches no longer open, letting go of their
// files; s.mu held. The returned func does the watcher's I/O and must be
// called after unlocking.
func (s *SessionChatSource) prune(active map[chatKey]bool) func() {
	pruned := false
	for k, r := range s.runs {
		if !active[k] {
			s.releaseAll(k, r)
			delete(s.runs, k)
			pruned = true
		}
	}
	if !pruned {
		return func() {}
	}
	return s.lockedSync
}

// takeDue drops the runs of expired watches and lists the due ones, by
// session then agent id (begin stamps each as its read starts). A pass
// whose generation was dropped meanwhile lists none and creates no run.
func (s *SessionChatSource) takeDue(gen int, active map[chatKey]bool, live map[int64]time.Time) []chatKey {
	now := s.o.Now()
	done := func() {}
	defer func() { done() }() // after the unlock below
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.generation != gen {
		return nil
	}
	done = s.prune(active)
	var due []chatKey
	for k := range active {
		r, ok := s.runs[k]
		if !ok {
			r = &chatRun{}
			s.runs[k] = r
		}
		_, isLive := live[k.session]
		r.live = isLive
		if s.isDue(k, r, isLive, now) {
			due = append(due, k)
		}
	}
	slices.SortFunc(due, func(a, b chatKey) int {
		return cmp.Or(cmp.Compare(a.session, b.session), cmp.Compare(a.agent, b.agent))
	})
	return due
}

// isDue says whether r reads now: its first read; then never within MinGap
// of the last (a waiting read stays waiting), and only for a waiting read
// (a changed conversation list, a reconcile, a Retry request), a liveness
// change, the Every tick of a chat that ticks or a dirty chat's debounce;
// s.mu held.
func (s *SessionChatSource) isDue(k chatKey, r *chatRun, isLive bool, now time.Time) bool {
	t := s.o.Timing
	switch {
	case r.last.IsZero():
		return true
	case now.Sub(r.last) < t.MinGap:
		return false
	case r.requested || r.convsChanged || r.reconcile || r.payload != nil && isLive != r.storedLive:
		return true
	}
	tick := r.ticks(k, isLive) && (isLive || r.payload == nil || !r.fetched)
	return tick && now.Sub(r.last) >= t.Every || r.dirty && !now.Before(r.dirtyDue(t))
}

// run reads one feed and stores its payload, unless the watch expired, the
// source was dropped or ctx ended meanwhile.
func (s *SessionChatSource) run(ctx context.Context, k chatKey, gen int) {
	// The known files are watched before the read, so a write during it
	// marks the chat dirty.
	s.arm(k, gen)
	read, err := bounded(ctx, s.o.Timing.Timeout, func(ctx context.Context) (ChatRead, error) {
		return s.o.Fetch(ctx, k.session, k.toolUseID)
	})
	if ctx.Err() != nil {
		return
	}
	s.withRun(k, gen, func(r *chatRun) {
		r.failed = err != nil
		r.fetched = r.fetched || err == nil
	})
	if err == nil {
		defer s.settle(k, gen, &read)
	} else {
		defer s.settle(k, gen, nil)
	}
	s.mu.Lock()
	var prev *chatPayload
	var openID string
	if r, ok := s.runs[k]; ok {
		prev, openID = r.doc, r.openID
	}
	s.mu.Unlock()
	var doc *chatPayload
	var live bool
	switch {
	case err != nil:
		reason, lineErr := "failed ("+errClass(err)+")", liveErrUnavailable
		if errors.Is(err, errRunTimedOut) {
			reason, lineErr = "timed out", liveErrTimedOut
		}
		log.Printf("hub slices: session chat of session %d %s; keeping the last payload", k.session, reason)
		_, live = s.o.Liveness().Runs[k.session]
		if prev == nil {
			if !live {
				return
			}
			// Nothing stored yet for a live session: say the read failed,
			// so the phone shows Unavailable + Retry, never Loading forever.
			if doc, err = chatDoc(nil, k.session, k.agent, true, nil, lineErr, openID); err != nil {
				return
			}
			break
		}
		marked := *prev
		marked.OpenID = openID
		switch {
		case !live:
			// The session stopped: its last block is no longer current, and
			// no live error either — the dialog stays, the liveness is real.
			marked.Live, marked.ActivityLive, marked.LiveError = false, nil, ""
		case prev.ActivityLive == nil && prev.LiveError == "" && prev.OpenID == openID:
			return
		default:
			marked.LiveError = lineErr
		}
		doc = &marked
	default:
		_, live = s.o.Liveness().Runs[k.session]
		block, lineErr := phoneLive(read.Live), ""
		if read.LiveErr != nil {
			log.Printf("hub slices: the live block of session %d failed (%s); keeping the last one", k.session, errClass(read.LiveErr))
			block, lineErr = nil, liveErrUnavailable
			if prev != nil {
				block = prev.ActivityLive
			}
		}
		if doc, err = chatDoc(read.Entries, k.session, k.agent, live, block, lineErr, openID); err != nil {
			log.Printf("hub slices: encoding the session chat of session %d failed", k.session)
			return
		}
		// observed_at alone changing is no change: the block keeps the
		// moment of the read that last changed it.
		if prev != nil && sameLiveBlock(doc.ActivityLive, prev.ActivityLive) {
			doc.ActivityLive = prev.ActivityLive
		}
	}
	payload, err := wire.Marshal(doc)
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
		r.payload, r.storedLive, r.doc = payload, live, doc
	}
	s.mu.Unlock()
	if changed && s.o.OnChange != nil {
		s.o.OnChange()
	}
}

// sameLiveBlock: a and b are both set and differ in observed_at at most.
func sameLiveBlock(a, b *sessionfeed.Live) bool {
	if a == nil || b == nil {
		return false
	}
	c := *a
	c.ObservedAt = b.ObservedAt
	return reflect.DeepEqual(&c, b)
}

// dropAll forgets every watch and payload (no phone linked, or the hub
// stopped).
func (s *SessionChatSource) dropAll() {
	s.w.DropAll()
	s.wmu.Lock()
	defer s.wmu.Unlock()
	s.mu.Lock()
	w := s.fw
	s.fw = nil
	clear(s.byPath)
	clear(s.unwatch)
	clear(s.runs)
	s.generation++
	s.mu.Unlock()
	if w != nil {
		_ = w.Close()
	}
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
	// ActivityLive is the live block (phoneLive), only while the session is
	// live; LiveError says its last read failed or hung (the block, when
	// present, is the last good one).
	ActivityLive *sessionfeed.Live `json:"activity_live,omitempty"`
	LiveVersion  int               `json:"live_version"`
	LiveError    string            `json:"live_error,omitempty"`
	// OpenID echoes the newest open_id the phone's session_chat_request
	// carried (each opening of the chat screen sends a new one): the phone
	// shows Loading until a record echoing its open arrives.
	OpenID string `json:"open_id,omitempty"`
}

// encodeChat is SessionChatPayload.encode: the FEED-02 kinds only, cut to
// the newest MaxChatEntries (oldest first), texts clipped at MaxChatText and
// labels at 200, then trimmed from the oldest end until the encoded size
// fits MaxChatBytes; everything dropped but the other kinds is counted in
// entries_more. The live block (block, already phoneLive'd) and live_error
// (liveErr) are reserved first and never cut: they travel only while the
// session is live. The payload carries no clock but the block's
// observed_at, so an unchanged feed encodes to the same bytes.
func encodeChat(feed []sessionfeed.Entry, sessionID int64, agentID string, live bool, block *sessionfeed.Live, liveErr, openID string) ([]byte, error) {
	doc, err := chatDoc(feed, sessionID, agentID, live, block, liveErr, openID)
	if err != nil {
		return nil, err
	}
	return wire.Marshal(doc)
}

// chatDoc is encodeChat before encoding.
func chatDoc(feed []sessionfeed.Entry, sessionID int64, agentID string, live bool, block *sessionfeed.Live, liveErr, openID string) (*chatPayload, error) {
	if !live {
		block, liveErr = nil, ""
	}
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
	// The envelope is measured with the largest entries_more it can carry
	// and the longest live_error a later failed read may set, the live block
	// included whole.
	envelope, err := wire.Marshal(chatPayload{
		SessionID: sessionID, AgentID: agent, Live: live, EntriesMore: len(known), Entries: []chatEntry{},
		ActivityLive: block, LiveVersion: chatLiveVersion, LiveError: liveErrTimedOut, OpenID: openID,
	})
	if err != nil {
		return nil, err
	}
	if len(envelope) > MaxChatBytes && block != nil {
		// phoneLive's bounds keep a block far below this; one that still
		// does not fit is dropped and said so, never cut.
		block, liveErr = nil, liveErrUnavailable
		if envelope, err = wire.Marshal(chatPayload{
			SessionID: sessionID, AgentID: agent, Live: live, EntriesMore: len(known), Entries: []chatEntry{},
			LiveVersion: chatLiveVersion, LiveError: liveErrTimedOut, OpenID: openID,
		}); err != nil {
			return nil, err
		}
	}
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
	return &chatPayload{
		SessionID: sessionID, AgentID: agent, Live: live,
		EntriesMore: more + dropped, Entries: entries[dropped:],
		ActivityLive: block, LiveVersion: chatLiveVersion, LiveError: liveErr, OpenID: openID,
	}, nil
}

// phoneLive is the live block the phone gets from a snapshot: every summary
// (steps, current, latest, each agent's action) and every agent description
// redacted then cut at maxLiveSummary (sessionfeed already redacted them
// before its own cut; this is the second layer), names cut at maxLiveName
// and ids at maxLiveID, at most maxLiveSteps steps and maxLiveAgents
// agents. Steps are cut from the oldest finished ones first, then the
// oldest running ones, never the current step, all counted in steps_more;
// agents past the cap in agents_more. It never mutates l; nil stays nil.
func phoneLive(l *sessionfeed.Live) *sessionfeed.Live {
	if l == nil {
		return nil
	}
	out := &sessionfeed.Live{
		ObservedAt: l.ObservedAt, Conversation: cutRunes(l.Conversation, maxLiveID), TurnAt: l.TurnAt, TurnActive: l.TurnActive,
		Current: phoneAction(l.Current), Latest: phoneAction(l.Latest),
		Agents: []sessionfeed.LiveAgent{}, AgentsState: cutRunes(l.AgentsState, maxLiveName), AgentsMore: l.AgentsMore,
		Steps: []sessionfeed.LiveAction{}, StepsMore: l.StepsMore,
	}
	// Past maxLiveSteps the oldest finished steps go first, then the oldest
	// running ones; the current step always stays.
	keep := make([]bool, len(l.Steps))
	for i := range keep {
		keep[i] = true
	}
	excess := len(l.Steps) - maxLiveSteps
	for pass := 0; pass < 2 && excess > 0; pass++ {
		for i, st := range l.Steps {
			if excess == 0 {
				break
			}
			finished := !st.CompletedAt.IsZero()
			if !keep[i] || (pass == 0) != finished || l.Current != nil && st.ID == l.Current.ID {
				continue
			}
			keep[i] = false
			excess--
			out.StepsMore++
		}
	}
	for i, st := range l.Steps {
		if keep[i] {
			out.Steps = append(out.Steps, *phoneAction(&st))
		}
	}
	agents := l.Agents
	if n := len(agents) - maxLiveAgents; n > 0 {
		agents, out.AgentsMore = agents[:maxLiveAgents], out.AgentsMore+n
	}
	for _, a := range agents {
		ref := sessionfeed.SubagentRef{
			ToolUseID: cutRunes(a.Ref.ToolUseID, maxLiveID), AgentID: cutRunes(a.Ref.AgentID, maxLiveID),
			Type: cutRunes(a.Ref.Type, maxLiveName), Status: cutRunes(a.Ref.Status, maxLiveName),
			Description: secretredact.TextBounded(a.Ref.Description, maxLiveSummary),
		}
		out.Agents = append(out.Agents, sessionfeed.LiveAgent{Ref: ref, StartedAt: a.StartedAt, Action: phoneAction(a.Action), CanOpen: a.CanOpen})
	}
	return out
}

// phoneAction is a copy of a with its summary redacted and cut.
func phoneAction(a *sessionfeed.LiveAction) *sessionfeed.LiveAction {
	if a == nil {
		return nil
	}
	c := *a
	c.ID, c.Tool = cutRunes(c.ID, maxLiveID), cutRunes(c.Tool, maxLiveName)
	c.Summary = secretredact.TextBounded(c.Summary, maxLiveSummary)
	return &c
}

// cutRunes keeps at most n runes of s.
func cutRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
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
