package chatengine

import "watchtower/internal/chatstore"

// Live is the conversation's running (or queued) engine turn: its text and
// steps so far, and whether it waits for a free slot. ok is false when the
// engine runs no turn of conv.
func (e *Engine) Live(conv int64) (text string, steps []chatstore.Step, waitingSlot, ok bool) {
	t, ok := e.LiveTurn(conv)
	return t.Text, t.Steps, t.WaitingSlot, ok
}

// LiveTurn is Live with the turn's id (Overlay).
func (e *Engine) LiveTurn(conv int64) (LiveTurn, bool) {
	e.mu.Lock()
	s := e.holding(conv)
	if s == nil {
		e.mu.Unlock()
		return LiveTurn{}, false
	}
	turnID, t, waiting := s.turn.st.TurnID, s.turn.t, s.phase == phasePending && s.blocked
	e.mu.Unlock()
	return LiveTurn{TurnID: turnID, Text: t.Text(), Steps: t.Steps(), WaitingSlot: waiting}, true
}

// LiveRouting is the routing conv's live session reported in its
// session_ready (Overlay): `ai session` writes the same to the conversation
// row itself, so a reader sees it before that write lands.
func (e *Engine) LiveRouting(conv int64) (LiveRouting, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for i := len(e.sessions) - 1; i >= 0; i-- {
		s := e.sessions[i]
		if s.conv == conv && s.readyLive != nil && !s.dropped {
			r := s.readyLive
			return LiveRouting{Mode: r.RoutingMode, Provider: r.Provider, Model: r.Model, Reason: r.Reason}, true
		}
	}
	return LiveRouting{}, false
}
