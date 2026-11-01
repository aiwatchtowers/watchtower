package cloudkit_test

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/cloudkit/bridgefake"
	pb "watchtower/internal/hub/transport/cloudkit/bridgepb"
)

const dataZone = "data/acme"

type rig struct {
	t      *testing.T
	ctx    context.Context
	dir    string
	hub    string
	st     *state.Store
	ident  identity.Identity
	kr     *identity.Keyring
	sealer *secure.Sealer
	fake   *bridgefake.Fake
	c      *cloudkit.Client
}

func newRig(t *testing.T, opts ...bridgefake.Option) *rig {
	t.Helper()
	dir := bridgefake.Dir(t)
	if err := os.MkdirAll(filepath.Join(dir, cloudkit.AssetsDirName), 0o700); err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ident, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	kr, err := identity.NewKeyring(ident, st, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	r := &rig{t: t, ctx: ctx, dir: dir, hub: kr.HubID().String(), st: st, ident: ident, kr: kr, sealer: secure.NewSealer(kr)}
	r.fake = bridgefake.Serve(t, dir, opts...)
	r.c = cloudkit.New(cloudkit.Config{Dir: dir, HubID: r.hub})
	t.Cleanup(func() { _ = r.c.Close() })
	return r
}

func (r *rig) data(plain string, payload []byte) secure.Record {
	r.t.Helper()
	rec, err := r.sealer.Data(dataZone, plain, "", payload, nil, "")
	if err != nil {
		r.t.Fatal(err)
	}
	return rec
}

func (r *rig) save(items ...transport.SaveItem) []transport.Outcome {
	r.t.Helper()
	out, err := r.c.Save(r.ctx, items)
	if err != nil {
		r.t.Fatalf("save: %v", err)
	}
	return out
}

// requests decodes every frame the bridge received.
func (r *rig) requests() []*pb.Request {
	r.t.Helper()
	var out []*pb.Request
	for _, f := range r.fake.Frames() {
		var q pb.Request
		if err := proto.Unmarshal(f, &q); err != nil {
			r.t.Fatal(err)
		}
		out = append(out, &q)
	}
	return out
}

func (r *rig) lastSave() *pb.Save {
	r.t.Helper()
	qs := r.requests()
	for i := len(qs) - 1; i >= 0; i-- {
		if s := qs[i].GetSave(); s != nil {
			return s
		}
	}
	r.t.Fatal("no save frame")
	return nil
}

func (r *rig) nextEvent(what string, ok func(transport.Event) bool) transport.Event {
	r.t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		select {
		case e := <-r.c.Events():
			if ok(e) {
				return e
			}
		case <-deadline:
			r.t.Fatalf("no %s event", what)
		}
	}
}

func TestClientRefusesUnsealedRecord(t *testing.T) {
	r := newRig(t)
	good := r.data("workbench-1", []byte("{}"))
	for _, items := range [][]transport.SaveItem{
		{{Record: secure.Record{}}},
		{{Record: good}, {Record: secure.Record{}}},
	} {
		if _, err := r.c.Save(r.ctx, items); !errors.Is(err, secure.ErrUnsealed) {
			t.Fatalf("err %v, want ErrUnsealed", err)
		}
	}
	if n := len(r.fake.Frames()); n != 0 || r.fake.Accepted() != 0 {
		t.Fatalf("%d frames on %d connections before the refusal", n, r.fake.Accepted())
	}
}

func TestSignalIsTheOnlyUnsealedKindAndOnlyFromTheSealer(t *testing.T) {
	r := newRig(t)
	// A signal made outside Sealer.Signal is the zero Record: refused.
	if _, err := r.c.Save(r.ctx, []transport.SaveItem{{Record: secure.Record{}}}); !errors.Is(err, secure.ErrUnsealed) {
		t.Fatalf("outside signal: %v", err)
	}
	if _, err := r.sealer.Signal(r.data("workbench-1", []byte("{}"))); err == nil {
		t.Fatal("a data record got a signal")
	}
	alert, err := r.sealer.Alert(dataZone, "ask_alert-1", []byte(`{"n":1}`))
	if err != nil {
		t.Fatal(err)
	}
	sig, err := r.sealer.Signal(alert)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(r.fake.Frames()); n != 0 {
		t.Fatalf("%d frames before the save", n)
	}
	out := r.save(transport.SaveItem{Record: alert}, transport.SaveItem{Record: sig})
	if !out[0].Saved || !out[1].Saved {
		t.Fatalf("outcomes %+v", out)
	}
	items := r.lastSave().GetItems()
	if len(items) != 2 || items[1].GetName() != secure.SignalName(alert.WireName()) || len(items[1].GetEnvelope()) != 0 {
		t.Fatalf("the signal did not travel as an ordinary, empty save item: %+v", items)
	}
	if _, err := secure.ParseHeader(items[0].GetEnvelope()); err != nil {
		t.Fatalf("the alert is not an envelope: %v", err)
	}
	// The signal is deleted like any record.
	del, err := r.c.Delete(r.ctx, dataZone, []transport.DeleteItem{{Name: sig.WireName()}})
	if err != nil || !del[0].Saved {
		t.Fatalf("delete signal: %+v, %v", del, err)
	}
}

func TestZonesMapToHubZones(t *testing.T) {
	r := newRig(t)
	rec := r.data("workbench-1", []byte("{}"))
	r.save(transport.SaveItem{Record: rec})
	if z := r.lastSave().GetItems()[0].GetZone(); z != cloudkit.DataZoneName(r.hub) {
		t.Fatalf("data zone sent as %q", z)
	}
	for zone, want := range map[string]string{
		dataZone:                      cloudkit.DataZoneName(r.hub),
		"data/" + r.hub:               cloudkit.DataZoneName(r.hub),
		cloudkit.DataZoneName(r.hub):  cloudkit.DataZoneName(r.hub),
		"relay/acme/phone-a":          cloudkit.RelayZoneName(r.hub),
		"relay/acme/phone-b":          cloudkit.RelayZoneName(r.hub),
		cloudkit.RelayZoneName(r.hub): cloudkit.RelayZoneName(r.hub),
	} {
		b, err := r.c.Changes(r.ctx, zone, 0)
		if err != nil {
			t.Fatalf("%s: %v", zone, err)
		}
		qs := r.requests()
		if got := qs[len(qs)-1].GetChanges().GetZone(); got != want {
			t.Errorf("%s sent as %q, want %q", zone, got, want)
		}
		for _, s := range b.Changed {
			if s.Zone != zone {
				t.Errorf("%s: a record came back in zone %q", zone, s.Zone)
			}
		}
		if want == cloudkit.DataZoneName(r.hub) && len(b.Changed) != 1 {
			t.Errorf("%s: %d records, want the saved one", zone, len(b.Changed))
		}
	}
	if a, b := r.c.MailboxFor("acme", "phone-a"), r.c.MailboxFor("acme", "phone-b"); a != cloudkit.RelayZoneName(r.hub) || b != a {
		t.Fatalf("mailboxes %q %q, want the one RelayZone", a, b)
	}
	for _, bad := range []string{"", "data/", "data/a/b", "relay/a", "relay/a/", "relay/a/b/c", "DataZone-other", "RelayZone-other", "inbox/acme"} {
		if _, err := r.c.Changes(r.ctx, bad, 0); !errors.Is(err, transport.ErrUnsupportedZone) {
			t.Errorf("%q: %v, want ErrUnsupportedZone", bad, err)
		}
	}
}

func TestPairZoneIsUnsupportedOnCloudKit(t *testing.T) {
	r := newRig(t)
	pair := transport.PairZone("slot1")
	rec, err := r.sealer.Data(pair, "workbench-1", "", []byte("{}"), nil, "")
	if err != nil {
		t.Fatal(err)
	}
	checks := map[string]error{}
	_, checks["save"] = r.c.Save(r.ctx, []transport.SaveItem{{Record: rec}})
	_, checks["delete"] = r.c.Delete(r.ctx, pair, []transport.DeleteItem{{Name: "x"}})
	_, checks["changes"] = r.c.Changes(r.ctx, pair, 0)
	checks["download"] = r.c.Download(r.ctx, pair, "att-1", filepath.Join(t.TempDir(), "x"))
	_, checks["participants"] = r.c.Participants(r.ctx, pair)
	checks["remove_participants"] = r.c.RemoveParticipants(r.ctx, pair, []string{"_u"})
	for op, err := range checks {
		if !errors.Is(err, transport.ErrUnsupportedZone) {
			t.Errorf("%s: %v, want ErrUnsupportedZone", op, err)
		}
	}
	if n := len(r.fake.Frames()); n != 0 {
		t.Fatalf("%d frames for a pairing zone", n)
	}
}

func TestTagSeqIsOpaqueEqualityOnly(t *testing.T) {
	r := newRig(t)
	first := r.save(transport.SaveItem{Record: r.data("workbench-1", []byte(`{"v":1}`))})[0]
	tag := first.RecordSeq
	second := r.save(transport.SaveItem{Record: r.data("workbench-1", []byte(`{"v":2}`)), Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: tag}})[0]
	if !second.Saved || second.RecordSeq == tag {
		t.Fatalf("save on the current tag: %+v", second)
	}
	if got := r.lastSave().GetItems()[0].GetExpect(); got.GetMode() != pb.ExpectMode_EXPECT_SEQ || got.GetTagSeq() != tag {
		t.Fatalf("expect sent as %+v, want the tag as given", got)
	}
	// Neighbours of the current tag are not it: only equality counts.
	for _, seq := range []uint64{tag, second.RecordSeq - 1, second.RecordSeq + 1} {
		o := r.save(transport.SaveItem{Record: r.data("workbench-1", []byte(`{"v":3}`)), Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: seq}})[0]
		if o.Saved || o.Conflict == nil || o.Conflict.RecordSeq != second.RecordSeq {
			t.Fatalf("expect %d: %+v, want a conflict at the current tag", seq, o)
		}
	}
	name := r.data("workbench-1", nil).WireName()
	del, err := r.c.Delete(r.ctx, dataZone, []transport.DeleteItem{
		{Name: name, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: tag}},
	})
	if err != nil || del[0].Saved || del[0].Conflict == nil || del[0].Conflict.Zone != dataZone {
		t.Fatalf("delete on an old tag: %+v, %v", del, err)
	}
	del, err = r.c.Delete(r.ctx, dataZone, []transport.DeleteItem{
		{Name: name, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: second.RecordSeq}},
	})
	if err != nil || !del[0].Saved {
		t.Fatalf("delete on the current tag: %+v, %v", del, err)
	}
}

func TestRecordSeqNeverComparedWithCursor(t *testing.T) {
	r := newRig(t)
	var tags []uint64
	for i := range 5 {
		o := r.save(transport.SaveItem{Record: r.data("workbench-"+string(rune('a'+i)), []byte("{}"))})[0]
		tags = append(tags, o.RecordSeq)
	}
	b, err := r.c.Changes(r.ctx, dataZone, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !b.Reset || len(b.Changed) != 5 {
		t.Fatalf("first page: reset %v, %d records", b.Reset, len(b.Changed))
	}
	for _, s := range b.Changed {
		if !slices.Contains(tags, s.RecordSeq) {
			t.Errorf("record %s came back with another tag", s.Name)
		}
		if s.RecordSeq <= b.NewSeq {
			t.Errorf("tag %d reads like a cursor (<= %d)", s.RecordSeq, b.NewSeq)
		}
	}
	// The client passes cursors through untouched: a tag used as a cursor
	// is just an unknown cursor.
	if _, err := r.c.Changes(r.ctx, dataZone, tags[0]); !errors.Is(err, transport.ErrTokenExpired) {
		t.Fatalf("a tag as cursor: %v, want ErrTokenExpired", err)
	}
	qs := r.requests()
	if got := qs[len(qs)-1].GetChanges().GetSince(); got != tags[0] {
		t.Fatalf("since sent as %d", got)
	}
	next, err := r.c.Changes(r.ctx, dataZone, b.NewSeq)
	if err != nil || len(next.Changed) != 0 || next.Reset || next.NewSeq != b.NewSeq {
		t.Fatalf("after the cursor: %+v, %v", next, err)
	}
}

func TestExpectAbsentConflictCarriesTheServerCopy(t *testing.T) {
	r := newRig(t)
	firstRec := r.data("workbench-1", []byte(`{"v":1}`))
	first := r.save(transport.SaveItem{Record: firstRec, Expect: transport.Expect{Mode: transport.ExpectAbsent}})[0]
	if !first.Saved {
		t.Fatalf("first save %+v", first)
	}
	o := r.save(transport.SaveItem{Record: r.data("workbench-1", []byte(`{"v":2}`)), Expect: transport.Expect{Mode: transport.ExpectAbsent}})[0]
	if o.Saved || o.Conflict == nil {
		t.Fatalf("second save %+v, want a conflict", o)
	}
	c := o.Conflict
	if !bytes.Equal(c.Envelope, firstRec.Envelope()) || c.RecordSeq != first.RecordSeq || c.Zone != dataZone ||
		c.Name != firstRec.WireName() || c.ServerAt.IsZero() {
		t.Fatalf("conflict %+v is not the server copy", c)
	}
	// A precondition on a missing record: not saved, no conflict copy.
	m := r.save(transport.SaveItem{Record: r.data("workbench-2", []byte("{}")), Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: 9}})[0]
	if m.Saved || m.Conflict != nil || m.Refused != nil {
		t.Fatalf("missing record: %+v", m)
	}
}

// sealedAsset writes a sealed asset of plain at path and returns its
// descriptor.
func sealedAsset(t *testing.T, plain []byte, path string) *secure.AssetDescriptor {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(t.TempDir(), "plain")
	if err := os.WriteFile(src, plain, 0o600); err != nil {
		t.Fatal(err)
	}
	d, err := secure.EncryptAssetFile(src, path, secure.ID{3})
	if err != nil {
		t.Fatal(err)
	}
	return &d
}

func TestAssetsCrossAsPathsOnly(t *testing.T) {
	r := newRig(t)
	plain := bytes.Repeat([]byte("transcript-text "), 64<<10/16*3) // 192 KiB
	inside := filepath.Join(r.dir, cloudkit.AssetsDirName, "transcripts", "t1.asset")
	d := sealedAsset(t, plain, inside)
	rec, err := r.sealer.Data(dataZone, "meeting_transcript-1", "", []byte(`{"id":1}`), d, inside)
	if err != nil {
		t.Fatal(err)
	}
	r.save(transport.SaveItem{Record: rec})
	item := r.lastSave().GetItems()[0]
	resolvedRoot, _ := filepath.EvalSymlinks(filepath.Join(r.dir, cloudkit.AssetsDirName))
	if !strings.HasPrefix(item.GetAssetPath(), resolvedRoot+string(filepath.Separator)) {
		t.Fatalf("asset path %q is not under the asset dir", item.GetAssetPath())
	}
	sealed, _ := os.ReadFile(inside)
	for i, f := range r.fake.Frames() {
		if len(f) > 64<<10 {
			t.Errorf("frame %d is %d bytes: asset bytes on the socket?", i, len(f))
		}
		if bytes.Contains(f, sealed[:256]) || bytes.Contains(f, []byte("transcript-text")) {
			t.Errorf("frame %d carries the asset", i)
		}
	}
	atts := r.fake.Store().Attachments()
	if len(atts) != 1 {
		t.Fatalf("%d attachments", len(atts))
	}
	for _, b := range atts {
		if !bytes.Equal(b, sealed) {
			t.Fatal("the uploaded asset is not the sealed file")
		}
	}

	// Outside the asset dir, or through a symlink: refused before any frame.
	before := len(r.fake.Frames())
	outside := filepath.Join(t.TempDir(), "t2.asset")
	d2 := sealedAsset(t, plain, outside)
	link := filepath.Join(r.dir, cloudkit.AssetsDirName, "link.asset")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{outside, link} {
		rec2, err := r.sealer.Data(dataZone, "meeting_transcript-2", "", []byte(`{"id":2}`), d2, p)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := r.c.Save(r.ctx, []transport.SaveItem{{Record: rec2}}); !errors.Is(err, secure.ErrUnsealed) {
			t.Errorf("%s: %v, want ErrUnsealed", filepath.Base(p), err)
		}
	}
	if n := len(r.fake.Frames()); n != before {
		t.Fatalf("%d frames written for refused assets", n-before)
	}

	// Download: the bridge writes under <dir>/downloads, the client moves the
	// file to dst.
	phone := r.fake.PhoneRecords(r.hub)
	upload := bytes.Repeat([]byte{0xA5}, 100<<10)
	if _, err := phone.WriteWithAsset("relay/acme/phone", "recupload-u1", []byte("env"), upload, transport.Expect{}); err != nil {
		t.Fatal(err)
	}
	b, err := r.c.Changes(r.ctx, "relay/acme/phone", 0)
	if err != nil || len(b.Changed) != 1 || b.Changed[0].AttachmentID == "" {
		t.Fatalf("upload record: %+v, %v", b, err)
	}
	dst := filepath.Join(t.TempDir(), "u1.sealed")
	if err := r.c.Download(r.ctx, "relay/acme/phone", b.Changed[0].AttachmentID, dst); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(dst); err != nil || !bytes.Equal(got, upload) {
		t.Fatalf("download: %v", err)
	}
	if fi, _ := os.Stat(dst); fi.Mode().Perm() != 0o600 {
		t.Fatalf("download mode %v", fi.Mode().Perm())
	}
	qs := r.requests()
	dl := qs[len(qs)-1].GetDownload()
	resolvedDL, _ := filepath.EvalSymlinks(filepath.Join(r.dir, cloudkit.DownloadsDirName))
	if dl == nil || filepath.Dir(dl.GetDst()) != filepath.Join(r.dir, cloudkit.DownloadsDirName) && filepath.Dir(dl.GetDst()) != resolvedDL {
		t.Fatalf("download dst %q is not under the downloads dir", dl.GetDst())
	}
	if left, _ := os.ReadDir(filepath.Join(r.dir, cloudkit.DownloadsDirName)); len(left) != 0 {
		t.Fatalf("%d files left in downloads", len(left))
	}
	for _, f := range r.fake.Answers() {
		if bytes.Contains(f, upload[:1024]) {
			t.Fatal("asset bytes came back on the socket")
		}
	}
}

func TestSocketPrivateAndPeerChecked(t *testing.T) {
	r := newRig(t)
	sock := filepath.Join(r.dir, cloudkit.SocketName)
	fi, err := os.Stat(sock)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %v, %v", fi.Mode().Perm(), err)
	}
	// A socket others may open is refused before dialing.
	if err := os.Chmod(sock, 0o666); err != nil {
		t.Fatal(err)
	}
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err == nil {
		t.Fatal("a 0666 socket was used")
	}
	if r.fake.Accepted() != 0 {
		t.Fatal("dialed a socket open to other users")
	}
	if err := os.Chmod(sock, 0o600); err != nil {
		t.Fatal(err)
	}
	// A peer of another user is closed before any frame.
	cloudkit.SetPeerUID(r.c, func(*net.UnixConn) (int, error) { return os.Getuid() + 1, nil })
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err == nil {
		t.Fatal("a bridge of another user was used")
	}
	cloudkit.SetPeerUID(r.c, func(*net.UnixConn) (int, error) { return 0, errors.New("no credentials") })
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err == nil {
		t.Fatal("a bridge without peer credentials was used")
	}
	if n := len(r.fake.Frames()); n != 0 {
		t.Fatalf("%d frames to a refused peer", n)
	}
	// The real peer call accepts this user's bridge; Hello goes first.
	_ = r.c.Close()
	r.c = cloudkit.New(cloudkit.Config{Dir: r.dir, HubID: r.hub})
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err != nil {
		t.Fatal(err)
	}
	qs := r.requests()
	if len(qs) != 2 || qs[0].GetHello().GetVersion() != cloudkit.ProtocolVersion || qs[0].GetHello().GetHubId() != r.hub {
		t.Fatalf("frames %v, want Hello then Changes", qs)
	}
}

func TestHelloVersionMismatchIsUnsupported(t *testing.T) {
	r := newRig(t, bridgefake.WithVersion(2))
	if _, err := r.c.Changes(r.ctx, dataZone, 0); !errors.Is(err, transport.ErrUnsupportedVersion) {
		t.Fatalf("err %v, want ErrUnsupportedVersion", err)
	}
}

func TestPullNowEventTriggersAPass(t *testing.T) {
	r := newRig(t)
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err != nil {
		t.Fatal(err)
	}
	r.fake.PullNow()
	r.nextEvent("pull_now", func(e transport.Event) bool { return e.PullNow })
	// A phone's write is a zone event for the one RelayZone.
	if _, err := r.fake.PhoneRecords(r.hub).Write("relay/acme/phone", "a-X-1", []byte("env"), transport.Expect{}); err != nil {
		t.Fatal(err)
	}
	r.nextEvent("relay zone", func(e transport.Event) bool { return e.Zone == r.c.MailboxFor("acme", "phone") })
	r.fake.SendError("rate_limited")
	r.nextEvent("error", func(e transport.Event) bool { return errors.Is(e.Err, transport.ErrRateLimited) })
	// A dropped connection is an Err event; the next op reconnects and the
	// reconnect is a pull_now (pushes may have been missed).
	r.fake.DropConnections()
	r.nextEvent("connection lost", func(e transport.Event) bool { return errors.Is(e.Err, transport.ErrUnavailable) })
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err != nil {
		t.Fatal(err)
	}
	r.nextEvent("pull_now after reconnect", func(e transport.Event) bool { return e.PullNow })
	if r.fake.Accepted() != 2 {
		t.Fatalf("%d connections, want 2", r.fake.Accepted())
	}
}

func TestFailureClassesMapToTransportErrors(t *testing.T) {
	r := newRig(t)
	for class, want := range map[string]error{
		"unavailable":         transport.ErrUnavailable,
		"token_expired":       transport.ErrTokenExpired,
		"rate_limited":        transport.ErrRateLimited,
		"record_too_large":    transport.ErrRecordTooLarge,
		"quota":               transport.ErrHubQuota,
		"forbidden":           transport.ErrForbidden,
		"unsupported_zone":    transport.ErrUnsupportedZone,
		"unsupported_version": transport.ErrUnsupportedVersion,
	} {
		r.fake.FailNext("changes", class)
		if _, err := r.c.Changes(r.ctx, dataZone, 0); !errors.Is(err, want) {
			t.Errorf("%s: %v", class, err)
		}
	}
	r.fake.FailNext("changes", "Some Text: /private/path")
	_, err := r.c.Changes(r.ctx, dataZone, 0)
	if err == nil || strings.Contains(err.Error(), "path") {
		t.Fatalf("an unknown class: %v", err)
	}
}

func TestSharesOverTheBridge(t *testing.T) {
	r := newRig(t)
	if a, err := r.c.AccountStatus(r.ctx); err != nil || a != transport.AccountAvailable {
		t.Fatalf("account %q, %v", a, err)
	}
	r.fake.SetAccount(transport.AccountNoAccount)
	if a, err := r.c.AccountStatus(r.ctx); err != nil || a != transport.AccountNoAccount {
		t.Fatalf("account %q, %v", a, err)
	}
	r.fake.SetAccount("weird")
	if _, err := r.c.AccountStatus(r.ctx); err == nil {
		t.Fatal("an unknown account state was accepted")
	}
	data, relay, err := r.c.EnsureShares(r.ctx)
	if err != nil || data == "" || relay == "" || data == relay {
		t.Fatalf("shares %q %q, %v", data, relay, err)
	}
	r.fake.FailNext("ensure_shares", "unavailable")
	if _, _, err := r.c.EnsureShares(r.ctx); !errors.Is(err, transport.ErrUnavailable) {
		t.Fatalf("ensure shares failure: %v", err)
	}
	if err := r.c.SetPublicLink(r.ctx, true); err != nil || !r.fake.PublicLink() {
		t.Fatalf("public link open: %v", err)
	}
	if err := r.c.SetPublicLink(r.ctx, false); err != nil || r.fake.PublicLink() {
		t.Fatalf("public link closed: %v", err)
	}
	relayCK := cloudkit.RelayZoneName(r.hub)
	r.fake.SetParticipants(relayCK, []transport.Participant{{UserRecordName: "_a", Accepted: true}, {UserRecordName: "_b"}})
	ps, err := r.c.Participants(r.ctx, "relay/acme/phone")
	if err != nil || len(ps) != 2 || ps[0] != (transport.Participant{UserRecordName: "_a", Accepted: true}) {
		t.Fatalf("participants %+v, %v", ps, err)
	}
	if err := r.c.RemoveParticipants(r.ctx, relayCK, []string{"_b"}); err != nil {
		t.Fatal(err)
	}
	if got := r.fake.ParticipantsOf(relayCK); len(got) != 1 || got[0].UserRecordName != "_a" {
		t.Fatalf("after remove: %+v", got)
	}
}

func TestLargeSavesSplitIntoFramesUnderTheCap(t *testing.T) {
	r := newRig(t)
	var items []transport.SaveItem
	for i := range 6 {
		payload := bytes.Repeat([]byte{'x'}, 800_000)
		items = append(items, transport.SaveItem{Record: r.data("session_chat-"+string(rune('a'+i)), payload)})
	}
	out := r.save(items...)
	for i, o := range out {
		if !o.Saved {
			t.Errorf("item %d: %+v", i, o)
		}
	}
	saves := 0
	for _, f := range r.fake.Frames() {
		if len(f) > cloudkit.MaxFrame {
			t.Errorf("a frame of %d bytes", len(f))
		}
		var q pb.Request
		_ = proto.Unmarshal(f, &q)
		if q.GetSave() != nil {
			saves++
		}
	}
	if saves < 2 {
		t.Fatalf("%d save frames, want the items split", saves)
	}
}
