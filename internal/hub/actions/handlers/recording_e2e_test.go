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
)

// TestRecordingUploadThroughTheProcessor runs a phone's upload through the
// processor and the real intake: the audio lands, the phone gets received.
func TestRecordingUploadThroughTheProcessor(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ident, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	keys, err := identity.NewKeyring(ident, st, clock)
	if err != nil {
		t.Fatal(err)
	}
	fake := memfake.New(transport.KindRelay, clock)
	disp := actions.NewDispatcher()
	recDir := filepath.Join(t.TempDir(), "recordings")
	Register(disp, Deps{Store: st, RecordingsDir: recDir, Clock: clock})
	proc := actions.NewProcessor(actions.Config{
		Store: st, Transport: fake, Sealer: secure.NewSealer(keys), Opener: secure.NewOpener(keys, keys), Keys: keys,
		Dispatcher: disp, HubRelayID: "hubrelaytest", Clock: clock,
	})
	meta, _ := keys.MetaKey()
	epoch, _ := keys.CurrentEpoch()
	ph, err := hubtest.New(hubtest.Config{
		Hub: keys.HubID(), HubKX: ident.Agreement.PublicKey(), MetaKey: meta, Epoch: epoch,
		HubRelayID: "hubrelaytest", Transport: fake, Clock: clock,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WithTx(ctx, func(tx *sql.Tx) error { return state.LinkDevice(tx, ph.Device()) }); err != nil {
		t.Fatal(err)
	}
	plain := bytes.Repeat([]byte("audio"), 900)
	sealed, desc, err := secure.EncryptAsset(plain, secure.ID{3}, make([]byte, 32), 1024)
	if err != nil {
		t.Fatal(err)
	}
	id := ph.ID()
	send := func(upload string) {
		b, _ := json.Marshal(map[string]any{"id": upload, "status": "pending", "device_id": id.String()})
		if _, err := ph.WriteUpload(upload, b, &desc, sealed); err != nil {
			t.Fatal(err)
		}
	}

	// Desktop never beat: final not_supported, nothing written.
	send("u0")
	if _, err := proc.Pass(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := ph.Sync(); err != nil {
		t.Fatal(err)
	}
	if e := ph.UploadEchoes["u0"]; e["status"] != "failed" || e["error_message"] != NotSupportedMessage {
		t.Fatalf("u0 echo %v", e)
	}
	if _, err := os.Stat(recDir); !os.IsNotExist(err) {
		t.Fatal("recordings dir created without a transcriber")
	}

	// Desktop running: received, audio on disk.
	if err := st.Heartbeat(now); err != nil {
		t.Fatal(err)
	}
	send("u1")
	if _, err := proc.Pass(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := ph.Sync(); err != nil {
		t.Fatal(err)
	}
	if e := ph.UploadEchoes["u1"]; e["status"] != "received" {
		t.Fatalf("u1 echo %v", e)
	}
	got, err := os.ReadFile(RecordingAudioPath(recDir, "u1"))
	if err != nil || !bytes.Equal(got, plain) {
		t.Fatalf("audio: %v", err)
	}
	if job, err := st.RecordingJob("u1"); err != nil || job.Status != state.RecordingQueued {
		t.Fatalf("job %+v %v", job, err)
	}

	// Desktop goes quiet: held, no file, then received once it beats again.
	now = now.Add(10 * time.Minute)
	send("u2")
	if _, err := proc.Pass(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := ph.Sync(); err != nil {
		t.Fatal(err)
	}
	if e := ph.UploadEchoes["u2"]; e["status"] != "held" {
		t.Fatalf("u2 echo %v", e)
	}
	if _, err := os.Stat(RecordingAudioPath(recDir, "u2")); !os.IsNotExist(err) {
		t.Fatal("audio written while held")
	}
	if err := st.Heartbeat(now); err != nil {
		t.Fatal(err)
	}
	if _, err := proc.Pass(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := ph.Sync(); err != nil {
		t.Fatal(err)
	}
	if e := ph.UploadEchoes["u2"]; e["status"] != "received" {
		t.Fatalf("u2 final echo %v", e)
	}
	if _, err := os.Stat(RecordingAudioPath(recDir, "u2")); err != nil {
		t.Fatal(err)
	}
}
