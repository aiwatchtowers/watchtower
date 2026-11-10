package actions

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/secure"
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
				case tc == "record" && strings.HasPrefix(point, "opened "+aID):
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

// advance moves the world's clock on by d.
func (w *world) advance(d time.Duration) {
	w.mu.Lock()
	w.now = w.now.Add(d)
	w.mu.Unlock()
}

// A store or transport error at a record is never a strike: however many
// passes (nudges) and however long, the record is read again until it
// works, and then applies once.
func TestSharedZoneTransientErrorIsNeverPassedOver(t *testing.T) {
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
		if strings.HasPrefix(point, "opened "+aID) {
			return errors.New("database is locked")
		}
		return nil
	}
	for range 3 * MaxRecordStrikes { // quick nudges, then well past the window
		_, _ = w.proc.Pass(w.ctx)
		_, _ = w.proc.Pass(w.ctx)
		w.advance(StrikeWindow / 2)
	}
	if tok, err := w.st.ZoneToken(w.mailbox); err != nil || tok != 0 {
		t.Fatalf("token %d (%v): A's record was passed over", tok, err)
	}
	w.wantCalls(bID + ":1")
	w.proc.fault = nil
	w.pass()
	w.wantCalls(bID+":1", aID+":1")
}

// A record whose content fails is passed over only after MaxRecordStrikes
// failures spread over StrikeWindow; the phone's record behind it is not
// attempted (and not struck) until then, and applies right after.
func TestSharedZoneContentErrorIsPassedOverAfterTheTimeFloor(t *testing.T) {
	w := newWorld(t, kindShared)
	a, b := w.phone, w.addPhone()
	aID := a.ID().String()
	bad, behind := a.NewAction("test_noop"), a.NewAction("test_noop")
	badName, err := a.SendLegacy(bad)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.SendLegacy(behind); err != nil {
		t.Fatal(err)
	}
	seq, err := b.Act("test_noop")
	if err != nil {
		t.Fatal(err)
	}
	w.proc.fault = func(point string) error {
		if point == "opened "+aID+" "+badName {
			return fmt.Errorf("sealing its echo: %w", secure.ErrOversized)
		}
		return nil
	}
	for range 2 * MaxRecordStrikes { // many quick nudges: under the time floor
		_, _ = w.proc.Pass(w.ctx)
	}
	if tok, _ := w.st.ZoneToken(w.mailbox); tok != 0 {
		t.Fatalf("passed over before the time floor: token %d", tok)
	}
	w.wantCalls(noops(seq)...)
	w.advance(StrikeWindow)
	if _, err := w.proc.Pass(w.ctx); err != nil {
		t.Fatalf("pass: %v", err)
	}
	w.wantCalls("test_noop:"+strconv.FormatUint(seq, 10), "test_noop:action-"+behind.ID)
	if tok, _ := w.st.ZoneToken(w.mailbox); tok == 0 {
		t.Fatal("the token did not move past the passed-over record")
	}
	if len(w.proc.strikes) != 0 {
		t.Fatalf("strikes left after the page: %d", len(w.proc.strikes))
	}
}

// A record that works clears its strikes at once; the strike table is capped.
func TestStrikesAreForgottenAndCapped(t *testing.T) {
	w := newWorld(t, kindShared)
	content := fmt.Errorf("x: %w", secure.ErrOversized)
	rec := transport.Stored{Name: "n", RecordSeq: 1}
	w.proc.strike("z", rec, content)
	w.proc.forget("z", rec)
	if len(w.proc.strikes) != 0 {
		t.Fatalf("strikes %v", w.proc.strikes)
	}
	for i := range maxStrikeRecords + 10 {
		w.advance(time.Second)
		w.proc.strike("z", transport.Stored{Name: "n", RecordSeq: uint64(i)}, content)
	}
	if len(w.proc.strikes) != maxStrikeRecords {
		t.Fatalf("%d strike entries, cap %d", len(w.proc.strikes), maxStrikeRecords)
	}
	if _, ok := w.proc.strikes[strikeKey("z", transport.Stored{Name: "n", RecordSeq: 0})]; ok {
		t.Fatal("the oldest entry was kept")
	}
	if !contentError(content) || contentError(errors.New("database is locked")) || contentError(transport.ErrUnavailable) {
		t.Fatal("contentError classes")
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
