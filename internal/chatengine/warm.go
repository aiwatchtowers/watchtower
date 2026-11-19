package chatengine

import (
	"context"
	"encoding/json"

	"watchtower/internal/chatstore"
)

// The Mac's warm sessions (unified chat T8, "not slower"): the landing makes
// its chat on the first keystroke and asks for its session at once, so the
// first answer does not wait for a spawn; a claude.ai connector switch
// retires the warm sessions, so none keeps the old tools; a draft left
// without a send is discarded. Each is a chat.sock operation of the app.

// ManageDiscard deletes the chat only while it is an untouched draft (no
// message, no attachment); a chat with either stays (chat_manage discard).
const ManageDiscard = "discard"

// Warm starts conv's session ahead of its first turn, with the routing req
// (nil: the conversation's). It never takes a slot a turn needs: it launches
// only into a free slot, else it is dropped, and once live it is an idle
// session like any other (evictable, closed after IdleTTL). A usable
// session of conv already there is kept (an incompatible idle one is
// retired first, as a turn would).
func (e *Engine) Warm(ctx context.Context, conv int64, req *chatstore.Routing) error {
	routing, project, err := e.store.SessionConfig(ctx, conv, req)
	if err != nil {
		return err
	}
	cfg := configOf(chatstore.Started{Routing: routing, ProjectID: project})
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.closed {
		return ErrClosed
	}
	if s := e.usable(conv); s != nil {
		if s.turn != nil || s.cfg.compatible(cfg) {
			s.lastActivity = e.c.Clock()
			return nil
		}
		s.retire = true
		s.poke()
	}
	s := e.newSession(conv, cfg)
	s.warm = true
	e.admit()
	return nil
}

// RetireWarm retires every session so the next turn starts a fresh one: an
// idle session closes now, a session mid-turn after its turn (the turn is
// never cut). The claude.ai connector switch, whose tools a session reads
// at spawn.
func (e *Engine) RetireWarm() {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range e.sessions {
		if s.closing || s.dropped || s.retire {
			continue
		}
		s.retire = true
		s.poke()
	}
	e.admit()
}

// discard deletes conv if it is an untouched draft and retires its warm
// session; a touched chat stays and its session too.
func (e *Engine) discard(ctx context.Context, conv int64) error {
	deleted, err := e.store.DeleteIfUntouched(ctx, conv)
	if err != nil || !deleted {
		return err
	}
	e.mu.Lock()
	for _, s := range e.sessions {
		if s.conv == conv && s.turn == nil && !s.closing && !s.dropped {
			s.retire = true
			if s.phase == phasePending {
				s.dropped = true
			}
			s.poke()
		}
	}
	e.admit()
	e.mu.Unlock()
	return nil
}

func (e *Engine) registerWarmOps() {
	e.Register("chat_warm", e.opWarm)
	e.Register("chat_sessions_retire", e.opSessionsRetire)
}

func (e *Engine) opWarm(ctx context.Context, params json.RawMessage, _ Client) (any, error) {
	var p struct {
		ConversationID int64          `json:"conversation_id"`
		Routing        *routingParams `json:"routing"`
	}
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if p.ConversationID <= 0 {
		return nil, errBadParams
	}
	req, ok := p.Routing.routing()
	if !ok {
		return nil, errBadParams
	}
	return ack(e.Warm(ctx, p.ConversationID, req))
}

func (e *Engine) opSessionsRetire(_ context.Context, _ json.RawMessage, _ Client) (any, error) {
	e.RetireWarm()
	return struct{}{}, nil
}
