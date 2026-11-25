package hub

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
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
	"watchtower/internal/hub/wire"
)

// watchLines connects to r's control socket, asks for desktop_watch and
// returns a reader of its raw lines (each decoded into a key → value map).
// next(wait) gives up after wait with no line (0 = no bound); r runs in a
// bubble, so the wait is on the bubble's clock.
func watchLines(t *testing.T, r *rig) func(wait time.Duration) (map[string]any, bool) {
	t.Helper()
	c := r.dial()
	t.Cleanup(func() { _ = c.Close() })
	if err := c.Send(ControlRequest{Op: OpDesktopWatch}); err != nil {
		t.Fatal(err)
	}
	sc := bufio.NewScanner(c.c)
	next := func(wait time.Duration) (map[string]any, bool) {
		deadline := time.Time{}
		if wait > 0 {
			deadline = time.Now().Add(wait)
		}
		_ = c.c.SetReadDeadline(deadline)
		if !sc.Scan() {
			return nil, false
		}
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			t.Fatalf("watch line %q: %v", sc.Text(), err)
		}
		return m, true
	}
	if a, ok := next(0); !ok || a["op"] != OpDesktopWatch || a["ok"] != true {
		t.Fatalf("desktop_watch answer: %v", a)
	}
	return next
}

// TestDesktopWatchStreamsRecordingQueued: a phone recording the intake
// answered received reaches Desktop's watch as one recording_queued line
// carrying the upload id only.
func TestDesktopWatchStreamsRecordingQueued(t *testing.T) {
	bubble(t, func(t *testing.T) {
		d, _ := fileDB(t)
		recordings := filepath.Join(t.TempDir(), "recordings")
		e := runEndToEnd(t, "", func(o *Options) { o.DB, o.RecordingsDir = d, recordings })
		ctl := e.rig.dial()
		defer func() { _ = ctl.Close() }()
		if a, err := ctl.Do(ControlRequest{Op: OpDesktopHeartbeat}); err != nil || !a.OK {
			t.Fatalf("heartbeat: %+v, %v", a, err)
		}
		next := watchLines(t, e.rig)

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
			m, ok := next(2 * time.Second) // a quiet window on the bubble's clock
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
	})
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

// Two pairing streams at once: each is shown only its own code (the qr and
// waiting carrying its token) and the events of phones under that code (by
// nonce); neither sees the other's qr, SAS or refusal, and neither records
// the other's SAS. An earlier code's refusal reaches only the stream that
// asked for that code.
func TestPairStreamsSeeOnlyTheirOwnCodes(t *testing.T) {
	a := &pairListener{token: "stream-a", queue: make(chan ControlAnswer, 8), codes: map[string]pairShown{}}
	b := &pairListener{token: "stream-b", queue: make(chan ControlAnswer, 8), codes: map[string]pairShown{}}
	s := &supervisor{o: Options{Dir: t.TempDir()}, pairs: map[*pairListener]bool{a: true, b: true}, watches: map[*pairListener]bool{}}
	s.broadcast(link.PairEvent{Kind: link.EventQR, URL: "https://example.com/a", Nonce: "na", Token: "stream-a"})
	s.broadcast(link.PairEvent{Kind: link.EventWaiting, Nonce: "na", Token: "stream-a"})
	s.broadcast(link.PairEvent{Kind: link.EventSAS, DeviceID: "AAAA", Code: "1234", Nonce: "na"})
	s.broadcast(link.PairEvent{Kind: link.EventQR, URL: "https://example.com/b", Nonce: "nb", Token: "stream-b"})
	s.broadcast(link.PairEvent{Kind: link.EventRefused, DeviceID: "AAAA", Reason: wire.RefusedExpiredCode, Nonce: "na"})
	s.broadcast(link.PairEvent{Kind: link.EventSAS, DeviceID: "BBBB", Code: "5678", Nonce: "nb"})
	events := func(p *pairListener) []string {
		var got []string
		for len(p.queue) > 0 {
			ev := <-p.queue
			got = append(got, ev.Event+":"+ev.DeviceID+ev.URL)
		}
		return got
	}
	if got, want := events(a), []string{"qr:https://example.com/a", "waiting:", "sas:AAAA", "refused:AAAA"}; !slices.Equal(got, want) {
		t.Fatalf("A's events %v, want %v", got, want)
	}
	if got, want := events(b), []string{"qr:https://example.com/b", "sas:BBBB"}; !slices.Equal(got, want) {
		t.Fatalf("B's events %v, want %v", got, want)
	}
	if _, ok := b.code("AAAA"); ok {
		t.Error("B recorded A's SAS")
	}
	if _, ok := a.code("BBBB"); ok {
		t.Error("A recorded B's SAS")
	}
}

// A refusal goes only to the streams that showed that phone's request under
// the refused code, or whose newest code is the refused one (#2385). A
// stream that asked again (a relay code after its CloudKit code) is not
// ended by a hello on its replaced code from a phone it never showed; a
// phone it did show still reaches it. A refusal no stream matches, or one
// naming no code, is sent to none.
func TestARefusalReachesOnlyTheStreamsThatShowedItsRequest(t *testing.T) {
	events := func(p *pairListener) []string {
		var got []string
		for len(p.queue) > 0 {
			ev := <-p.queue
			got = append(got, ev.Event+":"+ev.DeviceID)
		}
		return got
	}
	a := &pairListener{token: "stream-a", queue: make(chan ControlAnswer, 16), codes: map[string]pairShown{}}
	b := &pairListener{token: "stream-b", queue: make(chan ControlAnswer, 16), codes: map[string]pairShown{}}
	s := &supervisor{o: Options{Dir: t.TempDir()}, pairs: map[*pairListener]bool{a: true, b: true}, watches: map[*pairListener]bool{}}
	// A: an iCloud code, a phone's SAS under it, then a relay code.
	s.broadcast(link.PairEvent{Kind: link.EventQR, URL: "https://example.com/ck", Nonce: "n-ck", Token: "stream-a"})
	s.broadcast(link.PairEvent{Kind: link.EventSAS, DeviceID: "AAAA", Code: "1234", Nonce: "n-ck"})
	s.broadcast(link.PairEvent{Kind: link.EventQR, URL: "https://example.com/relay", Nonce: "n-relay", Token: "stream-a"})
	// B: one code, no phone.
	s.broadcast(link.PairEvent{Kind: link.EventQR, URL: "https://example.com/b", Nonce: "n-b", Token: "stream-b"})
	events(a)
	events(b)

	// Another phone scans A's replaced iCloud code: A never showed it.
	s.broadcast(link.PairEvent{Kind: link.EventRefused, DeviceID: "CCCC", Reason: wire.RefusedExpiredCode, Nonce: "n-ck"})
	if got := events(a); len(got) != 0 {
		t.Fatalf("the relay-code stream got %v for a phone it never showed", got)
	}
	// The phone A showed under that code is refused: A hears it.
	s.broadcast(link.PairEvent{Kind: link.EventRefused, DeviceID: "aaaa", Reason: wire.RefusedUsedCode, Nonce: "n-ck"})
	if got, want := events(a), []string{"refused:aaaa"}; !slices.Equal(got, want) {
		t.Fatalf("A's events %v, want %v", got, want)
	}
	// The same phone refused under another code than the one A showed it on.
	s.broadcast(link.PairEvent{Kind: link.EventRefused, DeviceID: "AAAA", Reason: wire.RefusedExpiredCode, Nonce: "n-b"})
	if got := events(a); len(got) != 0 {
		t.Fatalf("A got %v for a refusal under B's code", got)
	}
	// A refusal on a stream's newest code, no SAS shown: that stream only.
	if got, want := events(b), []string{"refused:AAAA"}; !slices.Equal(got, want) {
		t.Fatalf("B's events %v, want %v", got, want)
	}
	s.broadcast(link.PairEvent{Kind: link.EventRefused, DeviceID: "DDDD", Reason: wire.RefusedTooManyRequests, Nonce: "n-relay"})
	if got, want := events(a), []string{"refused:DDDD"}; !slices.Equal(got, want) {
		t.Fatalf("A's events %v, want %v", got, want)
	}
	// No stream's code, or no code at all: sent to none.
	s.broadcast(link.PairEvent{Kind: link.EventRefused, DeviceID: "AAAA", Reason: wire.RefusedExpiredCode, Nonce: "n-gone"})
	s.broadcast(link.PairEvent{Kind: link.EventRefused, DeviceID: "AAAA", Reason: wire.RefusedExpiredCode})
	if ga, gb := events(a), events(b); len(ga)+len(gb) != 0 {
		t.Fatalf("an unmatched refusal reached A %v, B %v", ga, gb)
	}
	// A sas no code names reaches every stream and is recorded without a
	// nonce; a refusal naming no code still matches none of them.
	s.broadcast(link.PairEvent{Kind: link.EventSAS, DeviceID: "EEEE", Code: "9999"})
	events(a)
	events(b)
	s.broadcast(link.PairEvent{Kind: link.EventRefused, DeviceID: "EEEE", Reason: wire.RefusedExpiredCode})
	if ga, gb := events(a), events(b); len(ga)+len(gb) != 0 {
		t.Fatalf("a refusal naming no code reached A %v, B %v", ga, gb)
	}
	if !s.pairs[a] || !s.pairs[b] {
		t.Fatal("a stream was dropped")
	}
}

// A pairing stream whose queue is full is dropped (removed, its connection
// closed) without holding back another stream of the same code, which gets
// every event. In a bubble: a send that blocked instead would deadlock it.
func TestAFullPairingStreamIsDroppedAndTheOtherGetsEveryEvent(t *testing.T) {
	bubble(t, func(t *testing.T) {
		conn, peer := net.Pipe()
		t.Cleanup(func() { _ = peer.Close() })
		full := &pairListener{token: "stream-full", queue: make(chan ControlAnswer, 1), w: &answerWriter{c: conn}}
		other := &pairListener{token: "stream-other", queue: make(chan ControlAnswer, 4)}
		full.addNonce("n")
		other.addNonce("n")
		s := &supervisor{o: Options{Dir: t.TempDir()}, pairs: map[*pairListener]bool{full: true, other: true}, watches: map[*pairListener]bool{}}
		s.broadcast(link.PairEvent{Kind: link.EventSAS, DeviceID: "AAAA", Code: "1234", Nonce: "n"})
		s.broadcast(link.PairEvent{Kind: link.EventRefused, DeviceID: "AAAA", Reason: wire.RefusedNotConfirmed, Nonce: "n"})
		if s.pairs[full] || !full.w.dropped.Load() {
			t.Fatalf("the full stream was kept (in pairs %v, dropped %v)", s.pairs[full], full.w.dropped.Load())
		}
		if len(other.queue) != 2 {
			t.Fatalf("the other stream got %d events, want 2", len(other.queue))
		}
	})
}

// A stream keeps the nonces of its newest link.KeptCodes codes only: the
// center keeps no older code.
func TestAStreamKeepsItsNewestCodesOnly(t *testing.T) {
	p := &pairListener{}
	for i := range link.KeptCodes + 1 {
		p.addNonce(fmt.Sprintf("n%d", i))
	}
	if p.owns("n0") || !p.owns(fmt.Sprintf("n%d", link.KeptCodes)) || len(p.nonces) != link.KeptCodes {
		t.Fatalf("nonces %v: want the newest %d", p.nonces, link.KeptCodes)
	}
}

// A phone's SAS that the link center emits before the pair request that
// asked for its code has even been answered reaches that stream: the stream
// holds the code's nonce from its qr, which the center emits first, not
// from anything done once the issue call returns.
func TestASASBeforeThePairAnswerReachesItsStream(t *testing.T) {
	a := &pairListener{token: "stream-a", queue: make(chan ControlAnswer, 4)}
	s := &supervisor{o: Options{Dir: t.TempDir()}, pairs: map[*pairListener]bool{a: true}, watches: map[*pairListener]bool{}}
	s.broadcast(link.PairEvent{Kind: link.EventQR, URL: "https://example.com/a", Nonce: "na", Token: "stream-a"})
	s.broadcast(link.PairEvent{Kind: link.EventSAS, DeviceID: "AAAA", Code: "1234", Nonce: "na"})
	<-a.queue
	if sas := <-a.queue; sas.Event != link.EventSAS || sas.DeviceID != "AAAA" {
		t.Fatalf("got %+v, want the SAS", sas)
	}
	if code, ok := a.code("AAAA"); !ok || code.code != "1234" {
		t.Fatalf("code %+v %v: the confirm would find none", code, ok)
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
