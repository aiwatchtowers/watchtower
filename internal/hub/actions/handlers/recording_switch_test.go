package handlers

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/logcanary"
)

// switchWorld is a phone, the processor and the real intake over one
// sidecar; restart builds a new processor over the same sidecar and relay,
// as a hub restart does (nothing kept in memory).
type switchWorld struct {
	t      *testing.T
	ctx    context.Context
	now    time.Time
	st     *state.Store
	keys   *identity.Keyring
	fake   *memfake.Fake
	recDir string
	proc   *actions.Processor
	ph     *hubtest.Phone
	desc   secure.AssetDescriptor
	sealed []byte
}

func newSwitchWorld(t *testing.T) *switchWorld {
	t.Helper()
	w := &switchWorld{t: t, ctx: context.Background(), now: time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)}
	var err error
	if w.st, err = state.Open(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = w.st.Close() })
	ident, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	if w.keys, err = identity.NewKeyring(ident, w.st, w.clock); err != nil {
		t.Fatal(err)
	}
	w.fake = memfake.New(transport.KindRelay, w.clock)
	w.recDir = filepath.Join(t.TempDir(), "recordings")
	w.restart()
	meta, _ := w.keys.MetaKey()
	epoch, _ := w.keys.CurrentEpoch()
	if w.ph, err = hubtest.New(hubtest.Config{
		Hub: w.keys.HubID(), HubKX: ident.Agreement.PublicKey(), MetaKey: meta, Epoch: epoch,
		HubRelayID: "hubrelaytest", Transport: w.fake, Clock: w.clock,
	}); err != nil {
		t.Fatal(err)
	}
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.LinkDevice(tx, w.ph.Device()) }); err != nil {
		t.Fatal(err)
	}
	if w.sealed, w.desc, err = secure.EncryptAsset(bytes.Repeat([]byte("audio"), 300), secure.ID{3}, make([]byte, 32), 1024); err != nil {
		t.Fatal(err)
	}
	return w
}

func (w *switchWorld) clock() time.Time { return w.now }

func (w *switchWorld) restart() {
	disp := actions.NewDispatcher()
	Register(disp, Deps{Store: w.st, RecordingsDir: w.recDir, Clock: w.clock})
	w.proc = actions.NewProcessor(actions.Config{
		Store: w.st, Transport: w.fake, Sealer: secure.NewSealer(w.keys), Opener: secure.NewOpener(w.keys, w.keys), Keys: w.keys,
		Dispatcher: disp, HubRelayID: "hubrelaytest", Clock: w.clock,
	})
}

func (w *switchWorld) send(upload string) {
	w.t.Helper()
	id := w.ph.ID()
	b, _ := json.Marshal(map[string]any{
		"id": upload, "status": "pending", "device_id": id.String(), "title_hint": logcanary.Text("title"),
		"started_at": 1730000000, "ended_at": 1730000060, "duration_sec": 60, "sample_format": "aac-64k-mono",
	})
	if _, err := w.ph.WriteUpload(upload, b, &w.desc, w.sealed); err != nil {
		w.t.Fatal(err)
	}
}

func (w *switchWorld) pass() {
	w.t.Helper()
	if _, err := w.proc.Pass(w.ctx); err != nil {
		w.t.Fatal(err)
	}
	if _, err := w.ph.Sync(); err != nil {
		w.t.Fatal(err)
	}
}

func (w *switchWorld) wantEcho(upload, status, reason string) map[string]any {
	w.t.Helper()
	e := w.ph.UploadEchoes[upload]
	if e["status"] != status {
		w.t.Fatalf("%s echo %v, want %s", upload, e, status)
	}
	got, has := e["reason"]
	switch {
	case reason == "" && has:
		w.t.Fatalf("%s echo carries a reason: %v", upload, e)
	case reason != "" && got != reason:
		w.t.Fatalf("%s echo reason %v, want %s", upload, got, reason)
	}
	return e
}

func (w *switchWorld) wantNoAudio() {
	w.t.Helper()
	ents, _ := os.ReadDir(w.recDir)
	if len(ents) != 0 {
		w.t.Fatalf("files under the recordings dir: %d", len(ents))
	}
}

func (w *switchWorld) setRecordings(on bool) {
	w.t.Helper()
	if err := w.st.SetRecordings(on); err != nil {
		w.t.Fatal(err)
	}
}

// hold beats long ago (Desktop seen, now away) and gets ids held.
func (w *switchWorld) hold(ids ...string) {
	w.t.Helper()
	if err := w.st.Heartbeat(w.now.Add(-time.Hour)); err != nil {
		w.t.Fatal(err)
	}
	for _, id := range ids {
		w.send(id)
	}
	w.pass()
	for _, id := range ids {
		w.wantEcho(id, "held", "")
	}
}

func TestSwitchOffFailsUploadsNotSupported(t *testing.T) {
	w := newSwitchWorld(t)
	if err := w.st.Heartbeat(w.now); err != nil { // Desktop fresh: only the switch refuses
		t.Fatal(err)
	}
	w.setRecordings(false)
	w.send("u1")
	w.pass()
	e := w.wantEcho("u1", "failed", "not_supported")
	if e["error_message"] != NotSupportedMessage {
		t.Fatalf("message %v", e["error_message"])
	}
	w.wantNoAudio()
	if _, err := os.Stat(w.recDir); !os.IsNotExist(err) {
		t.Fatal("the recordings dir was created with the switch off")
	}
}

func TestNeverSeenDesktopFailsNotSupportedWithAReason(t *testing.T) {
	w := newSwitchWorld(t)
	w.send("u1")
	w.pass()
	w.wantEcho("u1", "failed", "not_supported")
	w.wantNoAudio()
}

func TestReceivedEchoHasNoReason(t *testing.T) {
	w := newSwitchWorld(t)
	if err := w.st.Heartbeat(w.now); err != nil {
		t.Fatal(err)
	}
	w.send("u1")
	w.pass()
	w.wantEcho("u1", "received", "")
}

func TestTurningOffFailsEveryHeldUpload(t *testing.T) {
	w := newSwitchWorld(t)
	w.hold("u1", "u2")
	w.setRecordings(false)
	w.now = w.now.Add(time.Minute)
	w.pass()
	for _, id := range []string{"u1", "u2"} {
		w.wantEcho(id, "failed", "not_supported")
	}
	w.wantNoAudio()
	if held, err := w.st.HeldUploads(); err != nil || len(held) != 0 {
		t.Fatalf("still held: %+v %v", held, err)
	}
}

func TestHeldUploadExpiresAfter7Days(t *testing.T) {
	w := newSwitchWorld(t)
	t0 := w.now
	w.hold("u1")
	w.now = t0.Add(6*24*time.Hour + 23*time.Hour)
	w.pass()
	w.wantEcho("u1", "held", "")
	w.now = t0.Add(state.HeldUploadMaxAge)
	w.pass()
	e := w.wantEcho("u1", "failed", "expired")
	if e["error_message"] == nil {
		t.Fatal("an expired upload has no message for the owner")
	}
	w.wantNoAudio()
}

func TestHeldUploadExpirySurvivesARestart(t *testing.T) {
	w := newSwitchWorld(t)
	t0 := w.now
	w.hold("u1")
	held, err := w.st.HeldUploads()
	if err != nil || len(held) != 1 || !held[0].HeldAt.Equal(t0) {
		t.Fatalf("held %+v %v", held, err)
	}
	// More passes while still held leave the first hold's time alone.
	for range 3 {
		w.now = w.now.Add(time.Hour)
		w.pass()
	}
	w.restart()
	w.now = w.now.Add(time.Hour)
	w.pass() // a restarted hub that is not due yet leaves the hold as it is
	w.wantEcho("u1", "held", "")
	w.restart()
	w.now = t0.Add(state.HeldUploadMaxAge)
	w.pass()
	e := w.wantEcho("u1", "failed", "expired")
	for _, k := range []string{"started_at", "duration_sec", "sample_format", "device_id"} {
		if _, ok := e[k]; !ok {
			t.Fatalf("the echo after a restart lost %s: %v", k, e)
		}
	}
	if held, _ := w.st.HeldUploads(); len(held) != 0 {
		t.Fatalf("still held: %+v", held)
	}
}

func TestSwitchOffAfterARestartFailsTheHeldUpload(t *testing.T) {
	w := newSwitchWorld(t)
	w.hold("u1")
	w.restart()
	w.setRecordings(false)
	w.pass()
	w.wantEcho("u1", "failed", "not_supported")
}

func TestFILES01_RecordingSwitchLogsNoNames(t *testing.T) {
	sink := logcanary.Capture(t)
	w := newSwitchWorld(t)
	w.hold("u1", "u2")
	w.restart()
	w.setRecordings(false)
	w.pass()
	w.restart()
	w.send("u3")
	w.pass()
	sink.AssertClean(t)
}
