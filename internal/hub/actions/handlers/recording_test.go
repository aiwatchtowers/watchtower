package handlers

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

type recEnv struct {
	t     *testing.T
	h     *Handlers
	store *state.Store
	dir   string
	now   time.Time
	hub   secure.ID
}

func newRecEnv(t *testing.T) *recEnv {
	t.Helper()
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	e := &recEnv{t: t, store: st, dir: filepath.Join(t.TempDir(), "recordings"), now: time.Unix(1_800_000_000, 0), hub: secure.ID{9}}
	e.h = Register(actions.NewDispatcher(), Deps{Store: st, RecordingsDir: e.dir, Clock: func() time.Time { return e.now }})
	return e
}

func (e *recEnv) beat(at time.Time) {
	e.t.Helper()
	if err := e.store.Heartbeat(at); err != nil {
		e.t.Fatal(err)
	}
}

// upload seals plain and returns the intake whose Download writes it.
func (e *recEnv) upload(id string, plain []byte) RecordingIntake {
	e.t.Helper()
	key := make([]byte, 32)
	sealed, d, err := secure.EncryptAsset(plain, secure.ID{1}, key, 1024)
	if err != nil {
		e.t.Fatal(err)
	}
	return RecordingIntake{
		Device: secure.ID{0x0a}, UploadID: id, ThisHub: e.hub, Descriptor: &d,
		Download: func(_ context.Context, dst string) error { return os.WriteFile(dst, sealed, 0o600) },
	}
}

func (e *recEnv) files() []string {
	ents, _ := os.ReadDir(e.dir)
	var out []string
	for _, f := range ents {
		out = append(out, f.Name())
	}
	return out
}

func TestRecordingReceivedWhenTranscriberFresh(t *testing.T) {
	e := newRecEnv(t)
	e.beat(e.now.Add(-10 * time.Second))
	plain := bytes.Repeat([]byte("aud"), 2000)
	out := e.h.IntakeRecording(context.Background(), e.upload("u-1", plain))
	if out.Status != wire.StatusReceived {
		t.Fatalf("outcome %+v", out)
	}
	path := RecordingAudioPath(e.dir, "u-1")
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, plain) {
		t.Fatalf("audio: %v", err)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
	if names := e.files(); len(names) != 1 {
		t.Fatalf("leftovers: %v", names)
	}
	job, err := e.store.RecordingJob("u-1")
	if err != nil || job.Status != state.RecordingQueued {
		t.Fatalf("job %+v %v", job, err)
	}
	// a retry of the same upload is answered received, nothing queued twice
	if out := e.h.IntakeRecording(context.Background(), e.upload("u-1", plain)); out.Status != wire.StatusReceived {
		t.Fatalf("retry %+v", out)
	}
}

func TestRecordingHeldWithoutTranscriberWritesNoFile(t *testing.T) {
	e := newRecEnv(t)
	e.beat(e.now.Add(-time.Hour)) // seen once, long stale
	in := e.upload("u-1", []byte("audio"))
	downloaded := false
	dl := in.Download
	in.Download = func(c context.Context, dst string) error { downloaded = true; return dl(c, dst) }
	out := e.h.IntakeRecording(context.Background(), in)
	if out.Status != wire.StatusHeld || out.Reason != "" {
		t.Fatalf("outcome %+v", out)
	}
	if downloaded || len(e.files()) != 0 {
		t.Fatalf("downloaded=%v files=%v", downloaded, e.files())
	}
	if _, err := e.store.RecordingJob("u-1"); !errors.Is(err, state.ErrNoRecordingJob) {
		t.Fatal("a job was queued")
	}
	// the next pass with a fresh Desktop takes it
	e.beat(e.now)
	if out := e.h.IntakeRecording(context.Background(), e.upload("u-1", []byte("audio"))); out.Status != wire.StatusReceived {
		t.Fatalf("after heartbeat %+v", out)
	}
}

func TestRecordingOnAHostThatNeverHadDesktopFailsNotSupported(t *testing.T) {
	e := newRecEnv(t)
	out := e.h.IntakeRecording(context.Background(), e.upload("u-1", []byte("audio")))
	if out.Status != wire.StatusFailed || out.Reason != "not_supported" {
		t.Fatalf("outcome %+v", out)
	}
	if _, err := os.Stat(e.dir); !os.IsNotExist(err) {
		t.Fatalf("recordings dir was created: %v", err)
	}
}

func TestRecordingFailuresLeaveNoFile(t *testing.T) {
	cases := map[string]func(e *recEnv) RecordingIntake{
		"no asset": func(e *recEnv) RecordingIntake {
			in := e.upload("u-1", []byte("a"))
			in.Descriptor = nil
			return in
		},
		"download fails": func(e *recEnv) RecordingIntake {
			in := e.upload("u-1", []byte("a"))
			in.Download = func(context.Context, string) error { return errors.New("gone") }
			return in
		},
		"empty": func(e *recEnv) RecordingIntake { return e.upload("u-1", nil) },
		"tampered": func(e *recEnv) RecordingIntake {
			in := e.upload("u-1", bytes.Repeat([]byte("a"), 3000))
			dl := in.Download
			in.Download = func(c context.Context, dst string) error {
				if err := dl(c, dst); err != nil {
					return err
				}
				b, _ := os.ReadFile(dst)
				b[5] ^= 1
				return os.WriteFile(dst, b, 0o600)
			}
			return in
		},
		"bad id": func(e *recEnv) RecordingIntake { return e.upload("../x", []byte("a")) },
	}
	for name, mk := range cases {
		t.Run(name, func(t *testing.T) {
			e := newRecEnv(t)
			e.beat(e.now)
			out := e.h.IntakeRecording(context.Background(), mk(e))
			if out.Status != wire.StatusFailed {
				t.Fatalf("outcome %+v", out)
			}
			if names := e.files(); len(names) != 0 {
				t.Fatalf("files left: %v", names)
			}
		})
	}
}

func TestRecordingMissingAudioAndTooLarge(t *testing.T) {
	e := newRecEnv(t)
	e.beat(e.now)
	in := e.upload("u-1", []byte("a"))
	in.Descriptor = nil
	if out := e.h.IntakeRecording(context.Background(), in); out.Reason != reasonNotFound || out.Message != MissingAudioMessage {
		t.Fatalf("missing: %+v", out)
	}
	in = e.upload("u-2", []byte("a"))
	in.Descriptor.Header.TotalLength = MaxRecordingAssetBytes + 1
	called := false
	in.Download = func(context.Context, string) error { called = true; return nil }
	if out := e.h.IntakeRecording(context.Background(), in); out.Reason != reasonInvalidParams || out.Message != TooLargeMessage {
		t.Fatalf("too large: %+v", out)
	}
	if called {
		t.Fatal("an oversized asset was downloaded")
	}
}

func TestRecordingOversizedDownloadIsRefusedUndecrypted(t *testing.T) {
	e := newRecEnv(t)
	e.beat(e.now)
	in := e.upload("u-1", []byte("small"))
	in.Download = func(_ context.Context, dst string) error {
		return os.WriteFile(dst, make([]byte, 1<<20), 0o600)
	}
	out := e.h.IntakeRecording(context.Background(), in)
	if out.Reason != reasonInvalidParams || len(e.files()) != 0 {
		t.Fatalf("%+v files=%v", out, e.files())
	}
}

func TestRecordingWrongHub(t *testing.T) {
	e := newRecEnv(t)
	e.beat(e.now)
	in := e.upload("u-1", []byte("a"))
	other := secure.ID{7}
	in.TargetHub = &other
	if out := e.h.IntakeRecording(context.Background(), in); out.Reason != reasonWrongHub {
		t.Fatalf("%+v", out)
	}
}

func TestDesktopHostDepFollowsTheHeartbeat(t *testing.T) {
	e := newRecEnv(t)
	if e.h.d.DesktopHost() {
		t.Fatal("host before a beat")
	}
	e.beat(e.now)
	if !e.h.d.DesktopHost() {
		t.Fatal("no host after a beat")
	}
	e.now = e.now.Add(91 * time.Second)
	if e.h.d.DesktopHost() {
		t.Fatal("host after 91 s")
	}
}

func TestFILES01_RecordingLogsNoNames(t *testing.T) {
	sink := logcanary.Capture(t)
	e := newRecEnv(t)
	e.beat(e.now)
	// a recordings dir that cannot be created, a download that errors with
	// the canary, a corrupt asset: every log line stays free of content.
	canary := logcanary.Text("recording")
	blocked := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocked, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	e.h.d.RecordingsDir = filepath.Join(blocked, canary)
	in := e.upload("u-1", []byte("a"))
	e.h.IntakeRecording(context.Background(), in)
	e.h.d.RecordingsDir = e.dir
	in.Download = func(context.Context, string) error { return errors.New(canary) }
	e.h.IntakeRecording(context.Background(), in)
	sink.AssertClean(t)
}

func TestSweepRecordingTempsRemovesCrashLeftovers(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	keep := []string{filepath.Join(a, "u-1.m4a"), filepath.Join(b, "notes.txt")}
	drop := []string{filepath.Join(a, ".asset-123"), filepath.Join(a, ".u-2.sealed"), filepath.Join(b, ".asset-9")}
	for _, f := range append(append([]string{}, keep...), drop...) {
		if err := os.WriteFile(f, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	n, err := SweepRecordingTemps(a, b, filepath.Join(a, "missing"))
	if err != nil || n != len(drop) {
		t.Fatalf("swept %d, %v", n, err)
	}
	for _, f := range drop {
		if _, err := os.Stat(f); !os.IsNotExist(err) {
			t.Fatalf("%s survived", f)
		}
	}
	for _, f := range keep {
		if _, err := os.Stat(f); err != nil {
			t.Fatalf("%s removed", f)
		}
	}
}
