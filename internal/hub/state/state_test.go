package state

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func openTest(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestOpen_CreatesDirAndFilePrivate(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = s.Close() }()
	assertMode(t, dir, 0o700)
	assertMode(t, filepath.Join(dir, "hubstate.db"), 0o600)
}

func TestOpen_TightensLooseDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = s.Close() }()
	assertMode(t, dir, 0o700)
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat %s: %v", path, err)
	}
	if got := fi.Mode().Perm(); got != want {
		t.Fatalf("%s mode = %o, want %o", filepath.Base(path), got, want)
	}
}

func TestMeta_RoundTrip(t *testing.T) {
	s := openTest(t)
	if _, ok, err := s.Meta(MetaHubID); err != nil || ok {
		t.Fatalf("Meta on empty = ok %v err %v", ok, err)
	}
	if err := s.SetMeta(MetaHubID, "A"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetMeta(MetaHubID, "B"); err != nil {
		t.Fatal(err)
	}
	v, ok, err := s.Meta(MetaHubID)
	if err != nil || !ok || v != "B" {
		t.Fatalf("Meta = %q %v %v", v, ok, err)
	}
}

func TestLedger_BeginThenDone(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	at := time.Unix(1_700_000_000, 0)
	if p, _, _, err := s.Phase("r1"); err != nil || p != "" {
		t.Fatalf("Phase before = %q %v", p, err)
	}
	if err := s.WithTx(ctx, func(tx *sql.Tx) error { return Begin(tx, "r1", at) }); err != nil {
		t.Fatalf("Begin: %v", err)
	}
	if p, _, _, err := s.Phase("r1"); err != nil || p != PhaseBegun {
		t.Fatalf("Phase after Begin = %q %v", p, err)
	}
	// A second claim never succeeds: two passes cannot both apply it.
	err := s.WithTx(ctx, func(tx *sql.Tx) error { return Begin(tx, "r1", at) })
	if !errors.Is(err, ErrClaimed) {
		t.Fatalf("second Begin = %v, want ErrClaimed", err)
	}
	seq := uint64(42)
	if err := s.WithTx(ctx, func(tx *sql.Tx) error {
		return MarkDone(tx, "r1", "applied", []byte{0xA1, 0xA2}, &seq, at.Add(time.Second))
	}); err != nil {
		t.Fatalf("MarkDone: %v", err)
	}
	p, outcome, echo, err := s.Phase("r1")
	if err != nil || p != PhaseDone || outcome != "applied" || string(echo) != "\xa1\xa2" {
		t.Fatalf("Phase after done = %q %q %x %v", p, outcome, echo, err)
	}
	var doneSeq sql.NullInt64
	if err := s.db.QueryRow(`SELECT done_seq FROM relay_processed WHERE record_name = 'r1'`).Scan(&doneSeq); err != nil {
		t.Fatal(err)
	}
	if !doneSeq.Valid || doneSeq.Int64 != 42 {
		t.Fatalf("done_seq = %v", doneSeq)
	}
	// An idempotent kind is marked done without a begun row.
	if err := s.WithTx(ctx, func(tx *sql.Tx) error { return MarkDone(tx, "r2", "skipped", nil, nil, at) }); err != nil {
		t.Fatalf("MarkDone without Begin: %v", err)
	}
	if p, o, e, err := s.Phase("r2"); err != nil || p != PhaseDone || o != "skipped" || e != nil {
		t.Fatalf("r2 = %q %q %x %v", p, o, e, err)
	}
}

func TestWithTx_RollsBackOnError(t *testing.T) {
	s := openTest(t)
	boom := errors.New("boom")
	err := s.WithTx(context.Background(), func(tx *sql.Tx) error {
		if err := Begin(tx, "r1", time.Now()); err != nil {
			return err
		}
		if err := RecordSeen(tx, "w1", "S", 1, 7); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("WithTx = %v", err)
	}
	if p, _, _, _ := s.Phase("r1"); p != "" {
		t.Fatalf("Begin survived a rollback: %q", p)
	}
	var n int
	_ = s.db.QueryRow(`SELECT count(*) FROM relay_seen`).Scan(&n)
	if n != 0 {
		t.Fatalf("relay_seen survived a rollback: %d", n)
	}
}

func TestRecordSeen_Upserts(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	for _, seq := range []uint64{5, 9} {
		if err := s.WithTx(ctx, func(tx *sql.Tx) error { return RecordSeen(tx, "w1", "DEV", 2, seq) }); err != nil {
			t.Fatal(err)
		}
	}
	var epoch, seq int64
	if err := s.db.QueryRow(`SELECT epoch, seq FROM relay_seen WHERE wire_name = 'w1' AND sender_id = 'DEV'`).Scan(&epoch, &seq); err != nil {
		t.Fatal(err)
	}
	if epoch != 2 || seq != 9 {
		t.Fatalf("relay_seen = %d/%d", epoch, seq)
	}
}

func TestDevices_LinkReadAndSetLastApplied(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	linked := time.Unix(1_700_000_000, 0).UTC()
	d := Device{
		ID: "0A0A0A0A-0A0A-0A0A-0A0A-0A0A0A0A0A0A", Name: "phone", Scope: "private", LinkedAt: linked,
		SigningKey: []byte{1, 2}, AgreementKey: []byte{3, 4}, LinkNonce: "n1",
		TypingAllowed: true, StartSessionsAllowed: true, Ordered: true, RelayDeviceID: "relay1",
	}
	if err := s.WithTx(ctx, func(tx *sql.Tx) error { return LinkDevice(tx, d) }); err != nil {
		t.Fatalf("LinkDevice: %v", err)
	}
	if err := s.WithTx(ctx, func(tx *sql.Tx) error { return SetLastApplied(tx, "0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a", 3) }); err != nil {
		t.Fatalf("SetLastApplied: %v", err)
	}
	got, ok, err := s.Device(d.ID)
	if err != nil || !ok {
		t.Fatalf("Device = %v %v", ok, err)
	}
	d.LastAppliedActionSeq = 3
	if !got.LinkedAt.Equal(d.LinkedAt) {
		t.Fatalf("LinkedAt = %v, want %v", got.LinkedAt, d.LinkedAt)
	}
	got.LinkedAt = d.LinkedAt
	if !devicesEqual(got, d) {
		t.Fatalf("Device = %+v\nwant %+v", got, d)
	}
	all, err := s.Devices()
	if err != nil || len(all) != 1 {
		t.Fatalf("Devices = %d %v", len(all), err)
	}
	if _, ok, err := s.Device("missing"); err != nil || ok {
		t.Fatalf("missing device = %v %v", ok, err)
	}
	err = s.WithTx(ctx, func(tx *sql.Tx) error { return SetLastApplied(tx, "missing", 1) })
	if !errors.Is(err, ErrNoDevice) {
		t.Fatalf("SetLastApplied on a missing device = %v", err)
	}
}

func devicesEqual(a, b Device) bool {
	return a.ID == b.ID && a.Name == b.Name && a.Scope == b.Scope && a.LinkedAt.Equal(b.LinkedAt) &&
		string(a.SigningKey) == string(b.SigningKey) && string(a.AgreementKey) == string(b.AgreementKey) &&
		a.LinkNonce == b.LinkNonce && a.TypingAllowed == b.TypingAllowed && a.TypingRequested == b.TypingRequested &&
		a.PermissionsAllowed == b.PermissionsAllowed && a.PermissionsRequested == b.PermissionsRequested &&
		a.StartSessionsAllowed == b.StartSessionsAllowed && a.StartSessionsGranted == b.StartSessionsGranted &&
		a.LastAppliedActionSeq == b.LastAppliedActionSeq && a.Ordered == b.Ordered &&
		a.RelayDeviceID == b.RelayDeviceID && a.ResendRequestedFrom == b.ResendRequestedFrom
}

func TestControlQueueStoresSealedOnly(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	err := s.WithTx(ctx, func(tx *sql.Tx) error {
		return Enqueue(tx, Control{Mailbox: "m", RecordName: "c1", Kind: "echo", Expect: ExpectNone})
	})
	if !errors.Is(err, ErrUnsealed) {
		t.Fatalf("Enqueue empty envelope = %v, want ErrUnsealed", err)
	}
	err = s.WithTx(ctx, func(tx *sql.Tx) error {
		return Enqueue(tx, Control{Mailbox: "m", RecordName: "c1", Kind: "echo", Envelope: []byte("WTE\x01"), Expect: "bogus"})
	})
	if err == nil {
		t.Fatal("Enqueue with an unknown expect succeeded")
	}
	for i, c := range []Control{
		{Mailbox: "m", RecordName: "c1", Kind: "echo", Envelope: []byte{1}, Expect: ExpectSeq, ExpectSeq: 7},
		{Mailbox: "m", RecordName: "c2", Kind: "resend_from", Envelope: []byte{2}, Expect: ExpectAbsent},
		{Mailbox: "other", RecordName: "c3", Kind: "echo", Envelope: []byte{3}, Expect: ExpectNone},
	} {
		if err := s.WithTx(ctx, func(tx *sql.Tx) error { return Enqueue(tx, c) }); err != nil {
			t.Fatalf("Enqueue %d: %v", i, err)
		}
	}
	got, err := s.PendingControls("m")
	if err != nil || len(got) != 2 {
		t.Fatalf("PendingControls = %d %v", len(got), err)
	}
	if got[0].RecordName != "c1" || got[0].Expect != ExpectSeq || got[0].ExpectSeq != 7 || got[1].RecordName != "c2" {
		t.Fatalf("PendingControls order/fields = %+v", got)
	}
	if err := s.ControlFailed(got[0].ID, "unavailable"); err != nil {
		t.Fatal(err)
	}
	if err := s.ControlDone(got[1].ID); err != nil {
		t.Fatal(err)
	}
	got, _ = s.PendingControls("m")
	if len(got) != 1 || got[0].Attempts != 1 {
		t.Fatalf("after fail/done = %+v", got)
	}
	var class string
	if err := s.db.QueryRow(`SELECT last_error_class FROM control_queue WHERE id = ?`, got[0].ID).Scan(&class); err != nil || class != "unavailable" {
		t.Fatalf("last_error_class = %q %v", class, err)
	}
}

func TestHeldActions(t *testing.T) {
	s := openTest(t)
	if err := s.HoldAction("D", 5, "a5", []byte{5}); err != nil {
		t.Fatal(err)
	}
	if err := s.HoldAction("D", 4, "a4", []byte{4}); err != nil {
		t.Fatal(err)
	}
	if err := s.HoldAction("D", 4, "a4", []byte{4}); err != nil {
		t.Fatalf("holding a held action again: %v", err)
	}
	if err := s.HoldAction("D", 6, "a6", nil); !errors.Is(err, ErrUnsealed) {
		t.Fatalf("HoldAction unsealed = %v", err)
	}
	held, err := s.HeldActions("d")
	if err != nil || len(held) != 2 || held[0].ActionSeq != 4 || held[1].ActionSeq != 5 || held[0].RecordName != "a4" {
		t.Fatalf("HeldActions = %+v %v", held, err)
	}
	if err := s.WithTx(context.Background(), func(tx *sql.Tx) error { return DropHeld(tx, "D", 4) }); err != nil {
		t.Fatal(err)
	}
	held, _ = s.HeldActions("D")
	if len(held) != 1 || held[0].ActionSeq != 5 {
		t.Fatalf("after DropHeld = %+v", held)
	}
}

func TestZoneTokens(t *testing.T) {
	s := openTest(t)
	if v, err := s.ZoneToken("relay"); err != nil || v != 0 {
		t.Fatalf("ZoneToken empty = %d %v", v, err)
	}
	if err := s.SetZoneToken("relay", 12); err != nil {
		t.Fatal(err)
	}
	if err := s.SetZoneToken("relay", 0); err != nil {
		t.Fatal(err)
	}
	if err := s.SetZoneToken("data", 3); err != nil {
		t.Fatal(err)
	}
	if v, _ := s.ZoneToken("relay"); v != 0 {
		t.Fatalf("relay token = %d", v)
	}
	if v, _ := s.ZoneToken("data"); v != 3 {
		t.Fatalf("data token = %d", v)
	}
}

func TestEpochs(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	at := time.Unix(1_700_000_000, 0)
	for _, e := range []Epoch{{Epoch: 1, SealedKeys: []byte{1}, CreatedAt: at, FirstSeq: 1}, {Epoch: 2, SealedKeys: []byte{2}, CreatedAt: at, FirstSeq: 1025}} {
		if err := s.WithTx(ctx, func(tx *sql.Tx) error { return InsertEpoch(tx, e) }); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.WithTx(ctx, func(tx *sql.Tx) error { return RetireEpoch(tx, 1, at.Add(time.Hour)) }); err != nil {
		t.Fatal(err)
	}
	got, err := s.Epochs()
	if err != nil || len(got) != 2 || got[0].Epoch != 1 || got[0].RetiredAt == nil || got[1].RetiredAt != nil || got[1].FirstSeq != 1025 {
		t.Fatalf("Epochs = %+v %v", got, err)
	}
}

func TestSliceState(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	if err := s.WithTx(ctx, func(tx *sql.Tx) error {
		if err := SetSliceState(tx, "now-1", "wire1", "h1", time.Now()); err != nil {
			return err
		}
		if err := SetSliceState(tx, "now_x-1", "wire2", "h2", time.Now()); err != nil {
			return err
		}
		return SetSliceState(tx, "now-1", "wire1", "h3", time.Now())
	}); err != nil {
		t.Fatal(err)
	}
	got, err := s.SliceHashes("now")
	if err != nil || len(got) != 1 || got["now-1"].Hash != "h3" || got["now-1"].WireName != "wire1" {
		t.Fatalf("SliceHashes = %+v %v", got, err)
	}
	if err := s.WithTx(ctx, func(tx *sql.Tx) error { return DeleteSliceState(tx, "now-1") }); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.SliceHashes("now"); len(got) != 0 {
		t.Fatalf("after delete = %+v", got)
	}
}

func TestDeviceIDsStoredUppercase(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	if err := s.HoldAction("d", 5, "a5", []byte{5}); err != nil {
		t.Fatal(err)
	}
	if err := s.HoldAction("D", 5, "a5", []byte{5}); err != nil {
		t.Fatal(err)
	}
	if err := s.WithTx(ctx, func(tx *sql.Tx) error {
		if err := RecordSeen(tx, "w1", "dev", 1, 1); err != nil {
			return err
		}
		if err := RecordSeen(tx, "w1", "DEV", 1, 2); err != nil {
			return err
		}
		return LinkDevice(tx, Device{ID: "0c0c0c0c-0c0c-0c0c-0c0c-0c0c0c0c0c0c", Name: "p", Scope: "private", LinkedAt: time.Now()})
	}); err != nil {
		t.Fatal(err)
	}
	for _, q := range []struct{ query, want string }{
		{`SELECT group_concat(device_id) FROM held_actions`, "D"},
		{`SELECT group_concat(sender_id) FROM relay_seen`, "DEV"},
		{`SELECT group_concat(device_id) FROM devices`, "0C0C0C0C-0C0C-0C0C-0C0C-0C0C0C0C0C0C"},
	} {
		var got string
		if err := s.db.QueryRow(q.query).Scan(&got); err != nil || got != q.want {
			t.Fatalf("%s = %q %v, want %q", q.query, got, err, q.want)
		}
	}
}

func TestRecordSeen_NeverLowersAndReadsBack(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	if _, _, ok, err := s.RelaySeen("w1", "dev"); err != nil || ok {
		t.Fatalf("RelaySeen on empty = ok %v err %v", ok, err)
	}
	for _, v := range []struct {
		epoch uint32
		seq   uint64
	}{{2, 9}, {2, 5}, {1, 100}} {
		if err := s.WithTx(ctx, func(tx *sql.Tx) error { return RecordSeen(tx, "w1", "dev", v.epoch, v.seq) }); err != nil {
			t.Fatal(err)
		}
	}
	epoch, seq, ok, err := s.RelaySeen("w1", "DEV")
	if err != nil || !ok || epoch != 2 || seq != 9 {
		t.Fatalf("RelaySeen = %d/%d ok %v err %v, want 2/9", epoch, seq, ok, err)
	}
	if err := s.WithTx(ctx, func(tx *sql.Tx) error { return RecordSeen(tx, "w1", "dev", 3, 1) }); err != nil {
		t.Fatal(err)
	}
	if epoch, seq, _, _ = s.RelaySeen("w1", "dev"); epoch != 3 || seq != 1 {
		t.Fatalf("a newer epoch did not replace the mark: %d/%d", epoch, seq)
	}
}

func TestKeyboxRecipientKey_LinkedThenPendingRevokedRefused(t *testing.T) {
	s := openTest(t)
	if k, err := s.KeyboxRecipientKey("AA"); err != nil || k != nil {
		t.Fatalf("no row: key %x err %v", k, err)
	}
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := s.db.Exec(q, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`INSERT INTO link_refusals (device_id, name, scope, reason, at, agreement_key) VALUES ('AA', 'p', 'private', 'r', 1, x'04')`)
	exec(`INSERT INTO revoked_devices (device_id, agreement_key, removed_at) VALUES ('AA', x'03', 1)`)
	exec(`INSERT INTO pending_devices (device_id, agreement_key) VALUES ('AA', x'02')`)
	for _, want := range []byte{2, 3, 4} {
		k, err := s.KeyboxRecipientKey("aa")
		if err != nil || len(k) != 1 || k[0] != want {
			t.Fatalf("key %x err %v, want %02x", k, err, want)
		}
		switch want {
		case 2:
			exec(`DELETE FROM pending_devices`)
		case 3:
			exec(`DELETE FROM revoked_devices`)
		}
	}
}

func TestWipeSliceHashesKeepsWireNames(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	if err := s.WithTx(ctx, func(tx *sql.Tx) error { return SetSliceState(tx, "target-1", "w", "h", time.Now()) }); err != nil {
		t.Fatal(err)
	}
	if err := s.WithTx(ctx, WipeSliceHashes); err != nil {
		t.Fatal(err)
	}
	got, err := s.SliceHashes("target")
	if err != nil || got["target-1"] != (SliceRecord{Hash: "", WireName: "w"}) {
		t.Fatalf("slice state = %+v err %v", got, err)
	}
}

// The heartbeat's record is the bare kind name; a bare name of another kind
// and a longer kind sharing the prefix stay out.
func TestSliceHashesIncludesTheBareKindName(t *testing.T) {
	s := openTest(t)
	if err := s.WithTx(context.Background(), func(tx *sql.Tx) error {
		for _, name := range []string{"heartbeat", "heartbeat-x", "heartbeat_more-1", "digest"} {
			if err := SetSliceState(tx, name, "w", "h", time.Now()); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	got, err := s.SliceHashes("heartbeat")
	if _, bare := got["heartbeat"]; err != nil || len(got) != 2 || !bare || got["heartbeat-x"].Hash != "h" {
		t.Fatalf("SliceHashes(heartbeat) = %+v %v", got, err)
	}
	if got, _ := s.SliceHashes("digest_topic"); len(got) != 0 {
		t.Fatalf("SliceHashes(digest_topic) = %+v", got)
	}
}
