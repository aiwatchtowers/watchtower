package actions

import (
	"database/sql"
	"errors"
	"testing"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// One phone's failure in the shared mailbox (a drain error, a re-link
// mid-pass, an error at its record) leaves its records for the next pass and
// never stops the other phone's action from applying in the same pass.
func TestSharedZoneOnePhonesFailureLeavesTheOthersWorking(t *testing.T) {
	for _, tc := range []string{"drain", "relink", "record"} {
		t.Run(tc, func(t *testing.T) {
			w := newWorld(t, kindShared)
			w.byDevice("test_who")
			a, b := w.phone, w.addPhone()
			aID, bID := a.ID().String(), b.ID().String()
			if _, err := a.Act("test_who"); err != nil {
				t.Fatal(err)
			}
			if _, err := b.Act("test_who"); err != nil {
				t.Fatal(err)
			}
			once := true
			w.proc.fault = func(point string) error {
				switch {
				case tc == "drain" && point == "drain "+aID:
					return errors.New("injected drain failure")
				case tc == "relink" && point == "drain "+aID && once:
					once = false
					w.relink(a) // the link changes under the running pass
				case tc == "record" && point == "opened "+aID:
					return errors.New("injected record failure")
				}
				return nil
			}
			r, _ := w.proc.Pass(w.ctx)
			if r.Applied != 1 {
				t.Fatalf("pass %+v", r)
			}
			w.wantCalls(bID + ":1")
			if tok, err := w.st.ZoneToken(w.mailbox); err != nil || tok != 0 {
				t.Fatalf("token %d (%v): A's record must be read again", tok, err)
			}
			w.proc.fault = nil
			for range 10 {
				r := w.pass()
				if w.sync(a)+w.sync(b) == 0 && r.Read+r.ControlsWritten == 0 {
					break
				}
			}
			want := []string{bID + ":1", aID + ":1"}
			if tc == "relink" {
				want = want[:1] // sealed under the old link: no longer A's
			}
			w.wantCalls(want...)
			if e, ok := b.Echoes[1]; !ok || e.Status != wire.StatusApplied {
				t.Fatalf("B's echo %+v", b.Echoes)
			}
		})
	}
}

// A record that keeps failing holds the shared mailbox's token back at most
// MaxRecordStrikes passes: then it is passed over and the other phones'
// records are not read again.
func TestSharedZonePoisonRecordIsPassedOverAfterItsStrikes(t *testing.T) {
	w := newWorld(t, kindShared)
	w.byDevice("test_who")
	a, b := w.phone, w.addPhone()
	aID, bID := a.ID().String(), b.ID().String()
	if _, err := a.Act("test_who"); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Act("test_who"); err != nil {
		t.Fatal(err)
	}
	w.proc.fault = func(point string) error {
		if point == "opened "+aID {
			return errors.New("injected poison")
		}
		return nil
	}
	for i := 1; i <= MaxRecordStrikes; i++ {
		_, _ = w.proc.Pass(w.ctx)
		tok, err := w.st.ZoneToken(w.mailbox)
		if err != nil {
			t.Fatal(err)
		}
		if moved := tok != 0; moved != (i == MaxRecordStrikes) {
			t.Fatalf("pass %d: token %d", i, tok)
		}
	}
	w.wantCalls(bID + ":1")
	if r, _ := w.proc.Pass(w.ctx); r.Read != 0 {
		t.Fatalf("after the strikes the page is read again: %+v", r)
	}
}

// A phone's queued rows follow it when its mailbox changes shape (its own
// zone → the shared RelayZone): written in their order under the new key,
// none left under the old one.
func TestQueuedRowsMoveWithAPhonesMailbox(t *testing.T) {
	w := newWorld(t, kindShared)
	// The same phone as the processor saw it on a per-phone CloudKit zone.
	w.proc.cfg.Transport = w.fake
	boxes, err := w.proc.mailboxes()
	if err != nil || len(boxes) != 1 || boxes[0].shared {
		t.Fatalf("per-phone boxes %+v, %v", boxes, err)
	}
	old := boxes[0]
	for _, from := range []uint64{4, 7} {
		q, err := w.proc.sealResendFrom(old, from)
		if err != nil {
			t.Fatal(err)
		}
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.Enqueue(tx, q.control(old.queue)) }); err != nil {
			t.Fatal(err)
		}
	}
	w.proc.cfg.Transport = w.tr
	if n, _, err := w.proc.FlushControls(w.ctx); err != nil || n != 2 {
		t.Fatalf("flushed %d, %v", n, err)
	}
	for _, key := range []string{old.queue, w.queue(w.phone)} {
		if rows, err := w.st.PendingControls(key); err != nil || len(rows) != 0 {
			t.Fatalf("%d rows left under %q, %v", len(rows), key, err)
		}
	}
	w.sync(w.phone)
	if len(w.phone.Controls) != 2 || *w.phone.Controls[0].Seq != 4 || *w.phone.Controls[1].Seq != 7 {
		t.Fatalf("controls %+v", w.phone.Controls)
	}
}

// The relay path keeps phase 1's per-phone order and isolation: a phone
// whose drain fails has its own mailbox left unread this pass (its token
// stays), the other phone's mailbox is read and applied, and the failed
// phone's action applies once its drain works again.
func TestRelayPhoneFailureStaysWithItsOwnMailbox(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	w.byDevice("test_who")
	a, b := w.phone, w.addPhone()
	aID, bID := a.ID().String(), b.ID().String()
	if _, err := a.Act("test_who"); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Act("test_who"); err != nil {
		t.Fatal(err)
	}
	w.proc.fault = func(point string) error {
		if point == "drain "+aID {
			return errors.New("injected drain failure")
		}
		return nil
	}
	if _, err := w.proc.Pass(w.ctx); err == nil {
		t.Fatal("the drain failure was not reported")
	}
	w.wantCalls(bID + ":1")
	if tok, _ := w.st.ZoneToken(a.Zone()); tok != 0 {
		t.Fatalf("A's mailbox was read: token %d", tok)
	}
	if tok, _ := w.st.ZoneToken(b.Zone()); tok == 0 {
		t.Fatal("B's mailbox was not read")
	}
	w.proc.fault = nil
	w.pass()
	w.wantCalls(bID+":1", aID+":1")
}
