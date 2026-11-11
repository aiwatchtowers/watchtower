package sessionhost

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"sync/atomic"
	"time"
)

// CheckTimeout bounds how long a delivery waits, after its pause, for the
// requesting connection's DeliverCheckReply. No answer in time counts as a
// failed re-check: the line stays typed and no Return follows.
const CheckTimeout = 5 * time.Second

// Deliver outcomes (DeliveredMsg.Outcome).
const (
	// OutcomeSubmitted: pasted, then Return — ours, or the owner's own
	// during the pause.
	OutcomeSubmitted = "submitted"
	// OutcomeTyped: pasted and left in the prompt without its Return.
	OutcomeTyped = "typed"
	// OutcomeHeld: nothing written (Reason HeldPromptHasText).
	OutcomeHeld = "held"
	// OutcomeNoSession: no running session of that row, run and launch, or
	// the run changed during the pause.
	OutcomeNoSession = "no_session"
	// OutcomeNoPasteMode: bracketed paste is off; nothing written.
	OutcomeNoPasteMode = "no_paste_mode"
)

// MaxSettle caps DeliverReq.SettleMs: a longer pause would keep the
// pending Return, and with it every phone line held, that long.
const MaxSettle = CheckTimeout

// HeldPromptHasText is the one hold the host decides: under
// HoldIfPromptText the prompt held the owner's draft, a line in its pause or
// a line left typed.
const HeldPromptHasText = "prompt_has_text"

// Why a line was left typed (DeliveredMsg.Reason with OutcomeTyped), for the
// caller's log: codes only, never text.
const (
	TypedBesideText        = "beside_text"         // the prompt held text before the paste
	TypedNoSubmit          = "submit_if_false"     // the caller's pre-check said no Return
	TypedCheckFailed       = "check_failed"        // the re-check failed, timed out or its connection dropped
	TypedDialog            = "dialog"              // a permission dialog after the pause
	TypedCannotSubmit      = "cannot_submit"       // the caller's re-check said no Return
	TypedTextDuringPause   = "text_during_pause"   // the owner typed during the pause
	TypedOwnerReturnDialog = "owner_return_dialog" // the owner's Return in the pause may have gone into a dialog
)

// DeliveryEvent kinds (DeliveryEventMsg.Kind).
const (
	EventPasted    = "pasted"
	EventLeftTyped = "left_typed"
	EventSubmitted = "submitted"
)

// DeliverReq asks the host to type one line into a session — one bracketed
// paste, then, after a pause, one Return of its own only into a prompt that
// held nothing before and after the pause (PROJ-12). The connection is never
// bound to the session.
type DeliverReq struct {
	// ID names the request on its connection; the DeliverCheck and the
	// Delivered answer carry it.
	ID     string `json:"id"`
	Row    int64  `json:"row"`
	Run    string `json:"run"`
	Launch uint64 `json:"launch"`
	Text   string `json:"text"`
	// KeepLineBreaks / KeepFormat: PasteText's cleaning.
	KeepLineBreaks bool `json:"keep_line_breaks,omitempty"`
	KeepFormat     bool `json:"keep_format,omitempty"`
	// SettleMs is the pause between paste and Return; zero or less uses
	// the agent profile's PasteSettle, more than MaxSettle is MaxSettle.
	SettleMs int `json:"settle_ms,omitempty"`
	// SubmitIf is the caller's pre-check: false only pastes.
	SubmitIf bool `json:"submit_if,omitempty"`
	// HoldIfPromptText: write nothing while the prompt holds text (every
	// phone line, PROJ-16); answered held(prompt_has_text).
	HoldIfPromptText bool `json:"hold_if_prompt_text,omitempty"`
}

// DeliverCheckMsg asks the requesting connection, after the pause, to
// re-check the session's state before the Return.
type DeliverCheckMsg struct {
	ID string `json:"id"`
}

// DeliverCheckReplyMsg answers a DeliverCheck. Fresh: the caller's re-read
// succeeded. CanSubmit: its conditions for a Return still hold.
// AnswersDialog: a permission dialog is up, so an owner's Return during the
// pause may have answered it instead of sending the line.
type DeliverCheckReplyMsg struct {
	ID            string `json:"id"`
	Fresh         bool   `json:"fresh"`
	CanSubmit     bool   `json:"can_submit"`
	AnswersDialog bool   `json:"answers_dialog,omitempty"`
}

// DeliveredMsg answers a Deliver.
type DeliveredMsg struct {
	ID      string `json:"id"`
	Outcome string `json:"outcome"`
	Reason  string `json:"reason,omitempty"`
}

// DeliveryEventMsg tells the session's attached client what a delivery did,
// so its pane keeps showing its hints. BesideText (with EventLeftTyped): the
// line shares the prompt with other text not submitted, so the owner's
// Return sends them together (Desktop's sharedPrompts).
type DeliveryEventMsg struct {
	Row        int64  `json:"row"`
	Run        string `json:"run"`
	Kind       string `json:"kind"`
	BesideText bool   `json:"beside_text,omitempty"`
}

// deliver starts a delivery for c. It runs on its own goroutine: its pause
// and re-check must not stop the connection's other frames (the
// DeliverCheckReply among them).
func (s *Server) deliver(c *conn, p []byte) {
	var req DeliverReq
	if err := json.Unmarshal(p, &req); err != nil {
		c.sendError(fmt.Sprintf("deliver: bad request: %v", err))
		return
	}
	if req.ID == "" {
		c.sendError("deliver: empty id")
		return
	}
	// A line that cleans to nothing types nothing: no empty paste, no
	// Return into an empty prompt.
	if PasteText(req.Text, req.KeepLineBreaks, req.KeepFormat) == "" {
		c.sendError("deliver: empty text")
		return
	}
	replies, ok := c.expectCheck(req.ID)
	if !ok {
		c.sendError(fmt.Sprintf("deliver: id %q already in use", req.ID))
		return
	}
	go func() {
		defer c.dropCheck(req.ID)
		out := s.runDelivery(c, req, replies)
		out.ID = req.ID
		c.send(Delivered, encode(out))
	}()
}

// runDelivery is Deliver's algorithm. Every exit clears the pending Return
// it set.
func (s *Server) runDelivery(c *conn, req DeliverReq, replies <-chan DeliverCheckReplyMsg) DeliveredMsg {
	sess := s.lookup(req.Row, req.Run)
	if sess == nil || sess.launch != req.Launch {
		return DeliveredMsg{Outcome: OutcomeNoSession}
	}
	payload := PastePayload(PasteText(req.Text, req.KeepLineBreaks, req.KeepFormat))

	// Decide and paste under wmu, so no owner key lands between the
	// prompt read and the paste.
	sess.wmu.Lock()
	sess.mu.Lock()
	if sess.exited || sess.reaped {
		sess.mu.Unlock()
		sess.wmu.Unlock()
		return DeliveredMsg{Outcome: OutcomeNoSession}
	}
	if !sess.modes.On(bracketedPasteMode) {
		sess.mu.Unlock()
		sess.wmu.Unlock()
		return DeliveredMsg{Outcome: OutcomeNoPasteMode}
	}
	besideText := sess.prompt.holdsText()
	if besideText && req.HoldIfPromptText {
		sess.mu.Unlock()
		sess.wmu.Unlock()
		return DeliveredMsg{Outcome: OutcomeHeld, Reason: HeldPromptHasText}
	}
	pause := !besideText && req.SubmitIf
	if pause {
		sess.prompt.beginPause()
	} else {
		sess.prompt.leaveTyped()
	}
	sess.mu.Unlock()
	_, err := sess.ptmx.Write(payload)
	sess.wmu.Unlock()
	if err != nil {
		// Only a closed PTY refuses a write: the session is gone.
		if pause {
			sess.endPauseLocked()
		}
		return DeliveredMsg{Outcome: OutcomeNoSession}
	}
	sess.event(EventPasted, false)
	if !pause {
		sess.event(EventLeftTyped, besideText)
		reason := TypedNoSubmit
		if besideText {
			reason = TypedBesideText
		}
		return DeliveredMsg{Outcome: OutcomeTyped, Reason: reason}
	}

	time.Sleep(settleFor(req.SettleMs, sess.profile))
	if s.opts.inPause != nil {
		s.opts.inPause()
	}
	reply := s.recheck(c, req.ID, replies)
	return s.afterPause(sess, req, reply)
}

// settleFor is the pause for settleMs: the profile's PasteSettle for zero or
// less, at most MaxSettle.
func settleFor(settleMs int, prof Profile) time.Duration {
	if settleMs <= 0 {
		return prof.PasteSettle
	}
	return min(time.Duration(settleMs)*time.Millisecond, MaxSettle)
}

// recheck sends the DeliverCheck and waits for its reply. A reply that
// does not come within the check timeout, or a connection that drops,
// reads as not fresh.
func (s *Server) recheck(c *conn, id string, replies <-chan DeliverCheckReplyMsg) DeliverCheckReplyMsg {
	c.checkSent(id)
	c.send(DeliverCheck, encode(DeliverCheckMsg{ID: id}))
	timer := time.NewTimer(s.opts.checkTimeout)
	defer timer.Stop()
	select {
	case r := <-replies:
		return r
	case <-timer.C:
	case <-c.done:
	}
	return DeliverCheckReplyMsg{ID: id}
}

// afterPause ends the pause and writes the Return only when the run is the
// same, the re-check is fresh and allows it, no dialog is up and nothing
// reached the prompt meanwhile. An owner's submitting Return during the
// pause sent the line, unless the re-check failed or shows a dialog.
func (s *Server) afterPause(sess *session, req DeliverReq, reply DeliverCheckReplyMsg) DeliveredMsg {
	sess.wmu.Lock()
	defer sess.wmu.Unlock()
	cur := s.lookup(req.Row, req.Run)
	sess.mu.Lock()
	ownerReturned := sess.prompt.endPause()
	if cur != sess || sess.exited || sess.reaped {
		sess.mu.Unlock()
		return DeliveredMsg{Outcome: OutcomeNoSession}
	}
	dialog := reply.AnswersDialog || sess.prompt.dialog
	reason := ""
	switch {
	case !reply.Fresh:
		reason = TypedCheckFailed
	case ownerReturned && dialog:
		reason = TypedOwnerReturnDialog
	case ownerReturned:
		sess.mu.Unlock()
		sess.event(EventSubmitted, false)
		return DeliveredMsg{Outcome: OutcomeSubmitted}
	case !reply.CanSubmit:
		reason = TypedCannotSubmit
	case sess.prompt.draft:
		reason = TypedTextDuringPause
	case dialog:
		reason = TypedDialog
	}
	if reason != "" {
		besideText := sess.prompt.draft
		sess.prompt.leaveTyped()
		sess.mu.Unlock()
		sess.event(EventLeftTyped, besideText)
		return DeliveredMsg{Outcome: OutcomeTyped, Reason: reason}
	}
	sess.mu.Unlock()
	if _, err := sess.ptmx.Write(sess.profile.Submit); err != nil {
		return DeliveredMsg{Outcome: OutcomeNoSession}
	}
	sess.event(EventSubmitted, false)
	return DeliveredMsg{Outcome: OutcomeSubmitted}
}

// endPauseLocked ends a pause on an exit path that writes no Return.
func (s *session) endPauseLocked() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prompt.endPause()
}

// event sends a DeliveryEvent to the session's attached client, if any.
func (s *session) event(kind string, besideText bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn != nil {
		s.conn.send(DeliveryEvent, encode(DeliveryEventMsg{
			Row: s.key.row, Run: s.key.run, Kind: kind, BesideText: besideText,
		}))
	}
}

// expectCheck registers a delivery's id on the connection; false when the
// id is already in flight there.
func (c *conn) expectCheck(id string) (<-chan DeliverCheckReplyMsg, bool) {
	c.checksMu.Lock()
	defer c.checksMu.Unlock()
	if c.checks == nil {
		c.checks = map[string]*pendingCheck{}
	}
	if _, ok := c.checks[id]; ok {
		return nil, false
	}
	pc := &pendingCheck{replies: make(chan DeliverCheckReplyMsg, 1)}
	c.checks[id] = pc
	return pc.replies, true
}

// pendingCheck is one delivery waiting on its connection. sent: the host
// asked its DeliverCheck; a reply before that is not an answer to it.
type pendingCheck struct {
	replies chan DeliverCheckReplyMsg
	sent    bool
}

// checkSent marks the delivery's DeliverCheck as asked, from here on a
// reply counts.
func (c *conn) checkSent(id string) {
	c.checksMu.Lock()
	defer c.checksMu.Unlock()
	if pc := c.checks[id]; pc != nil {
		pc.sent = true
	}
}

func (c *conn) dropCheck(id string) {
	c.checksMu.Lock()
	defer c.checksMu.Unlock()
	delete(c.checks, id)
}

// answerCheck hands a DeliverCheckReply to its waiting delivery. A reply
// for no delivery in flight (late, or a second one), or one sent before the
// host asked (a pre-answer), is dropped.
func (c *conn) answerCheck(p []byte) {
	var m DeliverCheckReplyMsg
	if err := json.Unmarshal(p, &m); err != nil {
		c.sendError(fmt.Sprintf("deliver_check_reply: bad request: %v", err))
		return
	}
	c.checksMu.Lock()
	var replies chan DeliverCheckReplyMsg
	if pc := c.checks[m.ID]; pc != nil && pc.sent {
		replies = pc.replies
	}
	c.checksMu.Unlock()
	if replies == nil {
		return
	}
	select {
	case replies <- m:
	default:
	}
}

// deliverIDs numbers a Client's deliveries when the caller names none.
var deliverIDs atomic.Uint64

// Deliver types r.Text into a session (PROJ-12) and returns the host's
// outcome. After the pause the host asks for a re-check: check runs with a
// context bounded by CheckTimeout and its answer decides the Return. check
// must not use this Client. The call holds the Client for the whole delivery
// — the pause (up to MaxSettle) plus up to CheckTimeout for the re-check —
// so every other call on it (PromptHint, an Interrupt's InputTo, List, Stop)
// waits behind it: deliver on a Client of its own and send hints and
// interrupts on another. An empty r.ID is filled in. Text that cleans to
// nothing is refused (a *HostError), nothing written.
func (c *Client) Deliver(ctx context.Context, r DeliverReq, check func(context.Context) DeliverCheckReplyMsg) (DeliveredMsg, error) {
	if r.ID == "" {
		r.ID = "d" + strconv.FormatUint(deliverIDs.Add(1), 10)
	}
	_, p, err := c.do(ctx, func() (FrameType, []byte, error) {
		if err := WriteFrame(c.nc, Deliver, encode(r)); err != nil {
			return 0, nil, err
		}
		for {
			ft, p, err := c.readUntilAny(Delivered, DeliverCheck)
			if err != nil {
				return ft, p, err
			}
			if ft == Delivered {
				var m DeliveredMsg
				if json.Unmarshal(p, &m) == nil && m.ID == r.ID {
					return ft, p, nil
				}
				continue
			}
			var m DeliverCheckMsg
			if json.Unmarshal(p, &m) != nil || m.ID != r.ID {
				continue
			}
			cctx, cancel := context.WithTimeout(ctx, CheckTimeout)
			reply := check(cctx)
			cancel()
			reply.ID = r.ID
			if err := WriteFrame(c.nc, DeliverCheckReply, encode(reply)); err != nil {
				return 0, nil, err
			}
		}
	})
	if err != nil {
		return DeliveredMsg{}, fmt.Errorf("deliver: %w", err)
	}
	var m DeliveredMsg
	if err := json.Unmarshal(p, &m); err != nil {
		return DeliveredMsg{}, fmt.Errorf("deliver: %w", err)
	}
	return m, nil
}
