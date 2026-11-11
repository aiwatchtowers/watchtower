package hub

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
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
	eventually(t, "the upload received", func() bool {
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

// TestRecordingClaimAnswerCarriesTheAudioPath: Desktop never derives the
// audio's place itself (it never reads the sidecar): the claim's answer
// names the file, <recordings dir>/<upload id>.m4a; a finish names none,
// nor does a hub with no recordings dir.
func TestRecordingClaimAnswerCarriesTheAudioPath(t *testing.T) {
	r := newViewRig(t)
	st, s := r.s.st, r.s
	s.o.RecordingsDir = filepath.Join(t.TempDir(), "recordings")
	_ = st.QueueRecording("u1", "AAAAAAAA-0000-4000-8000-000000000001", time.Now())
	a := s.handle(ControlRequest{Op: OpRecordingClaim, Upload: "u1"}, nil)
	if !a.OK || a.Status != state.RecordingClaimed || a.AudioPath != filepath.Join(s.o.RecordingsDir, "u1.m4a") {
		t.Errorf("claim = %+v", a)
	}
	tid := int64(3)
	if a := s.handle(ControlRequest{Op: OpRecordingFinish, Upload: "u1", TranscriptID: &tid}, nil); !a.OK || a.AudioPath != "" {
		t.Errorf("finish = %+v, want no audio path", a)
	}
	s.o.RecordingsDir = ""
	_ = st.QueueRecording("u2", "AAAAAAAA-0000-4000-8000-000000000001", time.Now())
	if a := s.handle(ControlRequest{Op: OpRecordingClaim, Upload: "u2"}, nil); !a.OK || a.AudioPath != "" ||
		a.EventID != "" || a.StartedAt != nil {
		t.Errorf("claim without a recordings dir or an origin = %+v", a)
	}
}

// TestRecordingClaimAnswerCarriesTheOrigin: the claim names the calendar
// event the phone recorded for and its start, so Desktop links the
// transcript and derives the phone's title; never the title itself.
func TestRecordingClaimAnswerCarriesTheOrigin(t *testing.T) {
	r := newViewRig(t)
	st, s := r.s.st, r.s
	started := time.Unix(1_800_000_000, 0)
	if err := st.QueueRecordingFrom("u1", "AAAAAAAA-0000-4000-8000-000000000001",
		state.RecordingOrigin{EventID: "evt-1", StartedAt: started}, time.Now()); err != nil {
		t.Fatal(err)
	}
	a := s.handle(ControlRequest{Op: OpRecordingClaim, Upload: "u1"}, nil)
	if !a.OK || a.EventID != "evt-1" || a.StartedAt == nil || !a.StartedAt.Equal(started) {
		t.Errorf("claim = %+v", a)
	}
	line, _ := json.Marshal(a)
	if !bytes.Contains(line, []byte(`"started_at":1800000000`)) {
		t.Errorf("started_at goes as Unix seconds: %s", line)
	}
}

// TestRecordingProgressOverTheSocket: recording_progress stores the phase of
// a claimed job, answers it and republishes the recording_job slice; a bad
// progress is a bad request and republishes nothing.
func TestRecordingProgressOverTheSocket(t *testing.T) {
	r := newViewRig(t)
	st, s := r.s.st, r.s
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
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.kinds) != 1 || !slices.Equal(r.kinds[0], []hubslices.Kind{recordingJobKind}) {
		t.Errorf("publishes %v, want one of recording_job", r.kinds)
	}
}

// TestDesktopWatchAnswerComesFirstWithAStatusSnapshot: the desktop_watch
// answer is the stream's first line, carrying the current status, however
// many events race with the subscription.
func TestDesktopWatchAnswerComesFirstWithAStatusSnapshot(t *testing.T) {
	for i := 0; i < 20; i++ {
		s := &supervisor{o: Options{Dir: t.TempDir()}.withDefaults(), pairs: map[*pairListener]bool{}, watches: map[*pairListener]bool{}}
		s.status = Status{State: StateOff, Reason: ReasonDisabled}
		client, server := net.Pipe()
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan struct{})
		go func() { defer close(done); s.serveConn(ctx, server) }()
		stop := make(chan struct{})
		var spam sync.WaitGroup
		spam.Add(1)
		go func() {
			defer spam.Done()
			// Fewer events than a stream's queue holds: the client reads
			// only the first line, and a full queue would drop it.
			for sent := 0; sent < pairQueue/2; {
				select {
				case <-stop:
					return
				default:
					s.pairMu.Lock()
					subscribed := len(s.watches) > 0
					s.pairMu.Unlock()
					s.notifyDesktop(ControlAnswer{Event: EventRecordingQueued, OK: true, UploadID: "u1"})
					if subscribed {
						sent++
					}
				}
			}
		}()
		if err := json.NewEncoder(client).Encode(ControlRequest{Op: OpDesktopWatch}); err != nil {
			t.Fatal(err)
		}
		var first ControlAnswer
		if err := json.NewDecoder(client).Decode(&first); err != nil {
			t.Fatal(err)
		}
		close(stop)
		spam.Wait()
		cancel()
		_ = client.Close()
		<-done
		if first.Op != OpDesktopWatch || !first.OK || first.Event != "" || first.State != StateOff || first.Reason != ReasonDisabled {
			t.Fatalf("first line %+v, want the answer with the status snapshot", first)
		}
	}
}

// TestDesktopWatchHearsATypingRequest (PROJ-16, OD-2): the link center's
// typing request (link.TestATypingRequestAsksTheOwnerOnce pins once per
// request) reaches Desktop's watch as one typing_request line with the
// phone's device id and display name, and nothing else.
func TestDesktopWatchHearsATypingRequest(t *testing.T) {
	w := &pairListener{queue: make(chan ControlAnswer, 1)}
	s := &supervisor{o: Options{Dir: t.TempDir()}, pairs: map[*pairListener]bool{}, watches: map[*pairListener]bool{w: true}}
	h := &hubRuntime{sup: s}
	h.typingRequested("AAAA", "Colleague A's iPhone")
	raw, err := json.Marshal(<-w.queue)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != `{"event":"typing_request","ok":true,"device_id":"AAAA","name":"Colleague A's iPhone"}` {
		t.Errorf("typing_request = %s", raw)
	}
	(&hubRuntime{}).typingRequested("AAAA", "x") // no supervisor (tests): nothing, no panic
}

// TestDesktopWatchHearsDevicesChanged: a link-center change of the phones
// (device_grant) reaches the watch as one bare devices_changed line, so
// Desktop reads the phones count again; another kind sends nothing.
func TestDesktopWatchHearsDevicesChanged(t *testing.T) {
	w := &pairListener{queue: make(chan ControlAnswer, 2)}
	s := &supervisor{o: Options{Dir: t.TempDir()}, pairs: map[*pairListener]bool{}, watches: map[*pairListener]bool{w: true}}
	h := &hubRuntime{sup: s}
	h.devicesChanged([]string{"workbench"})
	h.devicesChanged([]string{link.KindDeviceGrant})
	raw, err := json.Marshal(<-w.queue)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != `{"event":"devices_changed","ok":true}` || len(w.queue) != 0 {
		t.Errorf("devices_changed = %s, %d more", raw, len(w.queue))
	}
}

// TestDesktopWatchHearsBringForward: the bring_forward event carries the
// workbench and the session only.
func TestDesktopWatchHearsBringForward(t *testing.T) {
	w := &pairListener{queue: make(chan ControlAnswer, 1)}
	s := &supervisor{o: Options{Dir: t.TempDir()}, pairs: map[*pairListener]bool{}, watches: map[*pairListener]bool{w: true}}
	s.notifyDesktop(ControlAnswer{Event: EventBringForward, OK: true, WorkbenchID: 3, SessionID: 9})
	raw, err := json.Marshal(<-w.queue)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != `{"event":"bring_forward","ok":true,"workbench_id":3,"session_id":9}` {
		t.Errorf("bring_forward = %s", raw)
	}
}
