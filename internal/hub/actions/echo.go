package actions

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Frame kinds of the mailbox records this lane reads and writes.
const (
	kindAction  = "action"
	kindControl = "control"
)

// control_queue.kind values: an echo of an action record, or a control kind.
const queueEcho = "echo"

// Wire reasons this package answers with (the Kit's ActionReason).
const (
	reasonDeviceNotLinked = "device_not_linked"
	reasonWrongHub        = "wrong_hub"
	reasonExpired         = "expired"
	reasonOutcomeUnknown  = "outcome_unknown"
	reasonUnsupported     = "unsupported_in_poc"
	reasonWriteFailed     = "write_failed"
)

// The Swift hub's messages, verbatim.
const (
	notLinkedMessage  = "This phone is not linked to this Mac."
	wrongHubMessage   = "This was sent to another Mac."
	clockAheadMessage = "Your iPhone's and Mac's clocks differ by more than 5 minutes — check Date & Time on both."
	restartedMessage  = "The Mac restarted while applying this"
)

// knownStatuses are the statuses a handler may answer with.
var knownStatuses = []string{
	wire.StatusApplied, wire.StatusFailed, wire.StatusExpired, wire.StatusCancelled,
	wire.StatusReceived, wire.StatusHeld,
}

func failed(reason, message string) Outcome {
	return Outcome{Status: wire.StatusFailed, Reason: reason, Message: message}
}

// normalize turns a handler answer with no or an unknown status into
// failed/write_failed: every action ends with an echo the phone understands.
func normalize(o Outcome) Outcome {
	for _, s := range knownStatuses {
		if o.Status == s {
			return o
		}
	}
	return failed(reasonWriteFailed, "")
}

// ledgerOutcome is relay_processed.outcome: "status" or "status:reason".
func ledgerOutcome(o Outcome) string {
	if o.Reason == "" {
		return o.Status
	}
	return o.Status + ":" + o.Reason
}

// storedEcho is relay_processed.echo, the Swift hub's ActionOutcome JSON
// (Foundation's default keys), so an adopted ledger reads the same.
type storedEcho struct {
	Status       string                     `json:"status"`
	Reason       *string                    `json:"reason,omitempty"`
	Result       map[string]json.RawMessage `json:"result,omitempty"`
	ErrorMessage *string                    `json:"errorMessage,omitempty"`
}

// result is o's echo result: Result plus Delivery as result.delivery.
func (o Outcome) result() (map[string]json.RawMessage, error) {
	if len(o.Result) == 0 && o.Delivery == "" {
		return nil, nil
	}
	out := make(map[string]json.RawMessage, len(o.Result)+1)
	for k, v := range o.Result {
		b, err := json.Marshal(v)
		if err != nil {
			return nil, fmt.Errorf("actions: echo result %q: %w", k, err)
		}
		out[k] = b
	}
	if o.Delivery != "" {
		b, err := json.Marshal(o.Delivery)
		if err != nil {
			return nil, err
		}
		out["delivery"] = b
	}
	return out, nil
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// encodeStored is o as relay_processed.echo.
func encodeStored(o Outcome) ([]byte, error) {
	res, err := o.result()
	if err != nil {
		return nil, err
	}
	return json.Marshal(storedEcho{Status: o.Status, Reason: optional(o.Reason), Result: res, ErrorMessage: optional(o.Message)})
}

// decodeStored reads a stored echo back as an Outcome; ok is false for an
// unreadable one.
func decodeStored(b []byte) (Outcome, bool) {
	var s storedEcho
	if len(b) == 0 || json.Unmarshal(b, &s) != nil || s.Status == "" {
		return Outcome{}, false
	}
	o := Outcome{Status: s.Status}
	if s.Reason != nil {
		o.Reason = *s.Reason
	}
	if s.ErrorMessage != nil {
		o.Message = *s.ErrorMessage
	}
	if len(s.Result) > 0 {
		o.Result = make(map[string]any, len(s.Result))
		for k, v := range s.Result {
			o.Result[k] = v
		}
	}
	return o, true
}

// echoPayload is the action rewritten with o (the Swift echoRecord): the
// same id, kind, params and action_seq, with o's status, reason, message and
// result.
func echoPayload(a wire.ActionRequest, o Outcome) ([]byte, error) {
	res, err := o.result()
	if err != nil {
		return nil, err
	}
	a.Status = o.Status
	a.Reason = optional(o.Reason)
	a.ErrorMessage = optional(o.Message)
	a.Result = res
	return wire.Marshal(a)
}

// queued is one sealed mailbox write ready for the control queue.
type queued struct {
	rec    secure.Record
	kind   string
	expect state.Control
}

// control is q as a control_queue row for mailbox.
func (q queued) control(mailbox string) state.Control {
	c := q.expect
	c.Mailbox, c.RecordName, c.Kind, c.Envelope = mailbox, q.rec.WireName(), q.kind, q.rec.Envelope()
	return c
}

func expectSeq(seq uint64) state.Control {
	return state.Control{Expect: state.ExpectSeq, ExpectSeq: seq}
}

var expectAbsent = state.Control{Expect: state.ExpectAbsent}

// sealEcho seals a's echo with o for the phone at b, overwriting wireName
// under expect. Sealing happens before the deciding transaction: the Sealer
// may write the seq ceiling in a transaction of its own.
func (p *Processor) sealEcho(b mailbox, wireName, plain string, a wire.ActionRequest, o Outcome, expect state.Control) (queued, error) {
	payload, err := echoPayload(a, o)
	if err != nil {
		return queued{}, err
	}
	rec, err := p.cfg.Sealer.ToPhone(b.zone, b.id, wireName, kindAction, plain, payload)
	if err != nil {
		return queued{}, fmt.Errorf("actions: sealing an echo: %w", err)
	}
	return queued{rec: rec, kind: queueEcho, expect: expect}, nil
}

// droppable reports whether err is a verdict about the bytes (they do not
// open, name another record or sender, are rolled back) rather than a
// failure of the hub itself (a locked keyring, an unreadable sidecar), which
// must stop the pass so nothing is lost.
func droppable(err error) bool {
	for _, e := range []error{
		secure.ErrTooShort, secure.ErrBadMagic, secure.ErrUnsupportedVersion, secure.ErrUnsupportedSuite,
		secure.ErrUnknownClass, secure.ErrLengthMismatch, secure.ErrAuthenticationFailed, secure.ErrFrameMalformed,
		secure.ErrOversized, secure.ErrWrongClass, secure.ErrWrongHub, secure.ErrWrongSender, secure.ErrNameMismatch,
		secure.ErrEpochNotAccepted, secure.ErrNoRelayKey, secure.ErrRolledBack, secure.ErrSignatureMissing,
		secure.ErrSignatureInvalid,
	} {
		if errors.Is(err, e) {
			return true
		}
	}
	return false
}

// errClass is an error's class for logs and control_queue.last_error_class:
// never its text (FILES-01).
func errClass(err error) string {
	classes := []struct {
		err   error
		class string
	}{
		{transport.ErrUnavailable, "unavailable"}, {transport.ErrRateLimited, "rate_limited"},
		{transport.ErrMailboxQuota, "mailbox_quota"}, {transport.ErrHubQuota, "hub_quota"},
		{transport.ErrRecordTooLarge, "record_too_large"}, {transport.ErrForbidden, "forbidden"},
		{transport.ErrEntitlementInactive, "entitlement_inactive"}, {transport.ErrTokenExpired, "token_expired"},
		{transport.ErrUnsupportedVersion, "unsupported_version"}, {context.Canceled, "canceled"},
		{context.DeadlineExceeded, "deadline"}, {secure.ErrWrongClass, "wrong_class"},
		{secure.ErrWrongSender, "wrong_sender"}, {secure.ErrWrongHub, "wrong_hub"},
		{secure.ErrNameMismatch, "name_mismatch"}, {secure.ErrRolledBack, "rolled_back"},
		{secure.ErrEpochNotAccepted, "epoch_not_accepted"}, {secure.ErrNoRelayKey, "no_relay_key"},
		{secure.ErrAuthenticationFailed, "authentication_failed"},
	}
	for _, c := range classes {
		if errors.Is(err, c.err) {
			return c.class
		}
	}
	if droppable(err) {
		return "malformed"
	}
	return "other"
}
