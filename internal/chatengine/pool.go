package chatengine

// The session pool (CHAT-03): one `watchtower ai session` (protocol v2)
// child per conversation, at most MaxLive at once, its stdout events folded
// into the Go turn store (internal/chatstore) on one goroutine per session.

import (
	"context"
	"errors"
	"log"
	"slices"
	"strconv"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
)

// usable is conv's session that may take a turn (e.mu held).
func (e *Engine) usable(conv int64) *session {
	for _, s := range e.sessions {
		if s.conv == conv && !s.retire && !s.closing && !s.dropped {
			return s
		}
	}
	return nil
}

// holding is the session holding a turn of conv (e.mu held).
func (e *Engine) holding(conv int64) *session {
	for _, s := range e.sessions {
		if s.conv == conv && s.turn != nil {
			return s
		}
	}
	return nil
}

func (e *Engine) newSession(conv int64, cfg sessionConfig) *session {
	s := &session{r: e, conv: conv, cfg: cfg, kick: make(chan struct{}, 1), lastActivity: e.c.Clock()}
	e.sessions = append(e.sessions, s)
	e.wg.Add(1)
	go s.loop()
	return s
}

// admit is the pool decision (e.mu held), Swift ChatSessionPolicy.decide
// with MaxLive 3: a waiting session launches when a slot is free; else the
// least recently used idle session is told to close and the waiting one
// launches once it exited; a session mid-turn is never cut, so with every
// slot mid-turn the waiting one is blocked ("Waiting for a free slot"). A
// conversation's new session never launches before its old process exited.
func (e *Engine) admit() {
	if e.closed {
		return
	}
	occupied, coming := 0, 0
	var victims []*session
	for _, s := range e.sessions {
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
	for _, s := range e.sessions {
		if s.phase != phasePending || s.turn == nil || s.dropped || s.closing {
			continue
		}
		s.blocked = false
		if e.predecessorAlive(s) {
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
func (e *Engine) predecessorAlive(s *session) bool {
	for _, o := range e.sessions {
		if o != s && o.conv == s.conv && o.phase != phasePending {
			return true
		}
	}
	return false
}

// ended removes s from the pool and re-admits.
func (e *Engine) ended(s *session) {
	e.mu.Lock()
	if i := slices.Index(e.sessions, s); i >= 0 {
		e.sessions = slices.Delete(e.sessions, i, i+1)
	}
	s.turn = nil
	e.admit()
	e.mu.Unlock()
	e.changed(s.conv)
}

// changed: conv's live state changed (a turn queued, started, streamed or
// ended) — its subscribers and the OnChange hook hear of it.
func (e *Engine) changed(conv int64) {
	e.notify(conv)
	if fn := e.onChange.Load(); fn != nil {
		(*fn)(conv)
	}
}

// turnEnded: a turn was finalized with its stored status.
func (e *Engine) turnEnded(conv int64, turnID, status string) {
	if fn := e.onTurnEnd.Load(); fn != nil {
		(*fn)(conv, turnID, status)
	}
}

// finalizeUnsent ends a turn that never reached a process, on the calling
// goroutine (nothing else holds it).
func (e *Engine) finalizeUnsent(st chatstore.Started, t *chatstore.Turn, status string, f *chatstore.Failure) {
	err := t.Finalize(status, f)
	if err != nil {
		err = t.Finalize(status, f) // one retry; then the lease goes stale
	}
	if err != nil {
		log.Printf("chatengine: conversation %d: finalizing an unsent turn failed (%s)", st.ConversationID, errClass(err))
		return
	}
	e.turnEnded(st.ConversationID, st.TurnID, status)
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
