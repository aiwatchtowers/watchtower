package hub

import (
	"errors"
	"slices"
	"testing"
	"time"

	hubslices "watchtower/internal/hub/slices"
)

// scriptedAway answers the queued states in order (an error for errAway).
type scriptedAway struct{ states []string }

var errAway = errors.New("console unreadable")

func (s *scriptedAway) Away() (bool, error) {
	next := s.states[0]
	s.states = s.states[1:]
	if next == "err" {
		return false, errAway
	}
	return next == "away", nil
}

// The owner leaving the Mac nudges the work alerts at once; coming back, a
// failed read and the first read (learning the state) nudge nothing, and
// nothing is read while no phone is linked.
// twin of FastLaneTests.testGoingAwayNudgesTheWorkAlerts
func TestGoingAwayNudgesTheWorkAlerts(t *testing.T) {
	src := &scriptedAway{states: []string{"away", "here", "away", "away", "err", "here", "away", "away"}}
	linked := true
	nudges := 0
	w := &awayWatch{away: src, active: func() bool { return linked }, nudge: func() { nudges++ }}

	want := []int{0, 0, 1, 1, 1, 1, 2}
	for i, n := range want {
		w.check()
		if nudges != n {
			t.Fatalf("read %d: %d nudges, want %d", i+1, nudges, n)
		}
	}
	linked = false
	w.check()
	if len(src.states) != 1 {
		t.Fatal("the console was read with no phone linked")
	}
	linked = true
	w.check() // learns "away" again after the link: no nudge
	if nudges != 2 {
		t.Fatalf("%d nudges after a relink", nudges)
	}
	if !slices.Contains(hubslices.UrgentKinds, hubslices.KindAskAlert) {
		t.Fatal("the work alerts are no urgent kind: the publisher would not keep the nudge")
	}
}

// An admitted contact is the heartbeat's phone contact; an earlier time
// never lowers it.
// twin of RelayProcessorTests.testADeviceRecordStampsItsSeenAtAndNeverALaterTime (the never-lower half)
func TestAnOlderContactNeverLowersTheStamp(t *testing.T) {
	h := &hubRuntime{}
	at := time.Unix(1_800_000_000, 0)
	h.noteContact(at)
	h.noteContact(at.Add(-time.Minute))
	if got := h.phoneContact(); !got.Equal(at) {
		t.Fatalf("contact %v, want %v", got, at)
	}
}
