package hub

import (
	"context"
	"log"
	"time"

	"watchtower/internal/hub/slices"
)

// The owner's off (go hub plan 3 Task 23 review): turning Mobile off deletes
// the records the hub published, as POLICY-03's wipe does — through the
// running transports before the hub stops (the bridge still up), and while
// the hub stays off, retried from the stopped wipe until nothing published
// is left. Only published records go: linked phones, their keyboxes, the
// mailboxes and the keys stay, so turning on again republishes and the
// phones read on (the Swift hub deleted its zones). Whether the owner's off
// should also unlink phones is the owner's call (ask #956): ownerOff is the
// one place to change.

// OffDelete* are `hub status --json`'s off_delete.state values while the
// owner's switch is off ("" while it is on).
const (
	OffDeleteOK      = "ok"      // nothing the hub published is left
	OffDeletePending = "pending" // published records left, not tried yet
	OffDeleteFailed  = "failed"  // the last try left published records; retried
)

// OffDeleteStatus is `hub status --json`'s "off_delete" block (pinned keys):
// State (OffDelete*, "" while on) and At, the last try (RFC 3339, "" = none
// in this run).
type OffDeleteStatus struct {
	State string `json:"state"`
	At    string `json:"at"`
}

// offWipeRetry spaces the stopped retries of the owner's off wipe; a try
// that leaves records doubles the wait up to offWipeMaxBackoff, so a
// permanently refused record does not start a desktop host's bridge every
// minute (test seams).
var (
	offWipeRetry      = wipeRetry
	offWipeMaxBackoff = time.Hour
)

// ownerOff is what the owner's off does to a running hub: stop it after
// deleting what it published (keepNothing), keeping the phones linked.
func (s *supervisor) ownerOff() {
	s.stopHub(keepNothing)
	now := time.Now()
	s.noteOffDelete(now)
	s.offWipeBackoff = offWipeRetry
	s.nextOffWipe = now.Add(offWipeRetry)
}

// retryOffWipe is the stopped retry while the owner's switch is off: what
// the off (or an earlier run) left published is wiped again, the wait
// doubling while records stay; a failed read is logged once per streak.
func (s *supervisor) retryOffWipe(ctx context.Context) {
	n, err := s.publishedLeft()
	switch {
	case err != nil:
		if !s.offWipeReadLogged {
			s.offWipeReadLogged = true
			log.Printf("hub: off: reading what is left published failed (%s): retried", errClass(err))
		}
	case n > 0:
		s.offWipeReadLogged = false
		s.nextWipe = time.Time{}
		s.wipeStopped(ctx)
		s.noteOffDelete(time.Now())
	default:
		s.offWipeReadLogged = false
	}
	switch {
	case err == nil && n > 0 && s.offDeleteFailed:
		s.offWipeBackoff = min(max(2*s.offWipeBackoff, offWipeRetry), offWipeMaxBackoff)
	default:
		s.offWipeBackoff = offWipeRetry
	}
	s.nextOffWipe = time.Now().Add(s.offWipeBackoff)
}

// keepNothing is the wipe's filter: every published kind goes.
func keepNothing(slices.Kind) bool { return false }

// publishedLeft counts the records the hub has published and not deleted.
func (s *supervisor) publishedLeft() (int, error) {
	recs, err := publishedRecords(s.st, keepNothing)
	return len(recs), err
}

// noteOffDelete records a try of the off wipe at now: whether it left
// anything published.
func (s *supervisor) noteOffDelete(now time.Time) {
	s.offDeleteAt = now
	n, err := s.publishedLeft()
	s.offDeleteFailed = err != nil || n > 0
	if s.offDeleteFailed {
		log.Printf("hub: off: %d published records left: retried while off", n)
	}
}

// offDeleteStatus is the off_delete block for the owner's off.
func (s *supervisor) offDeleteStatus() OffDeleteStatus {
	var st OffDeleteStatus
	if !s.offDeleteAt.IsZero() {
		st.At = s.offDeleteAt.UTC().Format(time.RFC3339)
	}
	n, err := s.publishedLeft()
	switch {
	case err == nil && n == 0:
		st.State = OffDeleteOK
	case s.offDeleteFailed:
		st.State = OffDeleteFailed
	default:
		st.State = OffDeletePending
	}
	return st
}
