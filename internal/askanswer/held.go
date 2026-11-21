package askanswer

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"watchtower/internal/asks"
)

// HeldStore keeps the held answers' ids across a restart (the hub's
// *state.Store, hub_meta).
type HeldStore interface {
	Meta(key string) (string, bool, error)
	SetMeta(key, value string) error
}

// HeldMetaKey is the hub's HeldStore key of the held answers (Deps.HeldKey's
// default): ask, session and run ids only (no content); the line is rebuilt
// from owner_asks at start.
const HeldMetaKey = "handlers_held_asks"

// heldLine is a line waiting for its session to leave a permission prompt, a
// failed state read or the owner's draft (SessionLineDelivery's held line):
// never typed into a later launch (that launch's brief lists the answer).
// An ask's line (askID set) is kept in Held; a line of no ask
// (DeliverLine) lives in memory only.
type heldLine struct {
	id               uint64 // this Answerer's own handle on the entry
	askID, sessionID int64
	// run is the launch the line was meant for, when known (pinned): a line
	// held because the host could not be read has none yet.
	run    uint64
	pinned bool
	line   string
	// notAfter, for a held line with no pinned run, is when the answer was
	// stored: a launch started after it already lists the answer in its
	// brief, so the line never goes into it.
	notAfter time.Time
}

// heldRecord is a held answer as Held keeps it.
type heldRecord struct {
	Ask     int64  `json:"ask"`
	Session int64  `json:"session"`
	Run     uint64 `json:"run"`
	Pinned  bool   `json:"pinned"`
}

func (a *Answerer) hold(line heldLine) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.seq++
	line.id = a.seq
	a.held = append(a.held, line)
	a.saveHeldLocked()
}

// saveHeldLocked writes the held answers' ids to Held, so a restart
// (session-host keeps the sessions) still delivers them. Called with a.mu.
func (a *Answerer) saveHeldLocked() {
	if a.d.Held == nil {
		return
	}
	recs := make([]heldRecord, 0, len(a.held))
	for _, l := range a.held {
		if l.askID != 0 {
			recs = append(recs, heldRecord{Ask: l.askID, Session: l.sessionID, Run: l.run, Pinned: l.pinned})
		}
	}
	b, err := json.Marshal(recs)
	if err == nil {
		err = a.d.Held.SetMeta(a.d.HeldKey, string(b))
	}
	if err != nil {
		log.Printf("askanswer: held answers not kept (%d)", len(recs))
	}
}

// loadHeld rebuilds the held answers at start: each kept id whose ask is
// still answered (not delivered by the brief since) in the same session gets
// its line again from owner_asks.
func (a *Answerer) loadHeld() {
	if a.d.Held == nil {
		return
	}
	raw, ok, err := a.d.Held.Meta(a.d.HeldKey)
	if err != nil || !ok {
		if err != nil {
			log.Printf("askanswer: held answers not read")
		}
		return
	}
	var recs []heldRecord
	if err := json.Unmarshal([]byte(raw), &recs); err != nil {
		log.Printf("askanswer: held answers unreadable")
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, rec := range recs {
		ask, err := a.d.DB.GetOwnerAskByID(rec.Ask)
		if err != nil || ask.Status != "answered" || !ask.SessionID.Valid || ask.SessionID.Int64 != rec.Session ||
			ask.AutomationRunID.Valid {
			continue
		}
		ans, err := asks.ParseAnswer([]byte(ask.Answer))
		if err != nil {
			log.Printf("askanswer: ask %d: held answer unreadable", rec.Ask)
			continue
		}
		a.seq++
		a.held = append(a.held, heldLine{id: a.seq, askID: rec.Ask, sessionID: rec.Session, run: rec.Run, pinned: rec.Pinned,
			line: asks.DeliveryLine(rec.Ask, ask.Kind, ans)})
	}
	a.saveHeldLocked()
}

// DeliverHeld tries every held line again (after a read of the session
// states): one whose session still waits on a permission prompt, or whose
// host or state cannot be read, is held again; one whose session stopped or
// runs another launch goes nowhere — the session's brief lists it. Each line
// leaves the queue (and Held) just before its own delivery, so neither an
// overlapping call nor a restart mid-delivery sends a line twice, and a
// crash loses at most the one line in flight (its brief still has it).
func (a *Answerer) DeliverHeld(ctx context.Context) {
	a.mu.Lock()
	held := append([]heldLine(nil), a.held...)
	a.mu.Unlock()
	for _, line := range held {
		if !a.takeHeld(line) {
			continue // an overlapping call took it
		}
		line, ok := a.stillAnswered(line)
		if !ok {
			continue
		}
		if a.deliver(ctx, line) == DeliveryCannotType {
			log.Printf("askanswer: ask %d: held line cannot be typed", line.askID)
		}
	}
}

// HoldsLine reports whether a line of no ask (DeliverLine) with exactly this
// text still waits held for sessionID: DeliverHeld will try it again, so a
// caller that would type the same line again (the twin's stall ping) waits
// for it instead of queueing a second copy.
func (a *Answerer) HoldsLine(sessionID int64, line string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, l := range a.held {
		if l.askID == 0 && l.sessionID == sessionID && l.line == line {
			return true
		}
	}
	return false
}

// takeHeld removes line from the held set and Held; false when it was no
// longer there.
func (a *Answerer) takeHeld(line heldLine) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	for i, l := range a.held {
		if l.id == line.id {
			a.held = append(a.held[:i:i], a.held[i+1:]...)
			a.saveHeldLocked()
			return true
		}
	}
	return false
}

// stillAnswered re-reads an ask's line right before it is typed: only an
// ask still answered (not read by the agent or delivered by the brief, not
// withdrawn) in the same session goes; its answered_at bounds an unpinned
// line's launch. A line of no ask always goes.
func (a *Answerer) stillAnswered(line heldLine) (heldLine, bool) {
	if line.askID == 0 {
		return line, true
	}
	ask, err := a.d.DB.GetOwnerAskByID(line.askID)
	if err != nil || ask.Status != "answered" || !ask.SessionID.Valid || ask.SessionID.Int64 != line.sessionID {
		return line, false
	}
	if at, err := time.Parse(answeredAtLayout, ask.AnsweredAt); err == nil {
		line.notAfter = at
	}
	return line, true
}
