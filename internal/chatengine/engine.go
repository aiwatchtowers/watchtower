// Package chatengine is the main chat's engine: the only writer of the main
// chat's turns (unified chat spec §4). It runs the `ai session` pool
// (CHAT-03), starts every turn through the Go turn store
// (internal/chatstore: the owner row before the turn, CHAT-01), holds each
// running turn's live text and steps, fans changes out to subscribers
// (snapshot, then coalesced upserts), and answers the chat operations. It
// imports nothing of the hub; the hub and, later, the Mac's socket are its
// clients.
//
// Logs carry ids, counts and error classes only (FILES-01).
package chatengine

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"watchtower/internal/chatstore"
	"watchtower/internal/db"
)

// MaxLive is the most `ai session` processes the engine runs at once
// (CHAT-03); a retiring process still counts until it exited.
const MaxLive = 3

// IdleTTL is how long an idle session stays warm.
const IdleTTL = 10 * time.Minute

// The subscription coalescing windows (spec §5.4).
const (
	FeedCoalesce = 150 * time.Millisecond
	ListCoalesce = 500 * time.Millisecond
)

// PageSize is the messages of one feed page.
const PageSize = 60

// LeaseOwnerID is the owner id of the engine's chat_turn_leases rows (owner
// `hub`). The engine keeps claiming the lease for one release, so an older
// app running against a new daemon sees its turns (spec §9.3).
const LeaseOwnerID = "chatengine"

// titleBudget bounds one AI title (the light-tier call).
const titleBudget = 2 * time.Minute

// ErrClosed is the answer of a closing engine (the daemon stops).
var ErrClosed = errors.New("chatengine: engine closed")

// Config is what an Engine runs with.
type Config struct {
	// Exe is the watchtower binary; DBPath the database file the sessions
	// open (--db-path); Dir the engine's folder (<workspace>/chatengine): the
	// sessions' process-group files live in <Dir>/sessions ("" = none).
	Exe, DBPath, Dir string
	// DB is the database the engine writes; Read the one it reads feeds,
	// lists and searches from (nil = DB).
	DB, Read *db.DB
	Clock    func() time.Time
	// Start spawns one session child (nil = Exe in its own process group).
	Start StartFunc
	// Title writes a conversation's AI title after its first complete
	// answer (nil = none); it runs on its own goroutine, cancelled at Close.
	Title func(ctx context.Context, conv int64) error
	// PreferredProvider is the provider an automatic conversation's reply
	// records when no session reported one.
	PreferredProvider string
	// FilesDir is <workspace>/chat_files: a deleted conversation's folder
	// is removed after the delete ("" = left).
	FilesDir string
	// SkillsDir is <workspace>/skills, the `/` picker's catalog ("" = none).
	SkillsDir string
	// procArgs reads a process's command line (nil = ps); a test seam.
	procArgs func(pid int) (string, error)
}

// Engine is the main chat's engine.
type Engine struct {
	c     Config
	store *chatstore.Store

	onChange  atomic.Pointer[func(conv int64)]
	onTurnEnd atomic.Pointer[func(conv int64, turnID, status string)]

	mu       sync.Mutex
	sessions []*session // every session not yet ended, in creation order
	// turns is the per-conversation lock of a starting turn: an entry lives
	// from a Turn's client-key lookup until its start committed and the turn
	// was handed to a session (a running turn is then guarded by its lease).
	turns  map[int64]*turnState
	closed bool
	wg     sync.WaitGroup

	titlesCtx    context.Context
	titlesCancel context.CancelFunc
	titles       sync.WaitGroup

	subMu sync.Mutex
	subs  map[*Subscription]struct{}

	opsMu sync.RWMutex
	ops   map[string]OpHandler

	// failReads, set by tests only, fails a subscription's reads while it
	// returns an error.
	failReads atomic.Pointer[func() error]

	// beforeStart runs between the client-key lookup and the start
	// transaction (tests: a concurrent duplicate).
	beforeStart func()
}

// turnState is a Turn being started: a second Turn with the same client key
// waits for it and answers with its result; any other is busy.
type turnState struct {
	clientKey string
	done      chan struct{}
	st        chatstore.Started
	err       error
}

// New returns an engine; Start runs its sweep.
func New(c Config) *Engine {
	if c.Clock == nil {
		c.Clock = time.Now
	}
	if c.Start == nil {
		c.Start = execStart(c.Exe)
	}
	if c.procArgs == nil {
		c.procArgs = psArgs
	}
	if c.Read == nil {
		c.Read = c.DB
	}
	e := &Engine{c: c, turns: map[int64]*turnState{}, subs: map[*Subscription]struct{}{}, ops: map[string]OpHandler{}}
	e.titlesCtx, e.titlesCancel = context.WithCancel(context.Background())
	opts := []chatstore.Option{chatstore.WithClock(c.Clock), chatstore.WithPreferredProvider(c.PreferredProvider)}
	if c.Title != nil {
		opts = append(opts, chatstore.WithTitleHook(e.title))
	}
	e.store = chatstore.New(c.DB, db.ChatLeaseHub, LeaseOwnerID, opts...)
	e.registerOps()
	return e
}

// Start runs the startup sweep (the groups and leases a killed daemon left)
// before the first turn can claim a lease.
func (e *Engine) Start(_ context.Context) error {
	return e.sweep()
}

// OnChange sets the hook called when a conversation's live state changed (a
// turn queued, started, streamed or ended, or an operation wrote it). Set
// once, before Start; it runs on an engine goroutine and must not block.
func (e *Engine) OnChange(fn func(conv int64)) { e.onChange.Store(&fn) }

// OnTurnEnd sets the hook called when a turn was finalized, with its stored
// status. Set once, before Start; it must not block.
func (e *Engine) OnTurnEnd(fn func(conv int64, turnID, status string)) { e.onTurnEnd.Store(&fn) }

// TurnRequest is one turn to start.
type TurnRequest struct {
	chatstore.StartRequest
	// ClientKey ("" = none) is stored in chat_messages.client_key: a repeated
	// key is answered with the turn it started, never applied twice.
	ClientKey string
	// ScreenContext ("" = none, at most MaxScreenContextBytes) is the
	// client-rendered current-screen block (Swift ScreenContext.block): put
	// before the provider text only, never stored.
	ScreenContext string
}

// Turn starts a turn (chatstore.Store.Start under the engine's lease) and
// hands it to the conversation's session, a warm one when it fits, else a
// new one that launches when a slot is free. It returns once the start
// transaction committed; the turn then runs on the session's goroutine. A
// refused turn (busy, invalid, conversation gone) writes nothing.
func (e *Engine) Turn(ctx context.Context, r TurnRequest) (chatstore.Started, error) {
	req := r.StartRequest
	req.ClientKey = r.ClientKey
	if len(r.ScreenContext) > MaxScreenContextBytes {
		return chatstore.Started{}, chatstore.ErrInvalid
	}
	req.ProviderPrefix = r.ScreenContext
	conv := req.ConversationID
	ts := &turnState{clientKey: req.ClientKey, done: make(chan struct{})}
	for {
		e.mu.Lock()
		if e.closed {
			e.mu.Unlock()
			return chatstore.Started{}, ErrClosed
		}
		other := e.turns[conv]
		if other == nil {
			e.turns[conv] = ts
			e.mu.Unlock()
			break
		}
		e.mu.Unlock()
		if req.ClientKey == "" || other.clientKey != req.ClientKey {
			return chatstore.Started{}, chatstore.ErrBusy
		}
		select { // the same request in flight: its answer is this one's
		case <-other.done:
		case <-ctx.Done():
			return chatstore.Started{}, ctx.Err()
		}
		if other.err == nil {
			return other.st, nil
		}
	}
	defer func() {
		e.mu.Lock()
		delete(e.turns, conv)
		e.mu.Unlock()
		close(ts.done)
	}()
	ts.st, ts.err = e.startTurn(ctx, req)
	return ts.st, ts.err
}

// startTurn is Turn under the conversation's lock.
func (e *Engine) startTurn(ctx context.Context, req chatstore.StartRequest) (chatstore.Started, error) {
	if req.ClientKey != "" {
		if st, ok, err := e.clientKeyEcho(ctx, req.ConversationID, req.ClientKey); err != nil || ok {
			return st, err
		}
	}
	if e.beforeStart != nil {
		e.beforeStart()
	}
	e.mu.Lock()
	prev := e.usable(req.ConversationID)
	var leaf *int64
	if prev != nil && prev.turn == nil && prev.leaf != nil {
		l := *prev.leaf
		leaf = &l
	}
	e.mu.Unlock()

	req.ContinuousLeafID = leaf
	st, err := e.store.Start(ctx, req)
	if errors.Is(err, chatstore.ErrDuplicateClientKey) {
		// Another writer applied the key between the lookup and the insert.
		st, ok, err := e.clientKeyEcho(ctx, req.ConversationID, req.ClientKey)
		if err == nil && !ok {
			err = chatstore.ErrBusy
		}
		return st, err
	}
	if err != nil {
		return st, err
	}
	turn := e.store.Turn(st)
	cfg := configOf(st)

	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		// The daemon stops: the turn never runs.
		e.finalizeUnsent(st, turn, chatstore.StatusPartial, lostFailure())
		return st, nil
	}
	s := e.usable(req.ConversationID)
	if s != nil && (s.turn != nil || !s.cfg.compatible(cfg)) {
		// A routing or project change recycles the session (Swift
		// ChatSessionConfig.isCompatible); it is idle, the lease says so.
		s.retire = true
		s.poke()
		s = nil
	}
	if leaf != nil && s != prev {
		// The leaf was the old process's: a new one has seen nothing.
		st.Replay = true
	}
	if s == nil {
		s = e.newSession(req.ConversationID, cfg)
	}
	now := e.c.Clock()
	s.turn = &heldTurn{st: st, t: turn, at: now}
	s.lastActivity = now
	s.poke()
	e.admit()
	e.mu.Unlock()
	e.changed(req.ConversationID)
	return st, nil
}

// clientKeyEcho is the turn a client key already started in conv: the row
// carrying the key (the owner row, or a regenerate's reply) and its pair.
// ok is false when no row has the key.
func (e *Engine) clientKeyEcho(ctx context.Context, conv int64, key string) (chatstore.Started, bool, error) {
	var (
		id     int64
		parent sql.NullInt64
		role   string
		turnID string
	)
	err := e.c.DB.QueryRowContext(ctx, `SELECT id, parent_id, role, turn_id FROM chat_messages
		WHERE conversation_id = ? AND client_key = ?`, conv, key).Scan(&id, &parent, &role, &turnID)
	if errors.Is(err, sql.ErrNoRows) {
		return chatstore.Started{}, false, nil
	}
	if err != nil {
		return chatstore.Started{}, false, fmt.Errorf("chatengine: reading a client key: %w", err)
	}
	st := chatstore.Started{ConversationID: conv, TurnID: turnID}
	if role == "assistant" {
		st.AssistantMessageID, st.UserMessageID = id, parent.Int64
		return st, true, nil
	}
	st.UserMessageID = id
	err = e.c.DB.QueryRowContext(ctx, `SELECT id FROM chat_messages
		WHERE conversation_id = ? AND parent_id = ? AND role = 'assistant' AND turn_id = ? ORDER BY id LIMIT 1`,
		conv, id, turnID).Scan(&st.AssistantMessageID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return chatstore.Started{}, false, fmt.Errorf("chatengine: reading a client key: %w", err)
	}
	return st, true, nil
}

// Cancel is a Stop: it marks turnID's lease cancel-requested (the holder,
// this engine or an older Mac, honours it) and wakes the session holding
// it. False means no such running turn.
func (e *Engine) Cancel(conv int64, turnID string) (bool, error) {
	ok, err := e.c.DB.RequestChatCancel(conv, turnID, e.c.Clock().UnixMilli())
	if err != nil || !ok {
		return ok, err
	}
	e.mu.Lock()
	if s := e.holding(conv); s != nil && s.turn.st.TurnID == turnID {
		s.cancelPoke = true
		s.poke()
	}
	e.mu.Unlock()
	return true, nil
}

// NewConversation creates an empty main chat in projectID (nil = none) with
// routing (nil or automatic = the default).
func (e *Engine) NewConversation(ctx context.Context, projectID *int64, r *chatstore.Routing) (int64, error) {
	id, err := e.store.NewConversation(ctx, projectID, r)
	if err == nil {
		e.changed(id)
	}
	return id, err
}

// ManageRequest is one Chats-panel write.
type ManageRequest struct {
	Conversation int64
	Op           string // pin|unpin|rename|delete|move
	Title        string
	ProjectID    *int64
}

// The chat_manage ops.
const (
	ManagePin    = "pin"
	ManageUnpin  = "unpin"
	ManageRename = "rename"
	ManageDelete = "delete"
	ManageMove   = "move"
)

// Manage applies a Chats-panel write. delete cancels the conversation's
// running turn: once the delete committed nothing more is written for it.
func (e *Engine) Manage(ctx context.Context, r ManageRequest) error {
	var err error
	switch r.Op {
	case ManagePin, ManageUnpin:
		err = e.store.Pin(ctx, r.Conversation, r.Op == ManagePin)
	case ManageRename:
		err = e.store.Rename(ctx, r.Conversation, r.Title)
	case ManageMove:
		err = e.store.Move(ctx, r.Conversation, r.ProjectID)
	case ManageDelete:
		err = e.delete(ctx, r.Conversation)
	default:
		return chatstore.ErrInvalid
	}
	if err == nil {
		e.changed(r.Conversation)
	}
	return err
}

// delete removes conv (its messages, steps and lease go by cascade, so a
// write of its running turn after the commit fails as gone) and then tells
// the session holding its turn to cancel and close.
func (e *Engine) delete(ctx context.Context, conv int64) error {
	if err := e.store.Delete(ctx, conv); err != nil {
		return err
	}
	e.mu.Lock()
	for _, s := range e.sessions {
		if s.conv == conv && s.turn != nil {
			s.gone = true
			s.poke()
		}
	}
	e.mu.Unlock()
	if e.c.FilesDir != "" {
		if err := chatstore.RemoveConversationFiles(e.c.FilesDir, conv); err != nil {
			log.Printf("chatengine: chat %d deleted, its attachment folder was not removed (%s)", conv, errClass(err))
		}
	}
	return nil
}

// SelectBranch makes messageID's newest leaf the active one.
func (e *Engine) SelectBranch(ctx context.Context, messageID int64) error {
	if err := e.store.SelectBranch(ctx, messageID); err != nil {
		return err
	}
	var conv int64
	if err := e.c.DB.QueryRowContext(ctx, `SELECT conversation_id FROM chat_messages WHERE id = ?`, messageID).Scan(&conv); err == nil {
		e.changed(conv)
	}
	return nil
}

// MarkRead marks conv read up to messageID.
func (e *Engine) MarkRead(ctx context.Context, conv, messageID int64) error {
	err := e.store.MarkRead(ctx, conv, messageID)
	if err == nil {
		e.changed(conv)
	}
	return err
}

// ConversationExists says whether main chat conv is there (a Discuss chat
// counts as absent: the phone reaches main chats only).
func (e *Engine) ConversationExists(ctx context.Context, conv int64) (bool, error) {
	return e.store.ConversationExists(ctx, conv)
}

// Feed is conv's feed (ReadFeed) with the engine's live turn over it.
func (e *Engine) Feed(ctx context.Context, conv, beforeMessageID int64) (Feed, error) {
	return ReadFeed(ctx, e.c.Read, conv, beforeMessageID, e.c.Clock(), e)
}

// List is the main chat's list (ReadList).
func (e *Engine) List(ctx context.Context) (List, error) {
	return ReadList(ctx, e.c.Read, e.c.Clock())
}

// Search is the chat search (ReadSearch).
func (e *Engine) Search(_ context.Context, q string) (SearchResult, error) {
	return ReadSearch(e.c.Read, q)
}

// Close stops every session (close, a 2 s grace, SIGTERM, SIGKILL after
// 3 s) and waits for each one's last write, then ends the subscriptions. A
// turn cut here keeps its text as `partial` with its lease, which the next
// start's sweep releases.
func (e *Engine) Close(ctx context.Context) error {
	e.mu.Lock()
	e.closed = true
	for _, s := range e.sessions {
		s.closing = true
		s.poke()
	}
	e.mu.Unlock()
	e.titlesCancel()
	done := make(chan struct{})
	go func() {
		e.wg.Wait()
		e.titles.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-ctx.Done():
		return ctx.Err()
	}
	e.subMu.Lock()
	subs := make([]*Subscription, 0, len(e.subs))
	for s := range e.subs {
		subs = append(subs, s)
	}
	e.subMu.Unlock()
	for _, s := range subs {
		s.Close()
	}
	return nil
}

// title runs Config.Title for conv off the finalizing goroutine (the store's
// title hook must not block); refused once the engine closes.
func (e *Engine) title(conv int64) {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return
	}
	e.titles.Add(1)
	e.mu.Unlock()
	go func() {
		defer e.titles.Done()
		ctx, cancel := context.WithTimeout(e.titlesCtx, titleBudget)
		defer cancel()
		if err := e.c.Title(ctx, conv); err != nil {
			log.Printf("chatengine: chat %d got no AI title (%s)", conv, errClass(err))
		}
	}()
}
