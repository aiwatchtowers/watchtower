// Package chatrun runs the hub's AI chat turns (spec §4.3 of the iPhone
// chat design): one `watchtower ai session` (protocol v2) child per
// conversation, at most MaxLive at once (CHAT-03's second bounded pool), its
// stdout events folded into the Go turn store (internal/chatstore) on one
// goroutine per session, the turn lease kept alive and watched for the
// other side's Stop, and the startup sweep of what a killed daemon left.
//
// Logs carry ids, counts and error classes only (FILES-01).
package chatrun

import (
	"context"
	"errors"
	"log"
	"slices"
	"strconv"
	"sync"
	"time"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
)

// MaxLive is the most `ai session` processes the hub runs at once (D13); a
// retiring process still counts until it exited.
const MaxLive = 2

// IdleTTL is how long an idle session stays warm.
const IdleTTL = 10 * time.Minute

// ErrClosed is the answer of a closing runner (the daemon stops).
var ErrClosed = errors.New("chatrun: runner closed")

// Config is what a Runner runs with.
type Config struct {
	// Exe is the watchtower binary; DBPath the database file the sessions
	// open (--db-path).
	Exe, DBPath string
	// HubID is this hub's id: the lease owner id of its turns.
	HubID string
	// Dir is the hub's directory: the children's process-group files live
	// in <Dir>/chatrun ("" = none written).
	Dir string
	// DB is the database the store writes (lease heartbeat, cancel poll,
	// sweep).
	DB    *db.DB
	Store *chatstore.Store
	// Start spawns one session child (nil = Exe in its own process group).
	Start StartFunc
	Clock func() time.Time
	// OnChange is called when a conversation's live state changed (a turn
	// queued, started, streamed or ended); OnTurnEnd when a turn was
	// finalized, with its stored status. Both run on a runner goroutine and
	// must not block.
	OnChange  func(conv int64)
	OnTurnEnd func(conv int64, turnID, status string)
	// procArgs reads a process's command line (nil = ps); a test seam.
	procArgs func(pid int) (string, error)
}

// Runner is the hub's chat session pool.
type Runner struct {
	c Config

	mu       sync.Mutex
	sessions []*session // every session not yet ended, in creation order
	closed   bool
	wg       sync.WaitGroup
}

// New returns a runner; nothing runs until the first Run.
func New(c Config) *Runner {
	if c.Clock == nil {
		c.Clock = time.Now
	}
	if c.Start == nil {
		c.Start = execStart(c.Exe)
	}
	if c.procArgs == nil {
		c.procArgs = psArgs
	}
	return &Runner{c: c}
}

// Run starts a turn (chatstore.Store.Start under the hub's lease) and hands
// it to the conversation's session, a warm one when it fits, else a new one
// that launches when a slot is free. It returns once the start transaction
// committed; the turn then runs on the session's goroutine.
func (r *Runner) Run(ctx context.Context, req chatstore.StartRequest) (chatstore.Started, error) {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return chatstore.Started{}, ErrClosed
	}
	prev := r.usable(req.ConversationID)
	var leaf *int64
	if prev != nil && prev.turn == nil && prev.leaf != nil {
		l := *prev.leaf
		leaf = &l
	}
	r.mu.Unlock()

	req.ContinuousLeafID = leaf
	st, err := r.c.Store.Start(ctx, req)
	if err != nil {
		return st, err
	}
	turn := r.c.Store.Turn(st)
	cfg := configOf(st)

	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		// The daemon stops: the turn never runs.
		r.finalizeUnsent(st, turn, chatstore.StatusPartial, lostFailure())
		return st, nil
	}
	s := r.usable(req.ConversationID)
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
		s = r.newSession(req.ConversationID, cfg)
	}
	now := r.c.Clock()
	s.turn = &heldTurn{st: st, t: turn, at: now}
	s.lastActivity = now
	s.poke()
	r.admit()
	r.mu.Unlock()
	r.changed(req.ConversationID)
	return st, nil
}

// Cancel is a Stop: it marks turnID's lease cancel-requested (the holder,
// this runner or the Mac, honours it) and wakes the session holding it. False
// means no such running turn.
func (r *Runner) Cancel(conv int64, turnID string) (bool, error) {
	ok, err := r.c.DB.RequestChatCancel(conv, turnID, r.c.Clock().UnixMilli())
	if err != nil || !ok {
		return ok, err
	}
	r.mu.Lock()
	if s := r.holding(conv); s != nil && s.turn.st.TurnID == turnID {
		s.cancelPoke = true
		s.poke()
	}
	r.mu.Unlock()
	return true, nil
}

// Live is the conversation's running (or queued) hub turn: its text and
// steps so far, and whether it waits for a free slot. ok is false when the
// hub runs no turn of conv.
func (r *Runner) Live(conv int64) (text string, steps []chatstore.Step, waitingSlot bool, ok bool) {
	r.mu.Lock()
	s := r.holding(conv)
	if s == nil {
		r.mu.Unlock()
		return "", nil, false, false
	}
	t, waiting := s.turn.t, s.phase == phasePending && s.blocked
	r.mu.Unlock()
	return t.Text(), t.Steps(), waiting, true
}

// Close stops every session (close, a 2 s grace, SIGTERM, SIGKILL after
// 3 s) and waits for each one's last write. A turn cut here keeps its text
// as `partial` with its lease, which the next start's sweep releases.
func (r *Runner) Close(ctx context.Context) error {
	r.mu.Lock()
	r.closed = true
	for _, s := range r.sessions {
		s.closing = true
		s.poke()
	}
	r.mu.Unlock()
	done := make(chan struct{})
	go func() {
		r.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// usable is conv's session that may take a turn (r.mu held).
func (r *Runner) usable(conv int64) *session {
	for _, s := range r.sessions {
		if s.conv == conv && !s.retire && !s.closing && !s.dropped {
			return s
		}
	}
	return nil
}

// holding is the session holding a turn of conv (r.mu held).
func (r *Runner) holding(conv int64) *session {
	for _, s := range r.sessions {
		if s.conv == conv && s.turn != nil {
			return s
		}
	}
	return nil
}

func (r *Runner) newSession(conv int64, cfg sessionConfig) *session {
	s := &session{r: r, conv: conv, cfg: cfg, kick: make(chan struct{}, 1), lastActivity: r.c.Clock()}
	r.sessions = append(r.sessions, s)
	r.wg.Add(1)
	go s.loop()
	return s
}

// admit is the pool decision (r.mu held), Swift ChatSessionPolicy.decide
// with MaxLive 2: a waiting session launches when a slot is free; else the
// least recently used idle session is told to close and the waiting one
// launches once it exited; a session mid-turn is never cut, so with every
// slot mid-turn the waiting one is blocked ("Waiting for a free slot"). A
// conversation's new session never launches before its old process exited.
func (r *Runner) admit() {
	if r.closed {
		return
	}
	occupied, coming := 0, 0
	var victims []*session
	for _, s := range r.sessions {
		if s.phase == phasePending {
			continue
		}
		occupied++
		switch {
		case s.retire || s.closing || s.dropped:
			coming++
		case s.phase == phaseLive && s.turn == nil:
			victims = append(victims, s)
		}
	}
	slices.SortStableFunc(victims, func(a, b *session) int { return a.lastActivity.Compare(b.lastActivity) })
	free := MaxLive - occupied
	for _, s := range r.sessions {
		if s.phase != phasePending || s.turn == nil || s.dropped || s.closing {
			continue
		}
		s.blocked = false
		if r.predecessorAlive(s) {
			continue // its old process is exiting; it frees the slot this one takes
		}
		switch {
		case free > 0:
			free--
			s.phase = phaseLaunch
			s.poke()
		case coming > 0:
			coming--
		case len(victims) > 0:
			v := victims[0]
			victims = victims[1:]
			v.retire = true
			v.poke()
		default:
			s.blocked = true
		}
	}
}

// predecessorAlive: another session of s's conversation still has a process.
func (r *Runner) predecessorAlive(s *session) bool {
	for _, o := range r.sessions {
		if o != s && o.conv == s.conv && o.phase != phasePending {
			return true
		}
	}
	return false
}

// ended removes s from the pool and re-admits.
func (r *Runner) ended(s *session) {
	r.mu.Lock()
	if i := slices.Index(r.sessions, s); i >= 0 {
		r.sessions = slices.Delete(r.sessions, i, i+1)
	}
	s.turn = nil
	r.admit()
	r.mu.Unlock()
	r.changed(s.conv)
}

func (r *Runner) changed(conv int64) {
	if r.c.OnChange != nil {
		r.c.OnChange(conv)
	}
}

func (r *Runner) turnEnded(conv int64, turnID, status string) {
	if r.c.OnTurnEnd != nil {
		r.c.OnTurnEnd(conv, turnID, status)
	}
}

// finalizeUnsent ends a turn that never reached a process, on the calling
// goroutine (nothing else holds it).
func (r *Runner) finalizeUnsent(st chatstore.Started, t *chatstore.Turn, status string, f *chatstore.Failure) {
	err := t.Finalize(status, f)
	if err != nil {
		err = t.Finalize(status, f) // one retry; then the lease goes stale
	}
	if err != nil {
		log.Printf("chatrun: conversation %d: finalizing an unsent turn failed (%s)", st.ConversationID, errClass(err))
		return
	}
	r.turnEnded(st.ConversationID, st.TurnID, status)
}

// sessionConfig is what a session process is spawned with (Swift
// ChatSessionConfig): every argv field.
type sessionConfig struct {
	automatic       bool
	provider, model string
	project         int64 // 0 = none
}

func configOf(st chatstore.Started) sessionConfig {
	c := sessionConfig{automatic: st.Routing.Automatic, provider: st.Routing.Provider, model: st.Routing.Model}
	if st.ProjectID != nil {
		c.project = *st.ProjectID
	}
	return c
}

// compatible is ChatSessionConfig.isCompatible.
func (c sessionConfig) compatible(o sessionConfig) bool {
	return c.automatic == o.automatic && (c.automatic || (c.provider == o.provider && c.model == o.model)) &&
		c.project == o.project
}

// argv is the session's arguments after the executable — flags only, never
// content (CHAT-04).
func (c sessionConfig) argv(conv int64, dbPath string) []string {
	a := []string{"ai", "session", "--conversation", strconv.FormatInt(conv, 10), "--surface", "main"}
	if !c.automatic {
		a = append(a, "--provider", c.provider)
		if c.model != "" {
			a = append(a, "--model", c.model)
		}
	}
	if c.project != 0 {
		a = append(a, "--project-id", strconv.FormatInt(c.project, 10))
	}
	if dbPath != "" {
		a = append(a, "--db-path", dbPath)
	}
	return a
}

// lostFailure is a turn whose session died under it.
func lostFailure() *chatstore.Failure {
	return &chatstore.Failure{Code: chat.CodeSessionLost, Message: "The chat session ended before the answer finished."}
}

// errClass names an error without its text (FILES-01).
func errClass(err error) string {
	switch {
	case err == nil:
		return "none"
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, chatstore.ErrConversationGone):
		return "conversation_gone"
	case errors.Is(err, ErrClosed):
		return "closed"
	}
	var t interface{ Timeout() bool }
	if errors.As(err, &t) && t.Timeout() {
		return "timeout"
	}
	return "error"
}
