package memfake

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
)

// testKeys is a throwaway KeySource with fresh random keys; the fake never
// opens an envelope, so only the Sealer needs it.
type testKeys struct {
	sig        ed25519.PrivateKey
	kx         *ecdh.PrivateKey
	data, meta []byte
	seq        uint64
}

func newTestKeys(t *testing.T) *testKeys {
	t.Helper()
	_, sig, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	k := &testKeys{sig: sig, kx: kx, data: make([]byte, 32), meta: make([]byte, 32)}
	_, _ = rand.Read(k.data)
	_, _ = rand.Read(k.meta)
	return k
}

func (k *testKeys) HubID() secure.ID                   { return secure.ID{0xa, 0xb} }
func (k *testKeys) CurrentEpoch() (uint32, error)      { return 1, nil }
func (k *testKeys) NextSeq() (uint64, error)           { k.seq++; return k.seq, nil }
func (k *testKeys) DataKey(uint32) ([]byte, error)     { return bytes.Clone(k.data), nil }
func (k *testKeys) AlertKey(uint32) ([]byte, error)    { return bytes.Clone(k.data), nil }
func (k *testKeys) MetaKey() ([]byte, error)           { return bytes.Clone(k.meta), nil }
func (k *testKeys) RelayDevices() ([]secure.ID, error) { return nil, nil }
func (k *testKeys) Signer() ed25519.PrivateKey         { return k.sig }
func (k *testKeys) Agreement() *ecdh.PrivateKey        { return k.kx }
func (k *testKeys) AcceptsRelayEpoch(uint32, secure.ID) (bool, error) {
	return false, nil
}
func (k *testKeys) RelayKey(secure.Direction, secure.ID, uint32) ([]byte, error) {
	return nil, errors.New("no relay keys")
}
func (k *testKeys) KeyboxRecipient(secure.ID) (*ecdh.PublicKey, error) {
	return nil, errors.New("no devices")
}

var (
	kinds  = []transport.Kind{transport.KindRelay, transport.KindCloudKit}
	zone   = transport.DataZone("0A0B0000-0000-0000-0000-000000000000")
	box    = transport.MailboxZone("0A0B0000-0000-0000-0000-000000000000", "0C0D0000-0000-0000-0000-000000000000")
	fixed  = time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)
	clock  = func() time.Time { return fixed }
	absent = transport.Expect{Mode: transport.ExpectAbsent}
)

func seq(s uint64) transport.Expect { return transport.Expect{Mode: transport.ExpectSeq, Seq: s} }

func eachKind(t *testing.T, fn func(t *testing.T, f *Fake, s *secure.Sealer)) {
	t.Helper()
	for _, k := range kinds {
		t.Run(string(k), func(t *testing.T) { fn(t, New(k, clock), secure.NewSealer(newTestKeys(t))) })
	}
}

func seal(t *testing.T, s *secure.Sealer, plain, payload string) secure.Record {
	t.Helper()
	r, err := s.Data(zone, plain, "", []byte(payload), nil, "")
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func saveOne(t *testing.T, f *Fake, r secure.Record, e transport.Expect) transport.Outcome {
	t.Helper()
	out, err := f.Save(context.Background(), []transport.SaveItem{{Record: r, Expect: e}})
	if err != nil || len(out) != 1 {
		t.Fatalf("save: %v, %d outcomes", err, len(out))
	}
	return out[0]
}

func changes(t *testing.T, f *Fake, z string, since uint64) transport.Batch {
	t.Helper()
	b, err := f.Changes(context.Background(), z, since)
	if err != nil {
		t.Fatalf("changes(%s, %d): %v", z, since, err)
	}
	return b
}

func drainEvents(f *Fake) []transport.Event {
	var got []transport.Event
	for {
		select {
		case e := <-f.Events():
			got = append(got, e)
		default:
			return got
		}
	}
}

// Review Focus 1: an unsealed Record never reaches the store.
func TestMemfake_RefusesUnsealedRecord(t *testing.T) {
	eachKind(t, func(t *testing.T, f *Fake, s *secure.Sealer) {
		_, err := f.Save(context.Background(), []transport.SaveItem{{Record: secure.Record{}}})
		if !errors.Is(err, secure.ErrUnsealed) {
			t.Fatalf("zero Record: %v, want ErrUnsealed", err)
		}
		// One unsealed item refuses the whole call: the sealed one is not written either.
		good := seal(t, s, "target-1", `{}`)
		_, err = f.Save(context.Background(), []transport.SaveItem{{Record: good}, {Record: secure.Record{}}})
		if !errors.Is(err, secure.ErrUnsealed) {
			t.Fatalf("mixed batch: %v, want ErrUnsealed", err)
		}
		// Refused before any I/O: even an unreachable transport answers ErrUnsealed.
		f.SetAvailable(false)
		if _, err := f.Save(context.Background(), []transport.SaveItem{{Record: secure.Record{}}}); !errors.Is(err, secure.ErrUnsealed) {
			t.Fatalf("unavailable: %v, want ErrUnsealed", err)
		}
		f.SetAvailable(true)
		if n := len(f.Frames()); n != 0 {
			t.Errorf("Frames() = %d frames, want none", n)
		}
		if b := changes(t, f, zone, 0); len(b.Changed)+len(b.Deleted) != 0 || b.NewSeq != 0 {
			t.Errorf("zone changed: %+v", b)
		}
		if ev := drainEvents(f); len(ev) != 0 {
			t.Errorf("events: %+v", ev)
		}
	})
}

func TestMemfake_ExpectAbsentConflictReturnsCurrent(t *testing.T) {
	eachKind(t, func(t *testing.T, f *Fake, s *secure.Sealer) {
		first := seal(t, s, "target-1", `{"v":1}`)
		o := saveOne(t, f, first, absent)
		if !o.Saved || o.RecordSeq == 0 || o.Conflict != nil || o.Refused != nil {
			t.Fatalf("first save: %+v", o)
		}
		o2 := saveOne(t, f, seal(t, s, "target-1", `{"v":2}`), absent)
		if o2.Saved || o2.Refused != nil || o2.Conflict == nil {
			t.Fatalf("second save: %+v", o2)
		}
		c := o2.Conflict
		if !bytes.Equal(c.Envelope, first.Envelope()) || c.RecordSeq != o.RecordSeq || c.Zone != zone ||
			c.Name != first.WireName() || !c.ServerAt.Equal(fixed) {
			t.Errorf("conflict is not the current record: %+v", c)
		}
		// A tombstone counts as absent.
		del, err := f.Delete(context.Background(), zone, []transport.DeleteItem{{Name: first.WireName()}})
		if err != nil || !del[0].Saved {
			t.Fatalf("delete: %+v, %v", del, err)
		}
		if o3 := saveOne(t, f, seal(t, s, "target-1", `{"v":3}`), absent); !o3.Saved {
			t.Errorf("save over a tombstone: %+v", o3)
		}
	})
}

func TestMemfake_ExpectSeqOverwrite(t *testing.T) {
	eachKind(t, func(t *testing.T, f *Fake, s *secure.Sealer) {
		o := saveOne(t, f, seal(t, s, "target-1", `{"v":1}`), absent)
		second := seal(t, s, "target-1", `{"v":2}`)
		o2 := saveOne(t, f, second, seq(o.RecordSeq))
		if !o2.Saved || o2.RecordSeq == o.RecordSeq {
			t.Fatalf("overwrite: %+v (was %d)", o2, o.RecordSeq)
		}
		// A stale seq conflicts with the current record.
		o3 := saveOne(t, f, seal(t, s, "target-1", `{"v":3}`), seq(o.RecordSeq))
		if o3.Saved || o3.Conflict == nil || o3.Conflict.RecordSeq != o2.RecordSeq || !bytes.Equal(o3.Conflict.Envelope, second.Envelope()) {
			t.Fatalf("stale overwrite: %+v", o3)
		}
		// ExpectSeq on an absent record conflicts with no current record.
		o4 := saveOne(t, f, seal(t, s, "target-2", `{}`), seq(o2.RecordSeq))
		if o4.Saved || o4.Conflict != nil || o4.Refused != nil {
			t.Fatalf("expect seq on absent: %+v", o4)
		}
		// An unconditional save overwrites.
		if o5 := saveOne(t, f, seal(t, s, "target-1", `{"v":5}`), transport.Expect{}); !o5.Saved {
			t.Fatalf("unconditional: %+v", o5)
		}
		b := changes(t, f, zone, 0)
		if len(b.Changed) != 1 || b.Changed[0].Name != second.WireName() {
			t.Fatalf("last version only: %+v", b)
		}
		cur := b.Changed[0].RecordSeq

		// Conditional deletes: stale → conflict, current → deleted.
		del, err := f.Delete(context.Background(), zone, []transport.DeleteItem{
			{Name: second.WireName(), Expect: seq(o2.RecordSeq)},
			{Name: second.WireName(), Expect: seq(cur)},
			{Name: "never-written"},
		})
		if err != nil || len(del) != 3 {
			t.Fatalf("delete: %v, %+v", err, del)
		}
		if del[0].Saved || del[0].Conflict == nil || del[0].Conflict.RecordSeq != cur {
			t.Errorf("stale delete: %+v", del[0])
		}
		if !del[1].Saved {
			t.Errorf("current delete: %+v", del[1])
		}
		if !del[2].Saved || del[2].RecordSeq != 0 {
			t.Errorf("delete of an absent record: %+v", del[2])
		}
		if b := changes(t, f, zone, 0); len(b.Changed) != 0 || len(b.Deleted) != 1 || b.Deleted[0] != second.WireName() {
			t.Errorf("after delete: %+v", b)
		}
	})
}

func TestMemfake_ChangesPagesWithMore(t *testing.T) {
	for _, k := range kinds {
		t.Run(string(k), func(t *testing.T) {
			f := New(k, clock)
			const n = 450
			for i := range n {
				if o, err := f.Write(box, fmt.Sprintf("r-%03d", i), []byte{byte(i)}, absent); err != nil || !o.Saved {
					t.Fatalf("write %d: %+v, %v", i, o, err)
				}
			}
			// Deletes join the feed in change order; a rewrite moves a record to the end.
			if _, err := f.Delete(context.Background(), box, []transport.DeleteItem{{Name: "r-000"}, {Name: "r-001"}}); err != nil {
				t.Fatal(err)
			}
			if _, err := f.Write(box, "r-002", []byte("new"), transport.Expect{}); err != nil {
				t.Fatal(err)
			}
			var pages []transport.Batch
			since := uint64(0)
			for {
				b := changes(t, f, box, since)
				pages = append(pages, b)
				if b.NewSeq <= since && b.More {
					t.Fatalf("cursor did not move: %d → %d", since, b.NewSeq)
				}
				since = b.NewSeq
				if !b.More {
					break
				}
				if len(pages) > 10 {
					t.Fatal("no end")
				}
			}
			if len(pages) != 3 {
				t.Fatalf("%d pages, want 3", len(pages))
			}
			for i, p := range pages[:2] {
				if got := len(p.Changed) + len(p.Deleted); got != PageLimit {
					t.Errorf("page %d holds %d, want %d", i, got, PageLimit)
				}
			}
			live := map[string][]byte{}
			var deleted []string
			for _, p := range pages {
				for _, c := range p.Changed {
					live[c.Name] = c.Envelope
				}
				deleted = append(deleted, p.Deleted...)
			}
			if len(live) != n-2 || len(deleted) != 2 || string(live["r-002"]) != "new" {
				t.Errorf("live %d, deleted %v, r-002 %q", len(live), deleted, live["r-002"])
			}
			last := pages[2]
			if c := last.Changed[len(last.Changed)-1]; c.Name != "r-002" {
				t.Errorf("rewrite not last in the feed: %s", c.Name)
			}
			if b := changes(t, f, box, since); len(b.Changed)+len(b.Deleted) != 0 || b.More || b.NewSeq != since {
				t.Errorf("caught up: %+v", b)
			}
		})
	}
}

// Review Focus 3's tool: an expired cursor answers ErrTokenExpired until the
// caller resyncs from 0; purged tombstones are gone from the resync.
func TestMemfake_TokenExpired(t *testing.T) {
	for _, k := range kinds {
		t.Run(string(k), func(t *testing.T) {
			f := New(k, clock)
			for i := range 5 {
				if _, err := f.Write(box, fmt.Sprintf("a-%d", i), []byte("x"), absent); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := f.Delete(context.Background(), box, []transport.DeleteItem{{Name: "a-0"}}); err != nil {
				t.Fatal(err)
			}
			if _, err := f.Write(box, "a-5", []byte("x"), absent); err != nil {
				t.Fatal(err)
			}
			head := changes(t, f, box, 0).NewSeq // 7 changes: the tombstone of a-0 is below head
			f.ExpireBefore(box, head)
			for _, since := range []uint64{1, head - 1} {
				if _, err := f.Changes(context.Background(), box, since); !errors.Is(err, transport.ErrTokenExpired) {
					t.Errorf("since %d: %v, want ErrTokenExpired", since, err)
				}
			}
			// It stays expired: the next pull from the stale cursor fails again.
			if _, err := f.Changes(context.Background(), box, 1); !errors.Is(err, transport.ErrTokenExpired) {
				t.Errorf("second pull: %v", err)
			}
			// A cursor this zone never issued is expired too.
			if _, err := f.Changes(context.Background(), box, head+5); !errors.Is(err, transport.ErrTokenExpired) {
				t.Errorf("unissued cursor: %v", err)
			}
			b := changes(t, f, box, 0)
			if len(b.Changed) != 5 || len(b.Deleted) != 0 || b.NewSeq != head {
				t.Errorf("resync from 0: %d changed, deleted %v, new %d (head %d)", len(b.Changed), b.Deleted, b.NewSeq, head)
			}
			if b := changes(t, f, box, head); len(b.Changed) != 0 {
				t.Errorf("from head: %+v", b)
			}
			// Other zones are untouched.
			if _, err := f.Changes(context.Background(), zone, 0); err != nil {
				t.Errorf("other zone: %v", err)
			}
		})
	}
}

func TestMemfake_EventOnWrite(t *testing.T) {
	eachKind(t, func(t *testing.T, f *Fake, s *secure.Sealer) {
		if _, err := f.Write(box, "a-1", []byte("x"), absent); err != nil {
			t.Fatal(err)
		}
		if ev := drainEvents(f); len(ev) != 1 || ev[0].Zone != box || ev[0].Control != nil || ev[0].Err != nil {
			t.Fatalf("phone write: %+v", ev)
		}
		r := seal(t, s, "target-1", `{}`)
		o := saveOne(t, f, r, absent)
		if ev := drainEvents(f); len(ev) != 1 || ev[0].Zone != zone {
			t.Fatalf("hub save: %+v", ev)
		}
		// A failed precondition changes nothing and says nothing.
		saveOne(t, f, r, absent)
		if _, err := f.Write(box, "a-1", []byte("y"), absent); err != nil {
			t.Fatal(err)
		}
		if ev := drainEvents(f); len(ev) != 0 {
			t.Fatalf("conflicts: %+v", ev)
		}
		if _, err := f.Delete(context.Background(), zone, []transport.DeleteItem{{Name: r.WireName(), Expect: seq(o.RecordSeq)}}); err != nil {
			t.Fatal(err)
		}
		if ev := drainEvents(f); len(ev) != 1 || ev[0].Zone != zone {
			t.Fatalf("delete: %+v", ev)
		}
		f.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.PairingOpened, Detail: "slot-1"}})
		if ev := drainEvents(f); len(ev) != 1 || ev[0].Control == nil || ev[0].Control.Kind != transport.PairingOpened || ev[0].Control.Detail != "slot-1" {
			t.Fatalf("control: %+v", ev)
		}
	})
}

// The relay's RecordSeq is the zone's change counter; CloudKit's stands for an
// opaque change tag that never lines up with the Changes cursor.
func TestMemfake_RecordSeqShape(t *testing.T) {
	f := New(transport.KindRelay, clock)
	o, _ := f.Write(box, "a-1", []byte("x"), absent)
	o2, _ := f.Write(box, "a-2", []byte("x"), absent)
	if o.RecordSeq != 1 || o2.RecordSeq != 2 || changes(t, f, box, 0).NewSeq != 2 {
		t.Errorf("relay: record_seq %d, %d", o.RecordSeq, o2.RecordSeq)
	}
	if f.Kind() != transport.KindRelay {
		t.Errorf("kind %s", f.Kind())
	}

	ck := New(transport.KindCloudKit, clock)
	seen := map[uint64]bool{}
	for i := range 20 {
		o, err := ck.Write(box, "a-1", []byte{byte(i)}, transport.Expect{})
		if err != nil || !o.Saved || o.RecordSeq == 0 {
			t.Fatalf("write %d: %+v, %v", i, o, err)
		}
		if seen[o.RecordSeq] || o.RecordSeq <= 20 {
			t.Errorf("tag %d repeats or looks like a zone counter", o.RecordSeq)
		}
		seen[o.RecordSeq] = true
	}
	if b := changes(t, ck, box, 0); b.NewSeq != 20 || b.Changed[0].RecordSeq == b.NewSeq {
		t.Errorf("cloudkit cursor %d, tag %d", b.NewSeq, b.Changed[0].RecordSeq)
	}
	if ck.Kind() != transport.KindCloudKit {
		t.Errorf("kind %s", ck.Kind())
	}
}

func TestMemfake_FailuresWriteNothing(t *testing.T) {
	eachKind(t, func(t *testing.T, f *Fake, s *secure.Sealer) {
		ctx := context.Background()
		r := seal(t, s, "target-1", `{}`)
		f.FailNext("save", transport.ErrUnavailable)
		f.FailNext("save", transport.ErrRateLimited)
		if _, err := f.Save(ctx, []transport.SaveItem{{Record: r}}); !errors.Is(err, transport.ErrUnavailable) {
			t.Fatalf("first: %v", err)
		}
		if _, err := f.Save(ctx, []transport.SaveItem{{Record: r}}); !errors.Is(err, transport.ErrRateLimited) {
			t.Fatalf("second: %v", err)
		}
		if len(f.Frames()) != 0 || len(changes(t, f, zone, 0).Changed) != 0 {
			t.Fatal("a failed save wrote")
		}
		if o := saveOne(t, f, r, absent); !o.Saved {
			t.Fatalf("third: %+v", o)
		}
		f.FailNext("changes", transport.ErrTokenExpired)
		if _, err := f.Changes(ctx, zone, 0); !errors.Is(err, transport.ErrTokenExpired) {
			t.Errorf("changes: %v", err)
		}
		f.FailNext("delete", transport.ErrForbidden)
		if _, err := f.Delete(ctx, zone, []transport.DeleteItem{{Name: r.WireName()}}); !errors.Is(err, transport.ErrForbidden) {
			t.Errorf("delete: %v", err)
		}
		f.FailNext("download", transport.ErrForbidden)
		if err := f.Download(ctx, "x", filepath.Join(t.TempDir(), "out")); !errors.Is(err, transport.ErrForbidden) {
			t.Errorf("download: %v", err)
		}

		f.SetAvailable(false)
		if _, err := f.Save(ctx, []transport.SaveItem{{Record: r}}); !errors.Is(err, transport.ErrUnavailable) {
			t.Errorf("save down: %v", err)
		}
		if _, err := f.Delete(ctx, zone, []transport.DeleteItem{{Name: r.WireName()}}); !errors.Is(err, transport.ErrUnavailable) {
			t.Errorf("delete down: %v", err)
		}
		if _, err := f.Changes(ctx, zone, 0); !errors.Is(err, transport.ErrUnavailable) {
			t.Errorf("changes down: %v", err)
		}
		if _, err := f.Write(box, "a-1", []byte("x"), absent); !errors.Is(err, transport.ErrUnavailable) {
			t.Errorf("phone write down: %v", err)
		}
		f.SetAvailable(true)
		if b := changes(t, f, zone, 0); len(b.Changed) != 1 {
			t.Errorf("store changed while down: %+v", b)
		}

		cancelled, cancel := context.WithCancel(ctx)
		cancel()
		if _, err := f.Save(cancelled, []transport.SaveItem{{Record: r}}); !errors.Is(err, context.Canceled) {
			t.Errorf("cancelled save: %v", err)
		}

		defer func() {
			if recover() == nil {
				t.Error("an unknown op name was accepted")
			}
		}()
		f.FailNext("sav", transport.ErrUnavailable)
	})
}

func TestMemfake_FramesCaptureEveryEnvelope(t *testing.T) {
	eachKind(t, func(t *testing.T, f *Fake, s *secure.Sealer) {
		r := seal(t, s, "target-1", `{}`)
		saveOne(t, f, r, absent)
		if _, err := f.Write(box, "a-1", []byte("phone"), absent); err != nil {
			t.Fatal(err)
		}
		saveOne(t, f, r, absent) // a conflict is still received
		frames := f.Frames()
		if len(frames) != 3 || !bytes.Equal(frames[0], r.Envelope()) || string(frames[1]) != "phone" {
			t.Fatalf("frames: %d", len(frames))
		}
		frames[0][0] ^= 0xff
		if !bytes.Equal(f.Frames()[0], r.Envelope()) {
			t.Error("Frames() exposes the fake's own bytes")
		}
	})
}

func TestMemfake_AttachmentRoundTrip(t *testing.T) {
	eachKind(t, func(t *testing.T, f *Fake, s *secure.Sealer) {
		dir := t.TempDir()
		src, sealedPath := filepath.Join(dir, "plain"), filepath.Join(dir, "sealed")
		if err := os.WriteFile(src, bytes.Repeat([]byte("ab"), 100), 0o600); err != nil {
			t.Fatal(err)
		}
		d, err := secure.EncryptAssetFile(src, sealedPath, secure.ID{1})
		if err != nil {
			t.Fatal(err)
		}
		r, err := s.Data(zone, "session_report-1", "", []byte(`{}`), &d, sealedPath)
		if err != nil {
			t.Fatal(err)
		}
		if o := saveOne(t, f, r, absent); !o.Saved {
			t.Fatalf("save: %+v", o)
		}
		b := changes(t, f, zone, 0)
		if len(b.Changed) != 1 || b.Changed[0].AttachmentID == "" {
			t.Fatalf("no attachment: %+v", b)
		}
		out := filepath.Join(dir, "out")
		if err := f.Download(context.Background(), b.Changed[0].AttachmentID, out); err != nil {
			t.Fatal(err)
		}
		want, _ := os.ReadFile(sealedPath)
		got, _ := os.ReadFile(out)
		if !bytes.Equal(got, want) {
			t.Error("downloaded bytes differ from the sealed file")
		}
		atts := f.Attachments()
		if len(atts) != 1 || !bytes.Equal(atts[b.Changed[0].AttachmentID], want) {
			t.Errorf("Attachments(): %d entries", len(atts))
		}
		atts[b.Changed[0].AttachmentID][0] ^= 0xff
		if !bytes.Equal(f.Attachments()[b.Changed[0].AttachmentID], want) {
			t.Error("Attachments() exposes the fake's own bytes")
		}
		for _, fr := range f.Frames() {
			if bytes.Equal(fr, want) {
				t.Error("an asset landed in Frames()")
			}
		}
		if info, err := os.Stat(out); err != nil || info.Mode().Perm() != 0o600 {
			t.Errorf("download mode: %v, %v", info, err)
		}
		if err := f.Download(context.Background(), "unknown", out); err == nil {
			t.Error("an unknown attachment downloaded")
		}
		// A pairing zone takes no attachments.
		pr, err := s.Data(transport.PairZone("slot-1"), "session_report-2", "", []byte(`{}`), &d, sealedPath)
		if err != nil {
			t.Fatal(err)
		}
		out2, err := f.Save(context.Background(), []transport.SaveItem{{Record: pr}})
		if err != nil || out2[0].Saved || !errors.Is(out2[0].Refused, transport.ErrForbidden) {
			t.Errorf("pair zone attachment: %+v, %v", out2, err)
		}
	})
}

func TestMemfake_ChangesPageByteCap(t *testing.T) {
	for _, k := range kinds {
		t.Run(string(k), func(t *testing.T) {
			f := New(k, clock)
			big := bytes.Repeat([]byte{'x'}, PageBytes*3/8) // two fit a page, three do not
			for i := range 5 {
				if _, err := f.Write(box, fmt.Sprintf("r-%d", i), big, absent); err != nil {
					t.Fatal(err)
				}
			}
			// A record larger than the cap still makes a page of one.
			if _, err := f.Write(box, "huge", bytes.Repeat([]byte{'y'}, PageBytes+1), absent); err != nil {
				t.Fatal(err)
			}
			var sizes []int
			since := uint64(0)
			for {
				b := changes(t, f, box, since)
				sizes = append(sizes, len(b.Changed))
				since = b.NewSeq
				if !b.More {
					break
				}
			}
			if fmt.Sprint(sizes) != "[2 2 1 1]" {
				t.Errorf("page sizes %v, want [2 2 1 1]", sizes)
			}
		})
	}
}

// Like the relay's Go client, the fake never drops an event: beyond the
// channel's buffer zone events fold per zone and controls are kept.
func TestMemfake_EventsNeverDropped(t *testing.T) {
	f := New(transport.KindRelay, clock)
	for i := range eventBuffer {
		if _, err := f.Write(fmt.Sprintf("relay/h/p%d", i), "a-1", []byte("x"), absent); err != nil {
			t.Fatal(err)
		}
	}
	for i := range 10 {
		if _, err := f.Write(box, fmt.Sprintf("a-%d", i), []byte("x"), absent); err != nil {
			t.Fatal(err)
		}
	}
	f.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.SlotRemoved, Detail: "phone"}})
	f.SendEvent(transport.Event{Err: transport.ErrUnavailable})
	// The first overflow event may already be in the pump's hands when the
	// next one for its zone arrives, so the 10 box writes fold into one or two.
	var tail []transport.Event
	timeout := time.After(5 * time.Second)
	for n := 0; len(tail) == 0 || tail[len(tail)-1].Err == nil; n++ {
		select {
		case e := <-f.Events():
			if n >= eventBuffer {
				tail = append(tail, e)
			}
		case <-timeout:
			t.Fatalf("lost events: overflow tail %+v", tail)
		}
	}
	boxes := 0
	for _, e := range tail[:len(tail)-2] {
		if e.Zone == box {
			boxes++
		}
	}
	ctl := tail[len(tail)-2].Control
	if boxes < 1 || boxes > 2 || boxes != len(tail)-2 || ctl == nil || ctl.Kind != transport.SlotRemoved ||
		!errors.Is(tail[len(tail)-1].Err, transport.ErrUnavailable) {
		t.Errorf("overflow events out of order, lost or not folded: %+v", tail)
	}
	// Drained: events go straight to the channel again.
	if _, err := f.Write(box, "b-1", []byte("x"), absent); err != nil {
		t.Fatal(err)
	}
	select {
	case e := <-f.Events():
		if e.Zone != box {
			t.Errorf("after drain: %+v", e)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no event after drain")
	}
}

func TestZoneNames(t *testing.T) {
	if transport.DataZone("H") != "data/H" || transport.MailboxZone("H", "P") != "relay/H/P" || transport.PairZone("S") != "pair/S" {
		t.Error("zone names drifted from the relay proto README")
	}
}
