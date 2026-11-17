package cmd

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/hub/chatrun"
	"watchtower/internal/logredact"
)

// `ai session --persist` (mobile inbox spec 2026-11-15 §8, stage 3): the
// session saves its own turns through chatstore instead of the Desktop's
// ChatTurnStore. Each stdin `turn` runs chatstore.Start — the lease claim and
// persistTurnStart's writes in one transaction — before the provider gets
// it, answers `started` (or `refused` while another owner holds the lease),
// then every event the session emits is folded into the turn's rows. A 1 s
// tick flushes trailing text, heartbeats the lease every 15 s and reads a
// remote Stop (cancel_requested_at_ms), as the hub's chatrun runner does.

var (
	aiSessionFlagPersist      bool
	aiSessionFlagLeaseOwner   string
	aiSessionFlagLeaseOwnerID string
)

// Refused turns' reasons: another owner holds the conversation's lease (the
// hub's refusal reason for the phone too), or the command has no turn_id —
// refused up front, so no event of it can read as a session-level error that
// would end another turn.
const (
	reasonConversationBusy = "conversation_busy"
	reasonTurnIDRequired   = "turn_id_required"
)

// maxPersistCommandBytes bounds one stdin line, as the session's own reader.
const maxPersistCommandBytes = 8 << 20

// aiSessionPersistNow is the persister's (and its store's) clock; tests
// move it.
var aiSessionPersistNow = time.Now

// aiSessionPersistTick is the persister's 1 s tick; tests drive it.
var aiSessionPersistTick = func() (<-chan time.Time, func()) {
	t := time.NewTicker(time.Second)
	return t.C, t.Stop
}

func init() {
	f := aiSessionCmd.Flags()
	f.BoolVar(&aiSessionFlagPersist, "persist", false,
		"save the turns' rows in this process (chatstore): start, progress, end and the lease")
	f.StringVar(&aiSessionFlagLeaseOwner, "lease-owner", string(db.ChatLeaseDesktop),
		"with --persist: who holds the turns' lease (desktop|hub)")
	f.StringVar(&aiSessionFlagLeaseOwnerID, "lease-owner-id", "",
		"with --persist: the lease holder's id (the app's launch id)")
}

// persistLeaseOwner validates the --persist flags.
func persistLeaseOwner() (db.ChatLeaseOwner, string, error) {
	owner := db.ChatLeaseOwner(aiSessionFlagLeaseOwner)
	if owner != db.ChatLeaseDesktop && owner != db.ChatLeaseHub {
		return "", "", fmt.Errorf("--lease-owner must be desktop or hub, got %q", aiSessionFlagLeaseOwner)
	}
	if aiSessionFlagLeaseOwnerID == "" {
		return "", "", errors.New("--persist needs --lease-owner-id")
	}
	return owner, aiSessionFlagLeaseOwnerID, nil
}

// eventQueue hands the session's events to the persister without ever
// blocking the writer (EventWriter.Observe must not block).
type eventQueue struct {
	mu    sync.Mutex
	evs   []chat.Event
	ready chan struct{}
}

func newEventQueue() *eventQueue { return &eventQueue{ready: make(chan struct{}, 1)} }

func (q *eventQueue) push(e chat.Event) {
	q.mu.Lock()
	q.evs = append(q.evs, e)
	q.mu.Unlock()
	select {
	case q.ready <- struct{}{}:
	default:
	}
}

func (q *eventQueue) take() []chat.Event {
	q.mu.Lock()
	defer q.mu.Unlock()
	evs := q.evs
	q.evs = nil
	return evs
}

// persistedTurn is the turn being saved.
type persistedTurn struct {
	st         chatstore.Started
	t          *chatstore.Turn
	heartbeat  time.Time
	flushed    int
	cancelSent bool
	cancelAt   time.Time
	retry      func() error // a terminal event whose write failed, retried on the next tick
}

// sessionPersister owns every write of the session's turns: one goroutine
// (loop) runs Start, Apply, Flush and Finalize.
type sessionPersister struct {
	ctx      context.Context
	database *db.DB
	store    *chatstore.Store
	conv     int64
	owner    db.ChatLeaseOwner
	ownerID  string
	now      func() time.Time
	out      *chat.EventWriter
	queue    *eventQueue

	toSession io.Writer
	cur       *persistedTurn
	pending   []chat.Command // turns that came while the previous one was still being saved
	leaf      *int64         // the last reply this process answered (ChatContinuity)
}

// runPersistedSession runs s with p between stdin and the session.
func runPersistedSession(ctx context.Context, s *chat.Session, p *sessionPersister, in io.Reader) error {
	pr, pw := io.Pipe()
	p.toSession = pw
	prev := p.out.Observe
	p.out.Observe = func(e chat.Event) {
		if prev != nil {
			prev(e)
		}
		p.queue.push(e)
	}
	sessionDone := make(chan struct{})
	loopDone := make(chan struct{})
	go func() {
		defer close(loopDone)
		p.loop(in, pw, sessionDone)
	}()
	err := s.Run(ctx, pr)
	_ = pr.Close() // a forward after the end fails instead of blocking
	close(sessionDone)
	<-loopDone
	return err
}

func (p *sessionPersister) loop(in io.Reader, toSession io.Closer, sessionDone <-chan struct{}) {
	lines := make(chan []byte)
	stop := make(chan struct{})
	defer close(stop)
	go readPersistLines(in, lines, stop)
	tick, stopTick := aiSessionPersistTick()
	defer stopTick()
	for {
		select {
		case line, ok := <-lines:
			if !ok {
				lines = nil
				_ = toSession.Close() // stdin EOF: the session ends as before
				continue
			}
			p.applyQueued()
			p.command(line)
		case <-p.queue.ready:
			p.applyQueued()
		case <-tick:
			p.applyQueued()
			p.onTick()
		case <-sessionDone:
			p.applyQueued()
			p.endOnExit()
			return
		}
	}
}

func readPersistLines(in io.Reader, out chan<- []byte, stop <-chan struct{}) {
	defer close(out)
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 64<<10), maxPersistCommandBytes)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		select {
		case out <- append([]byte(nil), line...):
		case <-stop:
			return
		}
	}
}

// command handles one stdin line: a turn is started here, anything else
// (cancel, close, a broken line) goes to the session as it came.
func (p *sessionPersister) command(line []byte) {
	var c chat.Command
	if json.Unmarshal(line, &c) != nil || c.Type != chat.CommandTurn {
		p.forward(line)
		return
	}
	if c.TurnID == "" {
		p.emit(chat.Event{Type: chat.EventRefused, Reason: reasonTurnIDRequired})
		return
	}
	if p.cur != nil {
		// The previous turn's end is not folded in yet: this one waits for it.
		p.pending = append(p.pending, c)
		return
	}
	p.startTurn(c)
}

func (p *sessionPersister) forward(line []byte) bool {
	_, err := p.toSession.Write(append(append([]byte(nil), line...), '\n'))
	return err == nil
}

func (p *sessionPersister) emit(e chat.Event) { _ = p.out.Emit(e) }

// saveError tells the Mac a write of the turn failed, as the Desktop's own
// writer showed it ("Couldn't save the reply: …"); the stderr log keeps the
// redacted detail.
func (p *sessionPersister) saveError(turnID, what string, err error) {
	p.emit(chat.Event{Type: chat.EventSaveError, TurnID: turnID, Message: what + ": " + err.Error()})
}

// startTurn writes the turn's starting rows, then hands it to the session.
func (p *sessionPersister) startTurn(c chat.Command) {
	req, err := p.startRequest(c)
	var st chatstore.Started
	if err == nil {
		st, err = p.store.Start(p.ctx, req)
	}
	switch {
	case errors.Is(err, chatstore.ErrBusy):
		holder := ""
		if l, lerr := p.database.GetChatLease(p.conv); lerr == nil && l != nil {
			holder = string(l.Owner)
		}
		p.emit(chat.Event{Type: chat.EventRefused, TurnID: c.TurnID, Reason: reasonConversationBusy, Holder: holder})
		return
	case err != nil:
		// Nothing was written or sent: the client keeps the text.
		p.emit(chat.Event{Type: chat.EventError, TurnID: c.TurnID, Code: chat.CodeInternal,
			Message: "Your message wasn't sent because it couldn't be saved: " + logredact.Full(err)})
		return
	}
	p.cur = &persistedTurn{st: st, t: p.store.Turn(st), heartbeat: p.now()}
	p.emit(startedEvent(st))
	text := st.SendText
	if c.Screen != "" {
		text = c.Screen + "\n\n" + text // ChatTurnText.compose: the screen block goes first
	}
	line, err := json.Marshal(chat.Command{Type: chat.CommandTurn, TurnID: st.TurnID, Text: text,
		Attachments: st.Attachments, Replay: st.Replay || c.Replay})
	if err != nil || !p.forward(line) {
		// The session is gone: the turn never ran.
		p.finalize(chatstore.StatusPartial, &chatstore.Failure{Code: chat.CodeSessionLost,
			Message: "The chat session ended before the answer started."})
	}
}

// startedEvent names the turn's rows and its prefix commands' results.
func startedEvent(st chatstore.Started) chat.Event {
	e := chat.Event{Type: chat.EventStarted, ConversationID: st.ConversationID, OwnerMessageID: st.UserMessageID,
		AssistantMessageID: st.AssistantMessageID, TurnID: st.TurnID, RememberOutcome: st.RememberOutcome,
		RememberLineID: st.RememberLineID, IdeaID: st.IdeaID, IdeaKind: st.IdeaKind}
	if st.PrefixErr != nil {
		e.PrefixError = logredact.Full(st.PrefixErr)
	}
	return e
}

// startRequest maps a turn command onto chatstore's request.
func (p *sessionPersister) startRequest(c chat.Command) (chatstore.StartRequest, error) {
	mode := c.Mode
	if mode == "" {
		mode = chatstore.ModeSend
	}
	if (c.ParentID != 0 && mode != chatstore.ModeRegenerate) || (c.EditMessageID != 0 && mode != chatstore.ModeEdit) {
		return chatstore.StartRequest{}, chatstore.ErrInvalid
	}
	r := chatstore.StartRequest{ConversationID: p.conv, Mode: mode, Text: c.Text, AttachmentIDs: c.AttachmentIDs,
		TurnID: c.TurnID, TitleText: c.TitleText, ContinuousLeafID: p.leaf,
		ReuseOwnerMessageID: c.ParentID, MessageID: c.EditMessageID}
	for _, id := range c.Quotes {
		r.Quotes = append(r.Quotes, chatstore.Quote{CommentID: id})
	}
	return r, nil
}

func (p *sessionPersister) applyQueued() {
	for _, ev := range p.queue.take() {
		p.apply(ev)
	}
	for p.cur == nil && len(p.pending) > 0 {
		c := p.pending[0]
		p.pending = p.pending[1:]
		p.startTurn(c)
	}
}

// apply folds one session event into the running turn.
func (p *sessionPersister) apply(ev chat.Event) {
	cur := p.cur
	if cur == nil || cur.retry != nil {
		return
	}
	err := cur.t.Apply(ev)
	switch {
	case errors.Is(err, chatstore.ErrConversationGone):
		p.lost()
		return
	case err != nil:
		stderrLogf("ai session: conversation %d: writing turn %s failed: %s", p.conv, cur.st.TurnID, logredact.Full(err))
		if done, _ := cur.t.Done(); endsTurn(ev, cur.st.TurnID) && !done {
			// The end is retried on the next tick; only a second failure is
			// the owner's to see.
			cur.retry = func() error { return cur.t.Apply(ev) }
		} else {
			p.saveError(cur.st.TurnID, "Couldn't save the reply", err)
		}
	}
	p.checkDone()
}

// endsTurn: ev is turnID's turn_done, or an error of it or of the session.
func endsTurn(ev chat.Event, turnID string) bool {
	switch ev.Type {
	case chat.EventTurnDone:
		return ev.TurnID == turnID
	case chat.EventError:
		return ev.TurnID == "" || ev.TurnID == turnID
	}
	return false
}

// checkDone lets go of a finalized turn.
func (p *sessionPersister) checkDone() {
	cur := p.cur
	if cur == nil || cur.retry != nil {
		return
	}
	done, status := cur.t.Done()
	if !done {
		return
	}
	if status == chatstore.StatusError {
		p.leaf = nil // it may or may not have reached the provider: replay next time
	} else {
		id := cur.st.AssistantMessageID
		p.leaf = &id
	}
	p.letGo()
}

// letGo drops the running turn: nothing more is written for it, and the
// client hears `turn_saved` — what a reload reads now is the turn's last
// state (its turn_done reached stdout before its end was written).
func (p *sessionPersister) letGo() {
	if p.cur == nil {
		return
	}
	turnID := p.cur.st.TurnID
	p.cur = nil
	p.emit(chat.Event{Type: chat.EventTurnSaved, TurnID: turnID})
}

// onTick: a failed end retried once, trailing text flushed, the lease kept
// and read for a remote Stop.
func (p *sessionPersister) onTick() {
	cur := p.cur
	if cur == nil {
		return
	}
	if cur.retry != nil {
		retry := cur.retry
		cur.retry = nil
		if err := retry(); errors.Is(err, chatstore.ErrConversationGone) {
			p.lost()
			return
		} else if err != nil {
			stderrLogf("ai session: conversation %d: the final write failed again (%s); the lease goes stale", p.conv, logredact.Full(err))
			p.saveError(cur.st.TurnID, "Couldn't finalize the reply", err)
			p.letGo()
			return
		}
		p.checkDone()
		if p.cur == nil {
			p.applyQueued()
			return
		}
	}
	if n := len(cur.t.Text()); n != cur.flushed {
		cur.flushed = n
		if err := cur.t.Flush(); errors.Is(err, chatstore.ErrConversationGone) {
			p.lost()
			return
		} else if err != nil {
			stderrLogf("ai session: conversation %d: flushing failed: %s", p.conv, logredact.Full(err))
			p.saveError(cur.st.TurnID, "Couldn't save the reply", err)
		}
	}
	p.watchLease(cur)
}

// watchLease is chatrun's lease watch for this process's turn.
func (p *sessionPersister) watchLease(cur *persistedTurn) {
	now := p.now()
	conv, turnID := cur.st.ConversationID, cur.st.TurnID
	if now.Sub(cur.heartbeat) >= chatrun.HeartbeatEvery {
		cur.heartbeat = now
		ok, err := p.database.HeartbeatChatLease(conv, turnID, now.UnixMilli())
		if err != nil {
			stderrLogf("ai session: conversation %d: lease heartbeat failed: %s", conv, logredact.Full(err))
		} else if !ok {
			p.lost()
			return
		}
	}
	l, err := p.database.GetChatLease(conv)
	if err != nil {
		stderrLogf("ai session: conversation %d: reading the lease failed: %s", conv, logredact.Full(err))
		return
	}
	if l == nil || l.TurnID != turnID || l.Owner != p.owner || l.OwnerID != p.ownerID {
		p.lost()
		return
	}
	switch {
	case l.CancelRequestedAtMS != nil && !cur.cancelSent:
		cur.cancelSent, cur.cancelAt = true, now
		p.forward([]byte(`{"type":"cancel"}`))
	case cur.cancelSent && now.Sub(cur.cancelAt) >= chatrun.CancelGrace:
		// The provider never answered the cancel: the reply ends `partial`
		// (the Mac's finishRunningAsPartial) and the lease is released.
		p.finalize(chatstore.StatusPartial, nil)
	}
}

// lost: the conversation is gone or its lease taken over — nothing more is
// written for the turn, and the provider is stopped.
func (p *sessionPersister) lost() {
	if p.cur == nil {
		return
	}
	stderrLogf("ai session: conversation %d: turn %s lost its conversation or lease; stopping it", p.conv, p.cur.st.TurnID)
	p.letGo()
	p.forward([]byte(`{"type":"cancel"}`))
	if p.conversationGone() {
		// Deleted (from the phone, say): the session has no chat to serve,
		// so it ends once the cancelled turn is out and is never reused
		// (CHAT-01, TestDriverStopsWhenConversationDeleted).
		p.forward([]byte(`{"type":"close"}`))
	}
}

// conversationGone reports whether the session's conversation row is gone.
// A read error is not "gone": the session stays.
func (p *sessionPersister) conversationGone() bool {
	var one int
	err := p.database.QueryRow(`SELECT 1 FROM chat_conversations WHERE id = ?`, p.conv).Scan(&one)
	return errors.Is(err, sql.ErrNoRows)
}

// finalize ends the running turn here (one retry; then the lease goes stale).
func (p *sessionPersister) finalize(status string, f *chatstore.Failure) {
	cur := p.cur
	if cur == nil {
		return
	}
	err := cur.t.Finalize(status, f)
	if err != nil && !errors.Is(err, chatstore.ErrConversationGone) {
		err = cur.t.Finalize(status, f)
	}
	if err != nil && !errors.Is(err, chatstore.ErrConversationGone) {
		stderrLogf("ai session: conversation %d: finalizing turn %s failed: %s", p.conv, cur.st.TurnID, logredact.Full(err))
		p.saveError(cur.st.TurnID, "Couldn't finalize the reply", err)
	}
	p.letGo()
}

// endOnExit: the session ended (stdin closed, close, a signal) with a turn
// still open — what streamed stays as a `partial` reply.
func (p *sessionPersister) endOnExit() {
	if p.cur == nil {
		return
	}
	if retry := p.cur.retry; retry != nil {
		p.cur.retry = nil
		if err := retry(); err == nil {
			p.checkDone()
		}
	}
	p.finalize(chatstore.StatusPartial, nil)
}

// checkQueryPersist validates `ai query --persist`: an embedded chat's
// protocol-v2 turn, named by its conversation and turn.
func checkQueryPersist() error {
	if !aiFlagPersist {
		return nil
	}
	switch {
	case aiFlagEvents != "v2":
		return errors.New("--persist needs --events v2")
	case aiFlagConversation <= 0:
		return errors.New("--persist needs --conversation")
	case aiFlagTurn == "":
		return errors.New("--persist needs --turn")
	}
	return nil
}

// queryPersist is one `ai query --persist` turn's writer.
type queryPersist struct {
	database *db.DB
	turn     *chatstore.EmbeddedTurn
}

// beginQueryPersist writes the turn's starting rows and answers `started`.
func beginQueryPersist(ctx context.Context, cfg *config.Config, dbPath string, w io.Writer) (*queryPersist, error) {
	database, err := db.Open(dbPath)
	if err != nil {
		return nil, fmt.Errorf("--persist: opening the database: %w", err)
	}
	store := chatstore.New(database, db.ChatLeaseDesktop, "")
	et, err := store.BeginEmbedded(ctx, aiFlagConversation, aiQueryOwnerText, aiFlagTurn, cfg.AI.Provider)
	if err != nil {
		_ = database.Close()
		return nil, fmt.Errorf("--persist: your message wasn't sent because it couldn't be saved: %w", err)
	}
	_ = chat.NewEventWriter(w).Emit(chat.Event{Type: chat.EventStarted, ConversationID: aiFlagConversation,
		OwnerMessageID: et.OwnerID, AssistantMessageID: et.MessageID, TurnID: aiFlagTurn})
	return &queryPersist{database: database, turn: et}, nil
}

// observer folds each written event into the turn; nil without --persist. A
// failure after the process was told to stop (the embedded chat's Stop is a
// SIGTERM) is the owner's Stop: the reply ends `partial`, as the engine
// writes it.
func (q *queryPersist) observer(ctx context.Context) func(chat.Event) {
	if q == nil {
		return nil
	}
	return func(ev chat.Event) {
		var err error
		if ev.Type == chat.EventError && ctx.Err() != nil {
			err = q.turn.Finalize(chatstore.StatusPartial, nil)
		} else {
			err = q.turn.Apply(ev)
		}
		if err != nil {
			stderrLogf("ai query: conversation %d: saving turn %s failed: %s", aiFlagConversation, aiFlagTurn, logredact.Full(err))
		}
	}
}

// close ends a turn the stream left open as `partial`, then closes the
// database.
func (q *queryPersist) close() {
	if !q.turn.Done() {
		if err := q.turn.Finalize(chatstore.StatusPartial, nil); err != nil {
			stderrLogf("ai query: conversation %d: finalizing turn %s failed: %s", aiFlagConversation, aiFlagTurn, logredact.Full(err))
		}
	}
	_ = q.database.Close()
}
