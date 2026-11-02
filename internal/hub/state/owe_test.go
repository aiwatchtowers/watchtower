package state

import (
	"context"
	"database/sql"
	"testing"
	"time"
)

// Relay sim rule 16: a lapsed phone's queued relay echoes move, in order and
// written over whatever holds their names, to its CloudKit queue; its other
// relay rows go, and a dropped resend_from forgets its gap.
func TestOweOverMovesEchoesAndDropsTheRest(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	const dev, from, to = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "relay/H/P", "relay/H/*@AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
	if err := s.WithTx(ctx, func(tx *sql.Tx) error {
		if err := LinkDevice(tx, Device{ID: dev, Name: "Phone", Scope: "private", LinkedAt: time.Unix(1_700_000_000, 0)}); err != nil {
			return err
		}
		for _, c := range []Control{
			{Mailbox: to, RecordName: "w0", Kind: "hub_on_relay", Envelope: []byte{0}, Expect: ExpectAbsent},
			{Mailbox: from, RecordName: "w1", Kind: "echo", Envelope: []byte{1}, Expect: ExpectSeq, ExpectSeq: 7},
			{Mailbox: from, RecordName: "w2", Kind: "resend_from", Envelope: []byte{2}, Expect: ExpectAbsent},
			{Mailbox: from, RecordName: "w3", Kind: "transport_switched", Envelope: []byte{3}, Expect: ExpectAbsent},
			{Mailbox: from, RecordName: "w4", Kind: "echo", Envelope: []byte{4}, Expect: ExpectAbsent},
		} {
			if err := Enqueue(tx, c); err != nil {
				return err
			}
		}
		return SetResendRequested(tx, dev, 5)
	}); err != nil {
		t.Fatal(err)
	}
	var moved int64
	if err := s.WithTx(ctx, func(tx *sql.Tx) error {
		var err error
		moved, err = OweOver(tx, dev, from, to, "echo", "resend_from")
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if moved != 2 {
		t.Fatalf("moved %d, want 2", moved)
	}
	if left, _ := s.PendingControls(from); len(left) != 0 {
		t.Fatalf("relay queue left %+v", left)
	}
	got, err := s.PendingControls(to)
	if err != nil || len(got) != 3 {
		t.Fatalf("CloudKit queue %+v %v", got, err)
	}
	for i, want := range []string{"w0", "w1", "w4"} {
		if got[i].RecordName != want {
			t.Fatalf("queue order %+v", got)
		}
	}
	if got[1].Expect != ExpectNone || got[2].Expect != ExpectNone || got[0].Expect != ExpectAbsent {
		t.Fatalf("expects %+v", got)
	}
	if d, _, _ := s.Device(dev); d.ResendRequestedFrom != 0 {
		t.Fatalf("resend_requested_from %d, want 0", d.ResendRequestedFrom)
	}
}

// LapseRelay is a compare-and-set that drops the phone's held actions;
// EndRelayLapse keeps relay_skip_before.
func TestLapseRelayIsACompareAndSet(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	const dev = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
	at := time.Unix(1_700_000_000, 0)
	if err := s.WithTx(ctx, func(tx *sql.Tx) error {
		if err := LinkDevice(tx, Device{ID: dev, Name: "Phone", Scope: "private", LinkedAt: at}); err != nil {
			return err
		}
		return Hold(tx, dev, 3, "w3", []byte{1})
	}); err != nil {
		t.Fatal(err)
	}
	var firsts []bool
	for range 2 {
		if err := s.WithTx(ctx, func(tx *sql.Tx) error {
			first, err := LapseRelay(tx, dev, at)
			firsts = append(firsts, first)
			return err
		}); err != nil {
			t.Fatal(err)
		}
	}
	if !firsts[0] || firsts[1] {
		t.Fatalf("compare-and-set answers %v", firsts)
	}
	if held, _ := s.HeldActions(dev); len(held) != 0 {
		t.Fatalf("held actions left %+v", held)
	}
	if ended, err := s.EndRelayLapse(dev); err != nil || !ended {
		t.Fatalf("end %v %v", ended, err)
	}
	d, _, _ := s.Device(dev)
	if d.RelayLapsedAt != nil || d.RelaySkipBefore == nil || !d.RelaySkipBefore.Equal(at) {
		t.Fatalf("after the end: lapsed %v skip %v", d.RelayLapsedAt, d.RelaySkipBefore)
	}
	if ended, _ := s.EndRelayLapse(dev); ended {
		t.Fatal("ended twice")
	}
}
