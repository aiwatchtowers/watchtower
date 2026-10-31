package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

// LocalSealer seals and opens a sidecar content value under the hub's wrap
// key (identity.Keyring's SealLocal/OpenLocal).
type LocalSealer interface {
	SealLocal(label string, plain []byte) ([]byte, error)
	OpenLocal(label string, sealed []byte) ([]byte, error)
}

// heldActionLabel is the SealLocal label of held_session_lines.action: the
// phone's whole action (its text included) is sealed; only the sanitised
// line stays in the clear, as it always was (spec §8 p. 4a's allowlist).
const heldActionLabel = "held_session_lines.action"

// lineState is the in-memory side of the phone lines (PROJ-16): which
// sessions a line is going to right now, when a line was last submitted into
// each session, and the queue of later echoes, written one after another.
type lineState struct {
	mu         sync.Mutex
	delivering map[int64]bool
	submitted  map[int64]time.Time
	queue      []pendingEcho
	echoing    bool
	pending    sync.WaitGroup
}

type pendingEcho struct {
	r actions.Request
	o actions.Outcome
}

// begin marks a line going to sessionID; false while another one is (the
// second line is held agent_busy, SessionLineDelivery's .queued).
func (s *lineState) begin(sessionID int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.delivering == nil {
		s.delivering = map[int64]bool{}
	}
	if s.delivering[sessionID] {
		return false
	}
	s.delivering[sessionID] = true
	return true
}

func (s *lineState) end(sessionID int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.delivering, sessionID)
}

// noteSubmit records that a line was submitted into sessionID at time at (any line: a
// phone line or an ask answer, SessionLineDelivery.submittedAt).
func (s *lineState) noteSubmit(sessionID int64, at time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.submitted == nil {
		s.submitted = map[int64]time.Time{}
	}
	s.submitted[sessionID] = at
}

func (s *lineState) submittedAt(sessionID int64) (time.Time, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	at, ok := s.submitted[sessionID]
	return at, ok
}

// heldLine is one held_session_lines row: the phone's request (opened from
// its sealed action), the session, the sanitised line, the launch the line
// was held in (run + launch = the run's start; launch "" = not known yet),
// the reason it waits and whether a try is typing it.
type heldLine struct {
	req       actions.Request
	sessionID int64
	line      string
	run       uint64
	launch    string
	reason    string
	typing    bool
}

func (l heldLine) phone() phoneLine {
	return phoneLine{req: l.req, sessionID: l.sessionID, line: l.line}
}

// heldAction is the sealed content of held_session_lines.action.
type heldAction struct {
	Device string             `json:"device"`
	Action wire.ActionRequest `json:"action"`
}

// saveHeld stores a line held on its first try, so a hub restart (the
// session host keeps the session) still delivers it.
func (h *Handlers) saveHeld(l heldLine) error {
	if h.d.Sealer == nil {
		return errors.New("no sidecar sealer")
	}
	plain, err := json.Marshal(heldAction{Device: l.req.Device.String(), Action: l.req.Action})
	if err != nil {
		return err
	}
	sealed, err := h.d.Sealer.SealLocal(heldActionLabel, plain)
	clear(plain)
	if err != nil {
		return fmt.Errorf("sealing a held line: %w", err)
	}
	run, err := i64(l.run)
	if err != nil {
		return err
	}
	err = h.d.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`INSERT OR REPLACE INTO held_session_lines
			(record_name, action, session_id, line, run, launch, reason, typing) VALUES (?, ?, ?, ?, ?, ?, ?, 0)`,
			l.req.RecordName, sealed, l.sessionID, l.line, run, l.launch, l.reason)
		return err
	})
	if err != nil {
		return fmt.Errorf("storing a held line: %w", err)
	}
	return nil
}

func i64(v uint64) (int64, error) {
	if v > 1<<63-1 {
		return 0, errors.New("run counter out of range")
	}
	return int64(v), nil
}

// heldLines reads every held line. A row whose action does not open is
// dropped (logged by its row only): it can be neither typed nor echoed.
func (h *Handlers) heldLines() ([]heldLine, error) {
	type raw struct {
		record, line, launch, reason string
		action                       []byte
		session                      int64
		run                          sql.NullInt64
		typing                       bool
	}
	var rows []raw
	err := h.d.Store.ReadTx(context.Background(), func(tx *sql.Tx) error {
		rs, err := tx.Query(`SELECT record_name, action, session_id, line, run, launch, reason, typing
			FROM held_session_lines ORDER BY rowid`)
		if err != nil {
			return err
		}
		defer rs.Close()
		for rs.Next() {
			var r raw
			if err := rs.Scan(&r.record, &r.action, &r.session, &r.line, &r.run, &r.launch, &r.reason, &r.typing); err != nil {
				return err
			}
			rows = append(rows, r)
		}
		return rs.Err()
	})
	if err != nil {
		return nil, fmt.Errorf("reading held lines: %w", err)
	}
	out := make([]heldLine, 0, len(rows))
	for _, r := range rows {
		req, ok := h.openHeld(r.record, r.action)
		if !ok {
			log.Printf("hub handlers: a held line of session %d does not open: dropped", r.session)
			if _, err := h.removeHeld(r.record, true); err != nil {
				log.Printf("hub handlers: an unreadable held line of session %d was not removed", r.session)
			}
			continue
		}
		out = append(out, heldLine{
			req: req, sessionID: r.session, line: r.line, run: uint64(max(r.run.Int64, 0)), launch: r.launch,
			reason: r.reason, typing: r.typing,
		})
	}
	return out, nil
}

// openHeld rebuilds a held line's request from its sealed action; an
// adopted Swift row (its action in the clear, the sender in device_id) is
// read as such.
func (h *Handlers) openHeld(record string, blob []byte) (actions.Request, bool) {
	var a heldAction
	if h.d.Sealer != nil {
		if plain, err := h.d.Sealer.OpenLocal(heldActionLabel, blob); err == nil {
			err = json.Unmarshal(plain, &a)
			clear(plain)
			if err != nil {
				return actions.Request{}, false
			}
		}
	}
	if a.Device == "" {
		if json.Unmarshal(blob, &a.Action) != nil || a.Action.DeviceID == nil {
			return actions.Request{}, false
		}
		a.Device = *a.Action.DeviceID
	}
	device, err := secure.ParseID(a.Device)
	if err != nil || a.Action.ID == "" {
		return actions.Request{}, false
	}
	return actions.Request{Device: device, RecordName: record, Action: a.Action}, true
}

// claimHeld marks a held line as being typed, right before its paste: false
// when it is gone (cancelled, finished) or another try holds it.
func (h *Handlers) claimHeld(record string) (bool, error) {
	var n int64
	err := h.d.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		res, err := tx.Exec(`UPDATE held_session_lines SET typing = 1 WHERE record_name = ? AND typing = 0`, record)
		if err != nil {
			return err
		}
		n, err = res.RowsAffected()
		return err
	})
	if err != nil {
		return false, fmt.Errorf("claiming a held line: %w", err)
	}
	return n == 1, nil
}

// reholdLine keeps a line held with reason (a try of it held it again):
// claimed is whether this try marked it typing (it is unmarked); an
// unclaimed try never touches a row another try is typing. An unpinned line
// is pinned to run/launch when they are known. changed reports a new reason
// (echoed again).
func (h *Handlers) reholdLine(record, reason string, claimed bool, run uint64, launch string) (changed bool, err error) {
	r, err := i64(run)
	if err != nil {
		return false, err
	}
	err = h.d.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		var old string
		var typing bool
		err := tx.QueryRow(`SELECT reason, typing FROM held_session_lines WHERE record_name = ?`, record).Scan(&old, &typing)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		if typing && !claimed {
			return nil
		}
		changed = old != reason
		_, err = tx.Exec(`UPDATE held_session_lines SET reason = ?, typing = 0,
			run = CASE WHEN launch = '' AND ? != '' THEN ? ELSE run END,
			launch = CASE WHEN launch = '' THEN ? ELSE launch END
			WHERE record_name = ?`, reason, launch, r, launch, record)
		return err
	})
	if err != nil {
		return false, fmt.Errorf("updating a held line: %w", err)
	}
	return changed, nil
}

// removeHeld deletes a held line; an unclaimed removal leaves a row another
// try is typing. removed is false when no row went.
func (h *Handlers) removeHeld(record string, claimed bool) (bool, error) {
	q := `DELETE FROM held_session_lines WHERE record_name = ? AND typing = 0`
	if claimed {
		q = `DELETE FROM held_session_lines WHERE record_name = ?`
	}
	var n int64
	err := h.d.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		res, err := tx.Exec(q, record)
		if err != nil {
			return err
		}
		n, err = res.RowsAffected()
		return err
	})
	if err != nil {
		return false, fmt.Errorf("removing a held line: %w", err)
	}
	return n == 1, nil
}

// finishLine ends a held line: out of the sidecar, its outcome echoed late.
// Nothing is echoed when the row was already gone (another try or a cancel
// finished it).
func (h *Handlers) finishLine(l heldLine, claimed bool, o actions.Outcome) {
	removed, err := h.removeHeld(l.req.RecordName, claimed)
	if err != nil {
		log.Printf("hub handlers: a held line of session %d was not removed", l.sessionID)
		return
	}
	if removed {
		h.lateEcho(l.req, o)
	}
}

// startHeldLines runs when the handlers are registered (a hub start): a line
// marked as being typed when the hub stopped is outcome_unknown and never
// typed again; one past its age or whose device lost its grant ends now. The
// others wait for the next read of the session states (DeliverHeld), where
// a session that stopped or runs another launch fails them.
func (h *Handlers) startHeldLines() {
	rows, err := h.heldLines()
	if err != nil {
		log.Printf("hub handlers: held lines not read at start")
		return
	}
	for _, l := range rows {
		switch {
		case l.typing:
			h.finishLine(l, true, failed(reasonOutcomeUnknown, restartedTypingMessage))
		case h.standingFailure(l.phone()) != "":
			h.finishLine(l, false, lineFailure(h.standingFailure(l.phone())))
		}
	}
}

// Revoked fails every held line of device that no try is typing right now
// with device_not_allowed (spec §10: Revoke or Remove on the Mac, or the
// phone's toggle turned off). Lines a try is typing end with that try.
func (h *Handlers) Revoked(device string) {
	rows, err := h.heldLines()
	if err != nil {
		log.Printf("hub handlers: held lines not read for a revoke")
		return
	}
	for _, l := range rows {
		if !l.typing && strings.EqualFold(l.req.Device.String(), device) {
			h.finishLine(l, false, lineFailure(inputReasonDeviceNotAllowed))
		}
	}
}

// lateEcho queues a later outcome of an action already echoed: written one
// after another on a goroutine of its own, never inside a dispatch (the
// processor's pass lock is not re-entrant), so it lands after the pass that
// echoed held.
func (h *Handlers) lateEcho(r actions.Request, o actions.Outcome) {
	s := &h.lines
	s.pending.Add(1)
	s.mu.Lock()
	s.queue = append(s.queue, pendingEcho{r: r, o: o})
	start := !s.echoing
	s.echoing = true
	s.mu.Unlock()
	if start {
		go h.writeEchoes()
	}
}

func (h *Handlers) writeEchoes() {
	s := &h.lines
	for {
		s.mu.Lock()
		if len(s.queue) == 0 {
			s.echoing = false
			s.mu.Unlock()
			return
		}
		e := s.queue[0]
		s.queue = s.queue[1:]
		s.mu.Unlock()
		if h.d.LateEcho == nil {
			log.Printf("hub handlers: a held line's later echo has no writer")
		} else if err := h.d.LateEcho(context.Background(), e.r, e.o); err != nil {
			log.Printf("hub handlers: a held line's later echo was not written")
		}
		s.pending.Done()
	}
}
