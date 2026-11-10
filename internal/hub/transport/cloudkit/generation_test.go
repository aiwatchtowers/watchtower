package cloudkit_test

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
)

// changesSince counts the Changes frames the bridge got with this cursor.
func (r *rig) changesSince(zone string, since uint64) int {
	n := 0
	for _, q := range r.requests() {
		if c := q.GetChanges(); c != nil && c.GetZone() == zone && c.GetSince() == since {
			n++
		}
	}
	return n
}

// loseState is the bridge losing bridge.db, once the client saw its
// connection drop.
func (r *rig) loseState() {
	r.t.Helper()
	r.fake.LoseState()
	r.nextEvent("connection lost", func(e transport.Event) bool { return errors.Is(e.Err, transport.ErrUnavailable) })
}

// fillData writes n phone-shaped records into the data zone behind the
// bridge (the feed moves past an old cursor).
func (r *rig) fillData(n int) {
	r.t.Helper()
	for i := range n {
		if _, err := r.fake.PhoneRecords(r.hub).Write(dataZone, "rec-"+string(rune('a'+i)), []byte("env"), transport.Expect{}); err != nil {
			r.t.Fatal(err)
		}
	}
}

// TestLostBridgeStateResetsNotSkips: the bridge lost bridge.db (a new
// generation, cursors restarting): a cursor of the old generation is
// ErrTokenExpired — never read against the new feed, where it would skip
// records silently — and the read from 0 is a Reset with every record. The
// zone stops pending only when the consumer comes back with a new cursor;
// after that a restart keeps the cursors.
func TestLostBridgeStateResetsNotSkips(t *testing.T) {
	r := newRig(t)
	r.fillData(3)
	b, err := r.c.Changes(r.ctx, dataZone, 0)
	if err != nil || len(b.Changed) != 3 {
		t.Fatalf("before: %+v, %v", b, err)
	}
	cursor := b.NewSeq
	r.loseState()
	r.fillData(5) // the new feed's counter passes the old cursor
	ck := cloudkit.DataZoneName(r.hub)
	before := r.changesSince(ck, cursor)
	if _, err := r.c.Changes(r.ctx, dataZone, cursor); !errors.Is(err, transport.ErrTokenExpired) {
		t.Fatalf("old cursor after the loss: %v, want ErrTokenExpired", err)
	}
	if r.changesSince(ck, cursor) != before {
		t.Fatal("an old-generation cursor was sent to the bridge")
	}
	if st := r.storedGeneration(); st.Generation != r.fake.Generation() || len(st.Pending) != 2 {
		t.Fatalf("stored %+v, want the new generation with both zones pending", st)
	}
	b, err = r.c.Changes(r.ctx, dataZone, 0)
	if err != nil || !b.Reset || len(b.Changed) != 5 {
		t.Fatalf("read from 0: %+v, %v", b, err)
	}
	if next, err := r.c.Changes(r.ctx, dataZone, b.NewSeq); err != nil || len(next.Changed) != 0 {
		t.Fatalf("the new generation's cursor: %+v, %v", next, err)
	}
	if st := r.storedGeneration(); len(st.Pending) != 1 || st.Pending[0] != cloudkit.RelayZoneName(r.hub) {
		t.Fatalf("stored %+v, want only the relay zone pending", st)
	}
	_ = r.c.Close()
	r.c = cloudkit.New(cloudkit.Config{Dir: r.dir, HubID: r.hub, RelayID: relayID})
	if _, err := r.c.Changes(r.ctx, dataZone, b.NewSeq); err != nil {
		t.Fatalf("a rebased zone's cursor after a restart: %v", err)
	}
}

// TestRestartBeforeTheResetStillRefusesOldState: the client saw the new
// generation (and even read from 0) but the hub stopped before it came back
// with a new cursor — its stored state may still be the old one. After the
// restart the old cursors and tags are refused, as they were before it.
func TestRestartBeforeTheResetStillRefusesOldState(t *testing.T) {
	r := newRig(t)
	r.fillData(3)
	b, err := r.c.Changes(r.ctx, dataZone, 0)
	if err != nil {
		t.Fatal(err)
	}
	cursor := b.NewSeq
	tag := r.save(transport.SaveItem{Record: r.data("workbench-1", []byte(`{"v":1}`))})[0].RecordSeq
	r.loseState()
	r.fillData(6)
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err != nil { // seen, read, not committed
		t.Fatal(err)
	}
	_ = r.c.Close() // the crash
	r.c = cloudkit.New(cloudkit.Config{Dir: r.dir, HubID: r.hub, RelayID: relayID})
	if _, err := r.c.Changes(r.ctx, dataZone, cursor); !errors.Is(err, transport.ErrTokenExpired) {
		t.Fatalf("old cursor after the restart: %v, want ErrTokenExpired", err)
	}
	o := r.save(transport.SaveItem{Record: r.data("workbench-1", []byte(`{"v":2}`)), Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: tag}})[0]
	if !errors.Is(o.Refused, cloudkit.ErrStaleTag) {
		t.Fatalf("old tag after the restart: %+v", o)
	}
}

// TestMissingGenerationFileIsARebase: with no GenerationFile (an upgrade, a
// deleted file) nothing says which generation the stored cursors are of, so
// they are refused until the zone is read again from 0.
func TestMissingGenerationFileIsARebase(t *testing.T) {
	r := newRig(t)
	r.fillData(3)
	b, err := r.c.Changes(r.ctx, dataZone, 0)
	if err != nil {
		t.Fatal(err)
	}
	_ = r.c.Close()
	if err := os.Remove(filepath.Join(r.dir, cloudkit.GenerationFile)); err != nil {
		t.Fatal(err)
	}
	r.c = cloudkit.New(cloudkit.Config{Dir: r.dir, HubID: r.hub, RelayID: relayID})
	if _, err := r.c.Changes(r.ctx, dataZone, b.NewSeq); !errors.Is(err, transport.ErrTokenExpired) {
		t.Fatalf("a stored cursor without the file: %v, want ErrTokenExpired", err)
	}
	fi, err := os.Stat(filepath.Join(r.dir, cloudkit.GenerationFile))
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("the file was not written 0600: %v", err)
	}
	// An existing file of a looser mode is tightened.
	if err := os.Chmod(filepath.Join(r.dir, cloudkit.GenerationFile), 0o644); err != nil {
		t.Fatal(err)
	}
	_ = r.c.Close()
	r.c = cloudkit.New(cloudkit.Config{Dir: r.dir, HubID: r.hub, RelayID: relayID})
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(filepath.Join(r.dir, cloudkit.GenerationFile)); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode().Perm())
	}
}

func (r *rig) storedGeneration() (st struct {
	Generation string   `json:"generation"`
	Pending    []string `json:"pending"`
}) {
	r.t.Helper()
	b, err := os.ReadFile(filepath.Join(r.dir, cloudkit.GenerationFile))
	if err != nil {
		r.t.Fatal(err)
	}
	if err := json.Unmarshal(b, &st); err != nil {
		r.t.Fatal(err)
	}
	return st
}

// TestConditionalWriteWithAnOldGenerationTagIsRefused: a tag_seq handed out
// before the bridge lost its state is refused per item (ErrStaleTag, an
// ErrTokenExpired) and never sent; a tag of the new generation works.
func TestConditionalWriteWithAnOldGenerationTagIsRefused(t *testing.T) {
	r := newRig(t)
	old := r.save(transport.SaveItem{Record: r.data("workbench-1", []byte(`{"v":1}`))})[0]
	r.loseState()
	saves := len(r.requests())
	o := r.save(transport.SaveItem{Record: r.data("workbench-1", []byte(`{"v":2}`)), Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: old.RecordSeq}})[0]
	if o.Saved || !errors.Is(o.Refused, cloudkit.ErrStaleTag) || !errors.Is(o.Refused, transport.ErrTokenExpired) {
		t.Fatalf("old tag: %+v", o)
	}
	for _, q := range r.requests()[saves:] {
		if q.GetSave() != nil {
			t.Fatal("an old-generation tag was sent to the bridge")
		}
	}
	name := r.data("workbench-1", nil).WireName()
	del, err := r.c.Delete(r.ctx, dataZone, []transport.DeleteItem{{Name: name, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: old.RecordSeq}}})
	if err != nil || !errors.Is(del[0].Refused, cloudkit.ErrStaleTag) {
		t.Fatalf("delete on an old tag: %+v, %v", del, err)
	}
	fresh := r.save(transport.SaveItem{Record: r.data("workbench-1", []byte(`{"v":3}`)), Expect: transport.Expect{Mode: transport.ExpectAbsent}})[0]
	if !fresh.Saved {
		t.Fatalf("absent in the new generation: %+v", fresh)
	}
	again := r.save(transport.SaveItem{Record: r.data("workbench-1", []byte(`{"v":4}`)), Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: fresh.RecordSeq}})[0]
	if !again.Saved {
		t.Fatalf("a new-generation tag: %+v", again)
	}
	if e := r.lastSave().GetItems()[0].GetExpect(); e.GetGeneration() != r.fake.Generation() {
		t.Fatalf("the tag went out with generation %q", e.GetGeneration())
	}
}

func TestQuotaOnTheMailboxIsTheMailboxQuota(t *testing.T) {
	r := newRig(t)
	r.fake.FailNext("changes", "quota")
	if _, err := r.c.Changes(r.ctx, mailbox, 0); !errors.Is(err, transport.ErrMailboxQuota) || errors.Is(err, transport.ErrHubQuota) {
		t.Fatalf("mailbox: %v", err)
	}
	r.fake.FailNext("changes", "quota")
	if _, err := r.c.Changes(r.ctx, dataZone, 0); !errors.Is(err, transport.ErrHubQuota) || errors.Is(err, transport.ErrMailboxQuota) {
		t.Fatalf("data: %v", err)
	}
	r.fake.FailNext("delete", "quota")
	if _, err := r.c.Delete(r.ctx, mailbox, []transport.DeleteItem{{Name: "x"}}); !errors.Is(err, transport.ErrMailboxQuota) {
		t.Fatalf("mailbox delete: %v", err)
	}
}

// TestEventQueueFoldsWhileNobodyReads: with the consumer away, a flood of
// error events of two classes and pull_nows past the channel's buffer
// leaves the queue bounded — one waiting event per class, the latest kept.
func TestEventQueueFoldsWhileNobodyReads(t *testing.T) {
	r := newRig(t)
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err != nil {
		t.Fatal(err)
	}
	for range 400 {
		r.fake.SendError("unavailable")
		r.fake.SendError("rate_limited")
		r.fake.PullNow()
	}
	r.fake.SendError("forbidden") // the sentinel: the last event, a class of its own
	// An answer after them: the reader has handled every event frame.
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err != nil {
		t.Fatal(err)
	}
	var got []transport.Event
	deadline := time.After(10 * time.Second)
	for len(got) == 0 || !errors.Is(got[len(got)-1].Err, transport.ErrForbidden) {
		select {
		case e := <-r.c.Events():
			got = append(got, e)
		case <-deadline:
			t.Fatalf("no sentinel after %d events", len(got))
		}
	}
	// The buffer, the one the pump held, and one waiting per class (four
	// classes with the sentinel's).
	if len(got) < 256 || len(got) > 256+1+4 {
		t.Fatalf("%d events delivered, want the buffer and at most one waiting per class", len(got))
	}
	var unavailable, rate, pull int
	for _, e := range got[256 : len(got)-1] {
		switch {
		case errors.Is(e.Err, transport.ErrUnavailable):
			unavailable++
		case errors.Is(e.Err, transport.ErrRateLimited):
			rate++
		case e.PullNow:
			pull++
		}
	}
	if unavailable < 1 || rate < 1 || pull < 1 || unavailable+rate+pull > 4 {
		t.Fatalf("waiting events: %d unavailable, %d rate_limited, %d pull_now; want one each", unavailable, rate, pull)
	}
}
