package link

import "time"

// Pairing event kinds, in the order a pairing sees them (`hub pair --json
// --stream`): the QR, waiting for a phone, the four-digit code, then linked
// or refused.
const (
	EventQR      = "qr"
	EventWaiting = "waiting"
	EventSAS     = "sas"
	EventLinked  = "linked"
	EventRefused = "refused"
)

// eventBuffer is how many events wait for a reader; a full buffer drops the
// newest (the state is in the sidecar, the events only narrate it).
const eventBuffer = 64

// PairEvent is one step of a pairing. URL and ExpiresAt are the QR's (qr);
// DeviceID and Name the phone's (sas, linked, refused); Code the four-digit
// code (sas); Reason a wire.Refused* value (refused).
type PairEvent struct {
	Kind      string
	URL       string
	ExpiresAt time.Time
	DeviceID  string
	Name      string
	Code      string
	Reason    string
}

// Events is the pairing narration; one reader at a time.
func (c *Center) Events() <-chan PairEvent { return c.events }

func (c *Center) emit(ev PairEvent) {
	select {
	case c.events <- ev:
	default: // no reader keeps up: the sidecar holds the state anyway
	}
}
