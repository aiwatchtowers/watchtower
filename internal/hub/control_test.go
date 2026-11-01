package hub

import (
	"bufio"
	"bytes"
	"encoding/json"
	"net"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
)

// watchLines dials the control socket, asks for desktop_watch and returns a
// reader of its raw lines (each decoded into a key → value map).
func watchLines(t *testing.T, dir string) func(time.Duration) (map[string]any, bool) {
	t.Helper()
	c, err := net.Dial("unix", filepath.Join(dir, SocketName))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	if err := json.NewEncoder(c).Encode(ControlRequest{Op: OpDesktopWatch}); err != nil {
		t.Fatal(err)
	}
	sc := bufio.NewScanner(c)
	next := func(wait time.Duration) (map[string]any, bool) {
		_ = c.SetReadDeadline(time.Now().Add(wait))
		if !sc.Scan() {
			return nil, false
		}
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			t.Fatalf("watch line %q: %v", sc.Text(), err)
		}
		return m, true
	}
	if a, ok := next(5 * time.Second); !ok || a["op"] != OpDesktopWatch || a["ok"] != true {
		t.Fatalf("desktop_watch answer: %v", a)
	}
	return next
}

// TestDesktopWatchStreamsRecordingQueued: a phone recording the intake
// answered received reaches Desktop's watch as one recording_queued line
// carrying the upload id only.
func TestDesktopWatchStreamsRecordingQueued(t *testing.T) {
	d, _ := fileDB(t)
	recordings := filepath.Join(t.TempDir(), "recordings")
	e := runEndToEnd(t, "", func(o *Options) { o.DB, o.RecordingsDir = d, recordings })
	ctl, err := Dial(e.dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ctl.Close() }()
	if a, err := ctl.Do(ControlRequest{Op: OpDesktopHeartbeat}); err != nil || !a.OK {
		t.Fatalf("heartbeat: %+v, %v", a, err)
	}
	next := watchLines(t, e.dir)

	sealed, desc, err := secure.EncryptAsset(bytes.Repeat([]byte{0x41}, 2000), secure.ID{7}, bytes.Repeat([]byte{9}, 32), 1024)
	if err != nil {
		t.Fatal(err)
	}
	upload, _ := json.Marshal(map[string]any{"id": "u1", "status": "pending", "device_id": e.phone.ID().String()})
	if _, err := e.phone.WriteUpload("u1", upload, &desc, sealed); err != nil {
		t.Fatal(err)
	}
	eventually(t, 20*time.Second, "the upload received", func() bool {
		if _, err := e.phone.Sync(); err != nil {
			t.Fatal(err)
		}
		return e.phone.UploadEchoes["u1"]["status"] == "received"
	})

	var queued []map[string]any
	for {
		m, ok := next(2 * time.Second)
		if !ok {
			break
		}
		if m["event"] == EventRecordingQueued {
			queued = append(queued, m)
		}
	}
	if len(queued) != 1 {
		t.Fatalf("recording_queued lines: %v, want one", queued)
	}
	var keys []string
	for k := range queued[0] {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	if !slices.Equal(keys, []string{"event", "ok", "upload_id"}) || queued[0]["upload_id"] != "u1" {
		t.Errorf("recording_queued = %v, want only the upload id", queued[0])
	}
}

// TestDesktopWatchHearsPairStepsWithoutCodes: a pairing step reaches the
// watch as a pair event with its kind and phone, never the URL or the code;
// a status change as a status event.
func TestDesktopWatchHearsPairStepsWithoutCodes(t *testing.T) {
	w := &pairListener{queue: make(chan ControlAnswer, 4)}
	s := &supervisor{o: Options{Dir: t.TempDir()}, pairs: map[*pairListener]bool{}, watches: map[*pairListener]bool{w: true}}
	s.broadcast(link.PairEvent{Kind: link.EventSAS, DeviceID: "AAAA", Code: "1234", URL: "https://example.com/l"})
	s.setStatus(Status{State: StateRunning})
	pair, status := <-w.queue, <-w.queue
	if pair.Event != EventPair || pair.Pair != link.EventSAS || pair.DeviceID != "AAAA" || pair.Code != "" || pair.URL != "" {
		t.Errorf("pair event = %+v", pair)
	}
	if status.Event != EventStatus || status.State != StateRunning {
		t.Errorf("status event = %+v", status)
	}
}

// TestRecordingProgressOverTheSocket: recording_progress stores the phase of
// a claimed job and answers it; a bad progress is a bad request.
func TestRecordingProgressOverTheSocket(t *testing.T) {
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	s := &supervisor{o: Options{Clock: time.Now}, st: st}
	now := time.Now()
	_ = st.QueueRecording("u1", "AAAAAAAA-0000-4000-8000-000000000001", now)
	if _, err := st.ClaimRecording("u1", now); err != nil {
		t.Fatal(err)
	}
	forty := 40
	a := s.handle(ControlRequest{Op: OpRecordingProgress, Upload: "u1", Phase: state.PhaseTranscribing, Percent: &forty}, nil)
	if !a.OK || a.Status != state.RecordingClaimed || a.Phase != state.PhaseTranscribing || a.Percent == nil || *a.Percent != 40 {
		t.Errorf("progress = %+v", a)
	}
	if a := s.handle(ControlRequest{Op: OpRecordingProgress, Upload: "u1", Phase: state.PhaseDiarizing, Percent: &forty}, nil); a.Error != ErrClassBadRequest {
		t.Errorf("a percent while diarizing = %+v", a)
	}
	if a := s.handle(ControlRequest{Op: OpRecordingProgress, Upload: "nope", Phase: state.PhaseDiarizing}, nil); a.Error != ErrClassNoJob {
		t.Errorf("no job = %+v", a)
	}
}
