package chatrun

import (
	"log"
	"time"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
)

// HeartbeatEvery is the lease heartbeat of a held turn; the lease is read
// for the other side's Stop on every 1 s tick. CancelGrace is how long a
// cancelled turn may take to answer with turn_done before it is finalized
// `partial` and its process killed (Swift ChatSessionClient.cancel).
const (
	HeartbeatEvery = 15 * time.Second
	CancelGrace    = 7 * time.Second
)

// watchLease keeps the held turn's lease (spec §4.3, §4.4): a heartbeat
// every HeartbeatEvery (when heartbeat), then a read of the row. A row gone
// or held by another turn means the conversation was deleted or the lease
// taken over; a cancel request sends `cancel` (a turn not sent yet just
// ends `partial`).
func (s *session) watchLease(now time.Time, heartbeat bool) {
	s.r.mu.Lock()
	held := s.turn
	s.r.mu.Unlock()
	if held == nil {
		return
	}
	conv, turnID := held.st.ConversationID, held.st.TurnID
	if s.watchTurn != turnID {
		// The start transaction wrote the first heartbeat.
		s.watchTurn, s.heartbeat, s.cancelSent = turnID, held.at, false
	}
	if heartbeat && now.Sub(s.heartbeat) >= HeartbeatEvery {
		s.heartbeat = now
		ok, err := s.r.c.DB.HeartbeatChatLease(conv, turnID, now.UnixMilli())
		if err != nil {
			log.Printf("chatrun: conversation %d: lease heartbeat failed (%s)", conv, errClass(err))
		} else if !ok {
			s.lost()
			return
		}
	}
	l, err := s.r.c.DB.GetChatLease(conv)
	if err != nil {
		log.Printf("chatrun: conversation %d: reading the lease failed (%s)", conv, errClass(err))
		return
	}
	if l == nil || l.TurnID != turnID || l.Owner != db.ChatLeaseHub || l.OwnerID != s.r.c.HubID {
		s.lost()
		return
	}
	if l.CancelRequestedAtMS == nil || s.cancelSent {
		return
	}
	s.cancelSent = true
	if s.cur != held {
		// Never sent: nothing to interrupt. A queued session has nothing
		// left to launch for.
		s.r.mu.Lock()
		s.turn = nil
		if s.proc == nil {
			s.dropped = true
		}
		s.r.mu.Unlock()
		s.r.finalizeUnsent(held.st, held.t, chatstore.StatusPartial, nil)
		s.r.changed(conv)
		return
	}
	log.Printf("chatrun: conversation %d: turn %s cancelled", conv, turnID)
	if err := s.send(chat.Command{Type: chat.CommandCancel}); err != nil {
		// The pipe is gone: the process is exiting; end finalizes the turn.
		return
	}
	s.cancelAt = time.NewTimer(CancelGrace)
}

// onCancelDeadline: no turn_done came within CancelGrace — the turn keeps
// its text as `partial` and the session, which ignored `cancel`, is
// terminated and never reused.
func (s *session) onCancelDeadline() {
	cur := s.cur
	if cur == nil {
		return
	}
	if done, _ := cur.t.Done(); done {
		return
	}
	s.r.mu.Lock()
	s.retire = true
	s.r.mu.Unlock()
	if err := cur.t.Finalize(chatstore.StatusPartial, nil); err != nil {
		log.Printf("chatrun: conversation %d: finalizing a stopped turn failed (%s)", s.conv, errClass(err))
		s.retry = func() error { return cur.t.Finalize(chatstore.StatusPartial, nil) }
	}
	s.beginShutdown(true) // before checkDone, whose retire path would send `close`
	s.checkDone()
}

func (s *session) stopCancelWatch() {
	if s.cancelAt != nil {
		s.cancelAt.Stop()
		s.cancelAt = nil
	}
}
