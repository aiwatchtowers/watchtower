package state

import (
	"maps"
	"testing"
	"time"
)

func TestBeginAlertPushRefusesASecondRow(t *testing.T) {
	s := openTest(t)
	t0 := time.Unix(1_800_000_000, 0).UTC()
	if ok, err := s.BeginAlertPush("ask-1", "phone-a", t0); err != nil || !ok {
		t.Fatalf("first BeginAlertPush = %v, %v", ok, err)
	}
	if ok, err := s.BeginAlertPush("ask-1", "phone-a", t0.Add(time.Second)); err != nil || ok {
		t.Fatalf("second BeginAlertPush = %v, %v; want false", ok, err)
	}
	// Settled, it is still refused: a push is never begun twice.
	if _, err := s.SettleAlertPush("ask-1", "phone-a", AlertAccepted, "", 1, t0); err != nil {
		t.Fatal(err)
	}
	if ok, err := s.BeginAlertPush("ask-1", "phone-a", t0.Add(time.Minute)); err != nil || ok {
		t.Fatalf("BeginAlertPush after settle = %v, %v; want false", ok, err)
	}
	// Another phone, or another key, begins.
	begun, err := s.BeginAlertPushes("ask-1", []string{"phone-a", "phone-b"}, t0)
	if err != nil || len(begun) != 1 || begun[0] != "phone-b" {
		t.Fatalf("BeginAlertPushes = %v, %v; want [phone-b]", begun, err)
	}
}

func TestSettleAlertPushSettlesOnlyAPendingRow(t *testing.T) {
	s := openTest(t)
	t0 := time.Unix(1_800_000_000, 0).UTC()
	if _, err := s.BeginAlertPush("ask-1", "phone-a", t0); err != nil {
		t.Fatal(err)
	}
	if ok, err := s.SettleAlertPush("ask-1", "phone-a", AlertAccepted, "", 2, t0.Add(time.Second)); err != nil || !ok {
		t.Fatalf("settle = %v, %v; want changed", ok, err)
	}
	// A later settle (a restart's expiry, a late duplicate) does not rewrite it.
	if ok, err := s.SettleAlertPush("ask-1", "phone-a", AlertExpired, ReasonStopped, 3, t0.Add(2*time.Second)); err != nil || ok {
		t.Fatalf("second settle = %v, %v; want unchanged", ok, err)
	}
	if ok, err := s.SettleAlertPush("ask-9", "phone-a", AlertAccepted, "", 1, t0); err != nil || ok {
		t.Fatalf("settle of a missing row = %v, %v; want unchanged", ok, err)
	}
	got, err := s.LastAlertOutcomes(t0)
	if err != nil || got["phone-a"] != AlertAccepted {
		t.Fatalf("LastAlertOutcomes = %v, %v", got, err)
	}
	// An outcome or reason outside the table's vocabulary is refused.
	if _, err := s.BeginAlertPush("ask-2", "phone-a", t0); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SettleAlertPush("ask-2", "phone-a", "delivered", "", 1, t0); err == nil {
		t.Fatal("unknown outcome accepted")
	}
	if _, err := s.SettleAlertPush("ask-2", "phone-a", AlertExpired, "late", 1, t0); err == nil {
		t.Fatal("unknown reason accepted")
	}
}

func TestExpirePendingAlertPushesAtStart(t *testing.T) {
	s := openTest(t)
	t0 := time.Unix(1_800_000_000, 0).UTC()
	for _, d := range []string{"phone-a", "phone-b"} {
		if _, err := s.BeginAlertPush("ask-1", d, t0); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.SettleAlertPush("ask-1", "phone-b", AlertAccepted, "", 1, t0); err != nil {
		t.Fatal(err)
	}
	n, err := s.ExpirePendingAlertPushes(t0.Add(time.Hour))
	if err != nil || n != 1 {
		t.Fatalf("ExpirePendingAlertPushes = %d, %v; want 1", n, err)
	}
	var outcome, reason string
	if err := s.db.QueryRow(`SELECT outcome, reason FROM alert_pushes WHERE device_id = 'phone-a'`).Scan(&outcome, &reason); err != nil {
		t.Fatal(err)
	}
	if outcome != AlertExpired || reason != ReasonRestart {
		t.Fatalf("pending row settled %s/%s; want expired/restart", outcome, reason)
	}
	if n, _ := s.ExpirePendingAlertPushes(t0.Add(2 * time.Hour)); n != 0 {
		t.Fatalf("second expiry settled %d rows", n)
	}
}

func TestAlertPushReads(t *testing.T) {
	s := openTest(t)
	t0 := time.Unix(1_800_000_000, 0).UTC()
	settle := func(key, dev, outcome, reason string, at time.Time) {
		t.Helper()
		if _, err := s.BeginAlertPush(key, dev, at); err != nil {
			t.Fatal(err)
		}
		if _, err := s.SettleAlertPush(key, dev, outcome, reason, 1, at); err != nil {
			t.Fatal(err)
		}
	}
	settle("ask-1", "phone-a", AlertAccepted, "", t0)
	settle("ask-1", "phone-b", AlertNoToken, "", t0)
	settle("ask-2", "phone-a", AlertExpired, ReasonOverflow, t0.Add(time.Minute))
	settle("ask-2", "phone-b", AlertExpired, ReasonInFlight, t0.Add(time.Minute))
	settle("ask-3", "phone-a", AlertExpired, ReasonOverflow, t0.Add(-time.Hour))
	settle("ask-4", "phone-b", AlertPushOff, "", t0.Add(2*time.Minute))
	if _, err := s.BeginAlertPush("ask-5", "phone-a", t0.Add(3*time.Minute)); err != nil {
		t.Fatal(err)
	}

	if n, err := s.AlertPushOverflows(t0); err != nil || n != 1 {
		t.Fatalf("AlertPushOverflows = %d, %v; want 1", n, err)
	}
	// Accepted, or expired in flight (it may have reached the relay); an
	// overflowed or refused push is not received.
	got, err := s.ReceivedAlertPushes([]string{"ask-1", "ask-2", "ask-9"})
	want := map[string]map[string]bool{"ask-1": {"phone-a": true}, "ask-2": {"phone-b": true}}
	if err != nil || len(got) != 2 || !maps.Equal(got["ask-1"], want["ask-1"]) || !maps.Equal(got["ask-2"], want["ask-2"]) {
		t.Fatalf("ReceivedAlertPushes = %v, %v; want %v", got, err, want)
	}
	// Newest settled outcome per phone; a pending row is no outcome.
	last, err := s.LastAlertOutcomes(t0)
	if err != nil || !maps.Equal(last, map[string]string{"phone-a": AlertExpired, "phone-b": AlertPushOff}) {
		t.Fatalf("LastAlertOutcomes = %v, %v", last, err)
	}

	if err := s.PruneAlertPushes(t0); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := s.db.QueryRow(`SELECT count(*) FROM alert_pushes`).Scan(&n); err != nil || n != 6 {
		t.Fatalf("after prune %d rows (%v); want 6 (the one before t0 gone)", n, err)
	}
}
