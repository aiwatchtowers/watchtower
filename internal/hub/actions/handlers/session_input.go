package handlers

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
	"unicode"

	"github.com/rivo/uniseg"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionstate"
)

// PROJ-16 values (mobile POC spec §6.5, §6.6).
const (
	// FinishLine is session_finish_request's fixed line.
	FinishLine = "Please wrap up: update the board, then call finish_session with a short summary."
	// MaxInputLength is a phone line's cap in characters (grapheme clusters)
	// after SanitizeInput.
	MaxInputLength = 4000
	// heldLineLifetime: a held line expires this long after the phone
	// created it.
	heldLineLifetime = actions.SessionRequestMaxAge
	// busyAfterSubmit: after a line is submitted into a session, the session
	// counts as busy until a hook reports after the submit, or this long
	// passed (SessionControl.submitSettle).
	busyAfterSubmit = 30 * time.Second
)

// Wire reasons of the phone lines (the Kit's ActionReason).
const (
	inputReasonAgentBusy        = "agent_busy"
	inputReasonNeedsApproval    = "needs_approval"
	inputReasonPromptHasText    = "prompt_has_text"
	inputReasonStateUnknown     = "state_unknown"
	inputReasonNotRunning       = "session_not_running"
	inputReasonExpired          = "expired"
	inputReasonCancelled        = "cancelled"
	inputReasonDeviceNotAllowed = reasonDeviceNotAllowed
)

// SessionInputHandlers' messages, verbatim.
const (
	inputTimeoutMessage    = "The Mac did not finish this in time — check the session on the Mac"
	inputNotAllowedMessage = "This phone is not allowed to type into sessions — Allow it in Settings → Mobile on the Mac"
	inputNotRunningMessage = "The session is not running on the Mac"
	copiedMessage          = "The session can't take typed text — it is on the Mac's clipboard"
	restartedTypingMessage = "Your Mac restarted while typing this — check the session on the Mac"
	expiredMessage         = "Held for a day without the session getting idle"
	cancelledMessage       = "Cancelled on the phone"
	foreignCancelMessage   = "Only the phone that sent this message can cancel it"
	// lostWhileTypingMessage: the host connection failed during a Deliver,
	// so whether the line reached the prompt is not known.
	lostWhileTypingMessage = "The Mac lost the session while typing this — check the session on the Mac"
)

// inputKinds are the phone line kinds (SessionInputHandlers.kinds).
var inputKinds = []string{"session_input", "session_finish_request", "session_input_cancel"}

// SanitizeInput is the Kit's SessionInputText rule (PROJ-16), the same on
// the phone: a CRLF and every other line break or control character become
// one space each, format characters (an emoji's zero-width joiner) stay, and
// the ends are trimmed. ok is false unless the line is 1–MaxInputLength
// characters (grapheme clusters) after that.
func SanitizeInput(s string) (string, bool) {
	var b strings.Builder
	b.Grow(len(s))
	prevCR := false
	for _, r := range s {
		cr := prevCR
		prevCR = r == '\r'
		if r == '\n' && cr {
			continue
		}
		if isLineBreak(r) {
			b.WriteByte(' ')
		} else {
			b.WriteRune(r)
		}
	}
	line := strings.TrimFunc(b.String(), unicode.IsSpace)
	n := uniseg.GraphemeClusterCount(line)
	return line, n >= 1 && n <= MaxInputLength
}

// isLineBreak: Foundation's controlCharacters (Cc, Cf) or newlines, except
// format characters (Cf).
func isLineBreak(r rune) bool {
	if unicode.Is(unicode.Cf, r) {
		return false
	}
	switch r {
	case '\u0085', '\u2028', '\u2029':
		return true
	}
	return unicode.Is(unicode.Cc, r)
}

// phoneLine is one phone line and where it goes.
type phoneLine struct {
	req       actions.Request
	sessionID int64
	line      string
}

// tryResult is how one try of a line ended: a final outcome, held with a
// reason (Run/Launch: the launch it was checked against, when known), or
// gone (the line is over elsewhere: cancelled, finished, or the hub
// stopping). Claimed reports that the try marked the held row typing.
type tryResult struct {
	final   *actions.Outcome
	held    string
	gone    bool
	claimed bool
	run     uint64
	launch  string
}

// sessionInput is `session_input` (entity the session id, params {text}),
// `session_finish_request` (the session id; FinishLine) and
// `session_input_cancel` (entity the original action's id), PROJ-16: a line
// goes only from a device the owner allowed to type, only to a live board
// claude session, and only through session-host's typed-never-submitted
// Deliver with HoldIfPromptText. Right before every paste the agent must be
// idle for the current run or working (a Claude session queues a line typed
// mid-turn; the echo then says while_busy), never at a permission prompt and
// never right after a submit until a hook reported; otherwise the line is
// held (agent_busy, needs_approval, prompt_has_text — the host's answer —,
// state_unknown), kept in the sidecar, retried on each read of the session
// states (DeliverHeld, never on a timer), echoed again when its reason
// changes, and ends applied, failed or expired 24 h after the phone created
// it, through a late echo.
//
// The dispatch owns a 30 s deadline (outcome_unknown). A first try still
// running then goes on, but may no longer hold its line: holding is decided
// once, by whichever comes first — the try's commit or the deadline — so a
// line the phone was told to check on the Mac is never typed later.
func (h *Handlers) sessionInput(ctx context.Context, r actions.Request) actions.Outcome {
	if r.Action.Kind == "session_input_cancel" {
		return h.withTimeout(ctx, "session_input", inputTimeoutMessage, func(context.Context) actions.Outcome {
			return h.cancelLine(r)
		})
	}
	var decided atomic.Int32 // 0 running, 1 the try committed its hold, 2 the deadline won
	commit := func() bool { return decided.CompareAndSwap(0, 1) }
	done := make(chan actions.Outcome, 1)
	h.lines.tries.Add(1)
	go func() {
		defer h.lines.tries.Done()
		defer func() {
			if p := recover(); p != nil {
				log.Printf("hub handlers: session_input panicked")
				done <- failed(reasonWriteFailed, "The Mac hit an internal error applying this")
			}
		}()
		done <- h.sendLine(context.WithoutCancel(ctx), r, commit)
	}()
	t := time.NewTimer(h.d.Timeout)
	defer t.Stop()
	select {
	case o := <-done:
		return o
	case <-t.C:
	case <-ctx.Done():
	}
	if decided.CompareAndSwap(0, 2) {
		return failed(reasonOutcomeUnknown, inputTimeoutMessage)
	}
	return <-done // the try committed its hold first: its row is being written
}

// sendLine is one phone line's first try; commit, called right before a hold
// is stored, is false once the dispatch's deadline passed.
func (h *Handlers) sendLine(ctx context.Context, r actions.Request, commit func() bool) actions.Outcome {
	sessionID, ok := entityID(r)
	if !ok {
		return failed(reasonInvalidParams, r.Action.Kind+" needs a session id")
	}
	line := FinishLine
	if r.Action.Kind == "session_input" {
		text, ok := stringParam(r, "text")
		if !ok {
			return failed(reasonInvalidParams, "session_input needs a text")
		}
		var sendable bool
		line, sendable = SanitizeInput(text)
		if line == "" {
			return failed(reasonInvalidParams, "The message is empty")
		}
		if !sendable {
			return failed(reasonInvalidParams, "The message is longer than "+strconv.Itoa(MaxInputLength)+" characters")
		}
	}
	if !h.mayType(r) {
		return failed(reasonDeviceNotAllowed, inputNotAllowedMessage)
	}
	kind, onBoard, err := h.boardSession(ctx, sessionID)
	if err != nil {
		return failed(reasonWriteFailed, "Could not read the session: "+err.Error())
	}
	if !onBoard || kind != "claude" {
		return failed(reasonNotFound, sessionGoneMessage)
	}
	l := phoneLine{req: r, sessionID: sessionID, line: line}
	res := h.tryLine(ctx, l, nil)
	switch {
	case res.final != nil:
		return *res.final
	case res.gone:
		return failed(reasonOutcomeUnknown, inputTimeoutMessage)
	}
	if !commit() {
		// The phone was already answered outcome_unknown: the line is not
		// held, so nothing types it later.
		log.Printf("hub handlers: a phone line ended held after its deadline: not kept")
		return failed(reasonOutcomeUnknown, inputTimeoutMessage)
	}
	err = h.saveHeld(heldLine{req: r, sessionID: sessionID, line: line, run: res.run, launch: res.launch, reason: res.held})
	if err != nil {
		// Not kept for a restart, so not kept at all: a held line must be
		// known to the next start.
		return failed(reasonWriteFailed, "The Mac could not hold this message")
	}
	return heldOutcome(res.held)
}

// tryLine is one try of a line: PROJ-16's conditions right before the paste
// (after a fresh read of the host and the session state), then Deliver. held
// is the sidecar row of a retry (nil on the first try): a retry types only
// after claiming its row, only while ctx runs (a stopping hub's lines wait
// for the next start), and only into the launch it was held in.
func (h *Handlers) tryLine(ctx context.Context, l phoneLine, held *heldLine) tryResult {
	if reason := h.standingFailure(l); reason != "" {
		return finalResult(lineFailure(reason))
	}
	if !h.lines.begin(l.sessionID) {
		return tryResult{held: inputReasonAgentBusy}
	}
	defer h.lines.end(l.sessionID)
	live, ok, err := h.d.Sessions.Live(ctx, l.sessionID)
	if err != nil {
		return tryResult{held: inputReasonStateUnknown}
	}
	launch := launchKey(live)
	if !ok || live.Exited || (held != nil && held.launch != "" && (held.run != live.Run || held.launch != launch)) {
		return finalResult(lineFailure(inputReasonNotRunning))
	}
	res := tryResult{run: live.Run, launch: launch}
	row, err := sessionstate.Load(ctx, h.d.DB, l.sessionID)
	if errors.Is(err, sql.ErrNoRows) {
		return finalResult(lineFailure(inputReasonNotRunning))
	}
	if err != nil {
		res.held = inputReasonStateUnknown
		return res
	}
	if !live.StartedAt.IsZero() {
		row.RunStartedAt = db.AgentStateStamp(live.StartedAt)
	}
	now := h.d.Clock()
	s := sessionstate.Resolve(row, now)
	switch {
	case sessionstate.NeedsApproval(s):
		res.held = inputReasonNeedsApproval
	case !sessionstate.IsIdle(row, s) && !sessionstate.IsWorking(s), h.justSubmitted(l.sessionID, row, now):
		res.held = inputReasonAgentBusy
	}
	if res.held != "" {
		return res
	}
	if held != nil {
		if ctx.Err() != nil {
			return tryResult{gone: true}
		}
		claimed, err := h.claimHeld(held.req.RecordName)
		if err != nil {
			// Not marked, a restart could type it twice: hold it.
			res.held = inputReasonStateUnknown
			return res
		}
		if !claimed {
			return tryResult{gone: true}
		}
		res.claimed = true
	}
	whileBusy := sessionstate.IsWorking(s)
	out, heldBy := h.deliverPhoneLine(ctx, l, live, whileBusy)
	if heldBy != "" {
		res.held = heldBy
		return res
	}
	res.final = &out
	return res
}

// deliverPhoneLine is the Deliver of a line that passed its gate; heldBy is
// the host's hold reason (prompt_has_text), else out is final.
func (h *Handlers) deliverPhoneLine(ctx context.Context, l phoneLine, live LiveRun, whileBusy bool) (out actions.Outcome, heldBy string) {
	res, err := h.d.Sessions.Deliver(ctx, DeliverRequest{
		SessionID: l.sessionID, Run: live.Run, Text: l.line, HoldIfPromptText: true, Settle: submitSettle,
		Check: func(ctx context.Context) CheckAnswer {
			s, r, fresh := h.readState(ctx, l.sessionID, live)
			return CheckAnswer{
				Fresh:         fresh,
				CanSubmit:     fresh && sessionstate.HooksReported(r) && !sessionstate.NeedsApproval(s),
				AnswersDialog: sessionstate.NeedsApproval(s),
			}
		},
	})
	if err != nil {
		return failed(reasonOutcomeUnknown, lostWhileTypingMessage), ""
	}
	switch res.Outcome {
	case DeliverSubmitted:
		h.lines.noteSubmit(l.sessionID, h.d.Clock())
		o := actions.Outcome{Status: wire.StatusApplied, Delivery: deliverySubmitted}
		if whileBusy {
			o.Result = map[string]any{"while_busy": true}
		}
		return o, ""
	case DeliverTyped:
		return actions.Outcome{Status: wire.StatusApplied, Delivery: deliveryTyped}, ""
	case DeliverHeld:
		if res.Reason != "" {
			return actions.Outcome{}, res.Reason
		}
		return actions.Outcome{}, inputReasonPromptHasText
	case DeliverNoPasteMode:
		if h.d.DesktopHost() && h.d.Clipboard != nil && h.d.Clipboard(l.line) == nil {
			return failed(reasonCannotType, copiedMessage), ""
		}
		return failed(reasonCannotType, CannotTypeMessage), ""
	}
	return lineFailure(inputReasonNotRunning), ""
}

// justSubmitted: a line went into the session within busyAfterSubmit and no
// hook has reported since — the agent is turning to it.
func (h *Handlers) justSubmitted(sessionID int64, row sessionstate.Row, now time.Time) bool {
	at, ok := h.lines.submittedAt(sessionID)
	if !ok || now.Sub(at) >= busyAfterSubmit {
		return false
	}
	stamp, ok := db.ParseAgentStateStamp(sessionstate.TrustedHookAt(row))
	return !ok || !stamp.After(at)
}

// standingFailure is what ends a line whatever the session does: its age,
// its device's grant. "" when neither.
func (h *Handlers) standingFailure(l phoneLine) string {
	if h.d.Clock().Sub(l.req.Action.CreatedAt.Time) > heldLineLifetime {
		return inputReasonExpired
	}
	if !h.mayType(l.req) {
		return inputReasonDeviceNotAllowed
	}
	return ""
}

// mayType reports the request's device's typing grant; a device not linked,
// or a read failure, may not type.
func (h *Handlers) mayType(r actions.Request) bool {
	d, linked, err := h.d.Store.Device(r.Device.String())
	return err == nil && linked && d.TypingAllowed
}

// boardSession is the session's kind when it is an agent session (claude or
// codex) of a workbench that exists (BoardSessionScope.fetchBoardSession).
func (h *Handlers) boardSession(ctx context.Context, sessionID int64) (kind string, ok bool, err error) {
	err = h.d.DB.QueryRowContext(ctx, `SELECT t.kind FROM terminal_sessions t JOIN projects p ON p.id = t.project_id
		WHERE t.id = ? AND t.kind IN ('claude', 'codex')`, sessionID).Scan(&kind)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return kind, err == nil, err
}

// launchKey names one launch of a session for a held line: the host's run
// counter alone restarts with the host, its start does not.
func launchKey(live LiveRun) string {
	if live.StartedAt.IsZero() {
		return ""
	}
	return live.StartedAt.UTC().Format(time.RFC3339Nano)
}

func finalResult(o actions.Outcome) tryResult { return tryResult{final: &o} }

func heldOutcome(reason string) actions.Outcome {
	return actions.Outcome{Status: wire.StatusHeld, Reason: reason}
}

// lineFailure is the final outcome of a line ended by reason.
func lineFailure(reason string) actions.Outcome {
	switch reason {
	case inputReasonExpired:
		return actions.Outcome{Status: wire.StatusExpired, Reason: inputReasonExpired, Message: expiredMessage}
	case inputReasonDeviceNotAllowed:
		return failed(reason, inputNotAllowedMessage)
	case inputReasonNotRunning:
		return failed(reason, inputNotRunningMessage)
	}
	return failed(reason, "")
}

// DeliverHeld's part for the phone lines: every held line not being typed is
// tried once more. A line held again keeps its row (its new reason stored and
// echoed when it changed); a line that ends is removed and echoed late.
func (h *Handlers) deliverHeldLines(ctx context.Context) {
	rows, err := h.heldLines()
	if err != nil {
		log.Printf("hub handlers: held lines not read for a retry")
		return
	}
	for _, l := range rows {
		if l.typing {
			continue
		}
		if ctx.Err() != nil {
			return
		}
		res := h.tryLine(ctx, l.phone(), &l)
		if ctx.Err() != nil && !res.claimed {
			// The hub is stopping: what this try read is not trusted, and
			// the line waits, untouched, for the next start.
			return
		}
		switch {
		case res.gone:
		case res.final != nil:
			h.finishLine(l, res.claimed, *res.final)
		default:
			changed, err := h.reholdLine(l.req.RecordName, res.held, res.claimed, res.run, res.launch)
			if err != nil {
				log.Printf("hub handlers: a held line of session %d was not updated", l.sessionID)
				continue
			}
			if changed {
				h.lateEcho(l.req, heldOutcome(res.held))
			}
		}
	}
}

// cancelLine drops the original's held line and echoes it cancelled; a line
// already gone (delivered, failed, being typed) is left as it is. Only the
// phone that sent the line may cancel it.
func (h *Handlers) cancelLine(r actions.Request) actions.Outcome {
	if r.Action.EntityID == nil || *r.Action.EntityID == "" {
		return failed(reasonInvalidParams, "session_input_cancel needs the original action id")
	}
	original := *r.Action.EntityID
	rows, err := h.heldLines()
	if err != nil {
		return failed(reasonWriteFailed, "Could not read the held messages")
	}
	for _, l := range rows {
		if l.req.Action.ID != original {
			continue
		}
		if l.req.Device != r.Device {
			return failed(reasonDeviceNotAllowed, foreignCancelMessage)
		}
		if l.typing {
			return applied(nil)
		}
		h.finishLine(l, false, actions.Outcome{Status: wire.StatusCancelled, Reason: inputReasonCancelled, Message: cancelledMessage})
		return applied(nil)
	}
	return applied(nil)
}
