package hub

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
)

// The local control socket (spec §4): <dir>/hub.sock, 0600 in the 0700 hub
// dir, served while Run holds the hub lock. A client of another user is
// closed before anything is read. One JSON ControlRequest per line in, one
// JSON ControlAnswer per line out; a pair request streams the pairing
// events on its connection, and a confirm on that connection decides with
// the code the stream showed. Nothing here logs a name, a code or a URL.

// SocketName is the control socket's file name in the hub dir.
const SocketName = "hub.sock"

// maxRequestBytes caps one request line: a desktop_view of MaxViewIDs ids
// and MaxViewIDs shown-over counts fits.
const maxRequestBytes = 2 << 20

// The control ops.
const (
	OpUnlink  = "unlink"
	OpAllow   = "allow"
	OpName    = "name"
	OpEnable  = "enable"
	OpDisable = "disable"
	OpPair    = "pair"
	OpConfirm = "confirm"
	// Desktop's own writes (spec §8 p. 4a): the hub writes them, so the
	// sidecar keeps one writer while a hub runs. The CLI refuses them under
	// an agent marker; the socket is the owner's alone (0600, peer uid).
	OpDesktopHeartbeat = "desktop_heartbeat"
	OpRecordingClaim   = "recording_claim"
	OpRecordingFinish  = "recording_finish"
	// OpRecordings sets the owner's recording switch (On; protocol §9).
	OpRecordings = "recordings"
	// Desktop's inputs (plan 3 Task 5): its view of the sessions (Hidden,
	// DisplayOver), a claimed recording's phase and percent, and a stream of
	// the hub's events for Desktop (the connection stays open and gets one
	// line per event: EventStatus, EventRecordingQueued, EventPair,
	// EventSwitched).
	OpDesktopView, OpRecordingProgress, OpDesktopWatch = "desktop_view", "recording_progress", "desktop_watch"
)

// The desktop_watch events.
const (
	// EventStatus is a new hub status: State and Reason.
	EventStatus = "status"
	// EventRecordingQueued is a phone recording queued for the transcriber:
	// UploadID only.
	EventRecordingQueued = "recording_queued"
	// EventPair is a pairing step: Pair is its kind (qr, waiting, sas,
	// linked, refused) and DeviceID the phone; never a URL or a code.
	EventPair = "pair"
	// EventSwitched is an accepted transport switch (the switcher, Task 18).
	EventSwitched = "switched"
)

// The error classes a ControlAnswer carries.
const (
	ErrClassBadRequest    = "bad_request"
	ErrClassHubOff        = "hub_off"
	ErrClassPolicyOff     = "policy_off"
	ErrClassNoDevice      = "no_device"
	ErrClassUnknownGrant  = "unknown_grant"
	ErrClassNoCode        = "no_code"
	ErrClassNoRequest     = "no_request"
	ErrClassCodeChanged   = "code_changed"
	ErrClassNoIdentity    = "no_identity"
	ErrClassNoJob         = "no_job"
	ErrClassJobState      = "job_state"
	ErrClassNoTranscriber = "no_transcriber"
	ErrClassFailed        = "failed"
	ErrClassTooManyIDs    = "too_many_ids"
)

// ControlRequest is one request on the control socket. Device names a phone
// (unlink, allow, confirm), Grant a link.Grant (allow) with On, Name the
// hub's display name (name), Confirm the owner's answer (confirm); Upload a
// recording job (recording_claim, recording_finish) with TranscriptID or
// ErrorClass (a class, never text) for its finish, or Phase and Percent for
// its progress (recording_progress); Hidden (session ids) and DisplayOver
// (shown-over counts) a desktop_view, each at most MaxViewIDs.
type ControlRequest struct {
	Op           string          `json:"op"`
	Device       string          `json:"device,omitempty"`
	Grant        string          `json:"grant,omitempty"`
	Name         string          `json:"name,omitempty"`
	On           bool            `json:"on,omitempty"`
	Confirm      bool            `json:"confirm,omitempty"`
	Upload       string          `json:"upload,omitempty"`
	TranscriptID *int64          `json:"transcript_id,omitempty"`
	ErrorClass   string          `json:"error_class,omitempty"`
	Hidden       []int64         `json:"hidden,omitempty"`
	DisplayOver  []ShownOverWire `json:"display_over,omitempty"`
	Phase        string          `json:"phase,omitempty"`
	Percent      *int            `json:"percent,omitempty"`
}

// ControlAnswer is one line from the hub: the answer to a request (Op set,
// OK or an Error class) or a pairing event (Event set: qr, waiting, sas,
// linked, refused).
type ControlAnswer struct {
	Op        string     `json:"op,omitempty"`
	Event     string     `json:"event,omitempty"`
	OK        bool       `json:"ok"`
	Error     string     `json:"error,omitempty"`
	DeviceID  string     `json:"device_id,omitempty"`
	Name      string     `json:"name,omitempty"`
	Grant     string     `json:"grant,omitempty"`
	Allowed   *bool      `json:"allowed,omitempty"`
	Enabled   *bool      `json:"enabled,omitempty"`
	URL       string     `json:"url,omitempty"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
	Code      string     `json:"code,omitempty"`
	Reason    string     `json:"reason,omitempty"`
	// At is when a desktop heartbeat was written; UploadID, Status and
	// TranscriptID a recording job after a claim or finish.
	At           *time.Time `json:"at,omitempty"`
	UploadID     string     `json:"upload_id,omitempty"`
	Status       string     `json:"status,omitempty"`
	TranscriptID *int64     `json:"transcript_id,omitempty"`
	// Recordings is the switch after a recordings request: "on" | "off".
	Recordings string `json:"recordings,omitempty"`
	// Phase and Percent are a job's progress after a recording_progress;
	// State a status event's state (Reason its reason); Pair a pair event's
	// kind.
	Phase   string `json:"phase,omitempty"`
	Percent *int   `json:"percent,omitempty"`
	State   string `json:"state,omitempty"`
	// ViewNeeded on a desktop heartbeat's answer: the hub holds no current
	// desktop_view (never sent, or dropped while the heartbeat was stale).
	ViewNeeded bool   `json:"view_needed,omitempty"`
	Pair       string `json:"pair,omitempty"`
}

// serveControl listens on <dir>/hub.sock until the returned stop is called
// (or ctx ends). A socket that cannot be served is logged and the hub runs
// without it: CLI writes then fail.
func (s *supervisor) serveControl(ctx context.Context) (stop func()) {
	path := filepath.Join(s.o.Dir, SocketName)
	l, err := listenControl(path)
	if err != nil {
		log.Printf("hub: control socket not served (%s)", errClass(err))
		return func() {}
	}
	ctx, cancel := context.WithCancel(ctx)
	var wg sync.WaitGroup
	conns := map[net.Conn]bool{}
	var connsMu sync.Mutex
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			uc, ok := c.(*net.UnixConn)
			if !ok {
				_ = c.Close()
				continue
			}
			uid, err := s.o.peerUID(uc)
			if err != nil || uid != os.Getuid() {
				log.Printf("hub: control socket: a client of another user refused")
				_ = c.Close()
				continue
			}
			if s.o.sendBuffer > 0 {
				if err := uc.SetWriteBuffer(s.o.sendBuffer); err != nil {
					log.Printf("hub: control socket: send buffer not set (%s)", errClass(err))
				}
			}
			connsMu.Lock()
			conns[c] = true
			connsMu.Unlock()
			wg.Add(1)
			go func() {
				defer wg.Done()
				s.serveConn(ctx, c)
				connsMu.Lock()
				delete(conns, c)
				connsMu.Unlock()
			}()
		}
	}()
	return func() {
		cancel()
		_ = l.Close()
		connsMu.Lock()
		for c := range conns {
			_ = c.Close()
		}
		connsMu.Unlock()
		wg.Wait()
		_ = os.Remove(path)
	}
}

// listenControl binds path 0600, replacing a stale socket (Run holds the
// hub lock, so no other hub serves it); a non-socket file there is refused.
func listenControl(path string) (net.Listener, error) {
	if fi, err := os.Lstat(path); err == nil {
		if fi.Mode().Type() != fs.ModeSocket {
			return nil, errors.New("hub: the control socket path is not a socket")
		}
		if err := os.Remove(path); err != nil {
			return nil, fmt.Errorf("hub: removing a stale control socket: %w", err)
		}
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("hub: listening on the control socket: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = l.Close()
		return nil, fmt.Errorf("hub: tightening the control socket: %w", err)
	}
	return l, nil
}

// pairListener is one connection's pairing stream: its writer, its queue
// of events (written by its own goroutine, so a stalled client never holds
// up the other streams) and the code each phone was shown on it.
type pairListener struct {
	w     *answerWriter
	queue chan ControlAnswer // guarded by supervisor.pairMu for sends and close
	mu    sync.Mutex
	codes map[string]string
}

func (p *pairListener) code(device string) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	c, ok := p.codes[strings.ToUpper(device)]
	return c, ok
}

// pairQueue is how many events one pairing stream may have waiting; a
// stream that falls further behind is dropped (its connection closed).
const pairQueue = 64

// broadcast hands a pairing event to every pairing stream without waiting
// on any of them: a stream whose queue is full is dropped, the others get
// every event.
func (s *supervisor) broadcast(ev link.PairEvent) {
	a := ControlAnswer{Event: ev.Kind, OK: true, URL: ev.URL, DeviceID: ev.DeviceID, Name: ev.Name, Code: ev.Code, Reason: ev.Reason}
	if !ev.ExpiresAt.IsZero() {
		at := ev.ExpiresAt
		a.ExpiresAt = &at
	}
	s.pairMu.Lock()
	defer s.pairMu.Unlock()
	if ev.Kind == link.EventSAS {
		for p := range s.pairs {
			p.mu.Lock()
			p.codes[strings.ToUpper(ev.DeviceID)] = ev.Code
			p.mu.Unlock()
		}
	}
	sendAll(s.pairs, a, "pairing")
	// Desktop's watch hears of the step, never its URL or code.
	sendAll(s.watches, ControlAnswer{Event: EventPair, OK: true, Pair: ev.Kind, DeviceID: ev.DeviceID}, "desktop watch")
}

// notifyDesktop hands an event to every desktop_watch stream without
// waiting on any of them.
func (s *supervisor) notifyDesktop(a ControlAnswer) {
	s.pairMu.Lock()
	defer s.pairMu.Unlock()
	sendAll(s.watches, a, "desktop watch")
}

// sendAll queues a on every stream of set (pairMu held); a stream whose
// queue is full is dropped, the others get every event.
func sendAll(set map[*pairListener]bool, a ControlAnswer, what string) {
	for p := range set {
		select {
		case p.queue <- a:
		default:
			// serveConn closes the queue once its reader ends.
			log.Printf("hub: control socket: a %s stream fell behind and was dropped", what)
			delete(set, p)
			p.w.drop()
		}
	}
}

// answerWriter serialises a connection's lines (answers and events). Each
// line has a write deadline; a write that fails or times out closes the
// connection, and every later write is skipped.
type answerWriter struct {
	mu      sync.Mutex // serialises lines
	c       net.Conn
	enc     *json.Encoder
	timeout time.Duration
	dropped atomic.Bool
	once    sync.Once
}

func (w *answerWriter) write(a ControlAnswer) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.dropped.Load() {
		return false
	}
	if err := w.c.SetWriteDeadline(time.Now().Add(w.timeout)); err == nil {
		if err = w.enc.Encode(a); err == nil {
			return true
		}
	}
	if !w.dropped.Load() {
		log.Printf("hub: control socket: a client stopped reading and was dropped")
	}
	w.drop()
	return false
}

// drop closes the connection (its reader then ends serveConn). It never
// waits for a write in progress: closing the conn ends that write.
func (w *answerWriter) drop() {
	w.dropped.Store(true)
	w.once.Do(func() { _ = w.c.Close() })
}

// serveConn answers one client's requests in order.
func (s *supervisor) serveConn(ctx context.Context, c net.Conn) {
	defer func() { _ = c.Close() }()
	w := &answerWriter{c: c, enc: json.NewEncoder(c), timeout: s.o.writeTimeout}
	var (
		pl, wl  *pairListener // this connection's pairing and desktop_watch streams
		pumping sync.WaitGroup
	)
	// stream is a new stream of this connection (the caller registers it);
	// its own goroutine writes its queue.
	stream := func() *pairListener {
		p := &pairListener{w: w, queue: make(chan ControlAnswer, s.o.pairQueue), codes: map[string]string{}}
		pumping.Add(1)
		go func() {
			defer pumping.Done()
			for a := range p.queue {
				p.w.write(a)
			}
		}()
		return p
	}
	defer func() {
		s.pairMu.Lock()
		if pl != nil {
			delete(s.pairs, pl)
			close(pl.queue)
		}
		if wl != nil {
			delete(s.watches, wl)
			close(wl.queue)
		}
		s.pairMu.Unlock()
		pumping.Wait()
	}()
	sc := bufio.NewScanner(c)
	sc.Buffer(make([]byte, 0, 4096), maxRequestBytes)
	for sc.Scan() {
		if ctx.Err() != nil {
			return
		}
		var r ControlRequest
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			w.write(ControlAnswer{Error: ErrClassBadRequest})
			continue
		}
		switch {
		case r.Op == OpPair && pl == nil:
			pl = stream()
			s.pairMu.Lock()
			s.pairs[pl] = true
			s.pairMu.Unlock()
		case r.Op == OpDesktopWatch && wl == nil:
			// The answer, with the status at this moment, is the stream's
			// first line: queued and registered under statusMu and pairMu,
			// so no event precedes it and no status change is missed.
			wl = stream()
			s.statusMu.Lock()
			s.pairMu.Lock()
			wl.queue <- s.watchAnswerLocked()
			s.watches[wl] = true
			s.pairMu.Unlock()
			s.statusMu.Unlock()
			continue
		}
		a := s.handle(r, pl)
		a.Op = r.Op
		if a.Error != "" {
			log.Printf("hub: control %s refused (%s)", opClass(r.Op), a.Error)
		}
		if !w.write(a) {
			return
		}
	}
}

// opClass is a request's op for a log line (an unknown op is not echoed).
func opClass(op string) string {
	for _, known := range []string{OpUnlink, OpAllow, OpName, OpEnable, OpDisable, OpPair, OpConfirm,
		OpDesktopHeartbeat, OpRecordingClaim, OpRecordingFinish, OpRecordings,
		OpDesktopView, OpRecordingProgress, OpDesktopWatch} {
		if op == known {
			return known
		}
	}
	return "unknown"
}

// handle runs one request.
func (s *supervisor) handle(r ControlRequest, pl *pairListener) ControlAnswer {
	switch r.Op {
	case OpEnable:
		return s.setEnabled(true)
	case OpDisable:
		return s.setEnabled(false)
	case OpName:
		name := strings.TrimSpace(r.Name)
		if name == "" || len([]rune(name)) > wire.MaxMacNameLength {
			return ControlAnswer{Error: ErrClassBadRequest}
		}
		if err := s.st.SetMeta(state.MetaDisplayName, name); err != nil {
			return ControlAnswer{Error: ErrClassFailed}
		}
		s.poke()
		return ControlAnswer{OK: true, Name: name}
	case OpUnlink, OpAllow:
		return s.withHubOr(func(h *hubRuntime) ControlAnswer { return h.handle(r, pl) }, func() ControlAnswer { return s.offlineLink(r) })
	case OpPair, OpConfirm:
		return s.withHub(func(h *hubRuntime) ControlAnswer { return h.handle(r, pl) })
	case OpDesktopHeartbeat:
		now := s.o.Clock()
		wasFresh, _, err := s.st.DesktopHost(now)
		wasFresh = err == nil && wasFresh
		if err := s.st.Heartbeat(now); err != nil {
			return ControlAnswer{Error: ErrClassFailed}
		}
		s.recordingsChanged() // the first beat turns the default switch on
		s.poke()
		return ControlAnswer{OK: true, At: &now, ViewNeeded: s.desktopBeat(now, wasFresh)}
	case OpRecordingClaim, OpRecordingFinish:
		return s.recordingJob(r)
	case OpRecordings:
		return s.setRecordings(r.On)
	case OpRecordingProgress:
		return s.recordingProgress(r)
	case OpDesktopView:
		if len(r.Hidden) > MaxViewIDs || len(r.DisplayOver) > MaxViewIDs {
			return ControlAnswer{Error: ErrClassTooManyIDs}
		}
		v := desktopViewOf(r, s.o.Clock())
		ok := ControlAnswer{OK: true}
		return s.withHubOr(func(h *hubRuntime) ControlAnswer { h.SetDesktopView(v); return ok },
			func() ControlAnswer { s.storeDesktopView(v, nil); return ok })
	case OpDesktopWatch:
		// A second watch on one connection: its stream is already there
		// (serveConn answers the first one itself, ahead of any event).
		return s.watchAnswer()
	}
	return ControlAnswer{Error: ErrClassBadRequest}
}

// watchAnswer answers desktop_watch with the current status (State, Reason),
// so a late subscriber starts from a snapshot.
func (s *supervisor) watchAnswer() ControlAnswer {
	s.statusMu.Lock()
	defer s.statusMu.Unlock()
	return s.watchAnswerLocked()
}

// watchAnswerLocked is watchAnswer with statusMu held.
func (s *supervisor) watchAnswerLocked() ControlAnswer {
	return ControlAnswer{Op: OpDesktopWatch, OK: true, State: s.status.State, Reason: s.status.Reason}
}

// recordingProgress stores Desktop's phase of a claimed job and republishes
// the recording_job slice on the running hub.
func (s *supervisor) recordingProgress(r ControlRequest) ControlAnswer {
	if r.Upload == "" {
		return ControlAnswer{Error: ErrClassBadRequest}
	}
	a := RecordingProgressAnswer(s.st, r.Upload, r.Phase, r.Percent)
	if a.OK {
		s.hubMu.RLock()
		if s.hub != nil {
			s.hub.publishSoon(recordingJobKind)
		}
		s.hubMu.RUnlock()
	}
	return a
}

// recordingJobKind is the slice a job's progress changes.
const recordingJobKind slices.Kind = "recording_job"

// RecordingProgressAnswer stores a progress on st and answers it in the
// control socket's shape (the CLI's lock-free path answers through it too).
func RecordingProgressAnswer(st *state.Store, upload, phase string, percent *int) ControlAnswer {
	err := st.RecordingProgress(upload, phase, percent)
	var job state.RecordingJob
	if err == nil {
		job, err = st.RecordingJob(upload)
	}
	switch {
	case errors.Is(err, state.ErrBadProgress):
		return ControlAnswer{Error: ErrClassBadRequest}
	case errors.Is(err, state.ErrNoRecordingJob):
		return ControlAnswer{Error: ErrClassNoJob}
	case errors.Is(err, state.ErrJobState):
		return ControlAnswer{Error: ErrClassJobState}
	case err != nil:
		return ControlAnswer{Error: ErrClassFailed}
	}
	return ControlAnswer{OK: true, UploadID: job.UploadID, Status: job.Status, Phase: job.Phase, Percent: job.Percent}
}

// setRecordings stores the recording switch for the owner.
func (s *supervisor) setRecordings(on bool) ControlAnswer {
	err := s.st.SetRecordings(on)
	switch {
	case errors.Is(err, state.ErrNoTranscriber):
		return ControlAnswer{Error: ErrClassNoTranscriber}
	case err != nil:
		return ControlAnswer{Error: ErrClassFailed}
	}
	s.recordingsChanged()
	v := state.RecordingsOff
	if on {
		v = state.RecordingsOn
	}
	return ControlAnswer{OK: true, Recordings: v}
}

// recordingsChanged tells a running hub the switch may have changed: the
// heartbeat is republished within slices.MaxDebounceWait, and a pass fails
// the held uploads when it went off.
func (s *supervisor) recordingsChanged() {
	s.hubMu.RLock()
	defer s.hubMu.RUnlock()
	if s.hub != nil {
		s.hub.publishSoon(slices.KindHeartbeat)
		s.hub.kick(s.hub.passKick)
	}
}

// recordingJob claims or finishes a recording job for Desktop.
func (s *supervisor) recordingJob(r ControlRequest) ControlAnswer {
	if r.Upload == "" {
		return ControlAnswer{Error: ErrClassBadRequest}
	}
	var (
		job state.RecordingJob
		err error
	)
	if r.Op == OpRecordingClaim {
		job, err = s.st.ClaimRecording(r.Upload, s.o.Clock())
	} else {
		if (r.TranscriptID == nil) == (r.ErrorClass == "") {
			return ControlAnswer{Error: ErrClassBadRequest}
		}
		job, err = s.st.FinishRecording(r.Upload, r.TranscriptID, r.ErrorClass, s.o.Clock())
	}
	switch {
	case errors.Is(err, state.ErrNoRecordingJob):
		return ControlAnswer{Error: ErrClassNoJob}
	case errors.Is(err, state.ErrJobState):
		return ControlAnswer{Error: ErrClassJobState}
	case err != nil:
		return ControlAnswer{Error: ErrClassFailed}
	}
	s.poke()
	return ControlAnswer{OK: true, UploadID: job.UploadID, Status: job.Status, TranscriptID: job.TranscriptID}
}

// offlineLink is unlink or allow while the lock holder runs no hub
// (disabled, policy off, starting): the offline link decisions on the
// supervisor's own store, so the sidecar still has one writer. Called with
// hubMu held, so no hub starts meanwhile.
func (s *supervisor) offlineLink(r ControlRequest) ControlAnswer {
	if r.Device == "" {
		return ControlAnswer{Error: ErrClassBadRequest}
	}
	device := strings.ToUpper(r.Device)
	s.offlineMu.Lock()
	defer s.offlineMu.Unlock()
	if r.Op == OpUnlink {
		if err := UnlinkOffline(s.o.Dir, s.st, device, s.o.Clock); err != nil {
			return ControlAnswer{Error: LinkErrClass(err)}
		}
		return ControlAnswer{OK: true, DeviceID: device}
	}
	if err := AllowOffline(s.st, device, link.Grant(r.Grant), r.On, s.o.Clock); err != nil {
		return ControlAnswer{Error: LinkErrClass(err)}
	}
	on := r.On
	return ControlAnswer{OK: true, DeviceID: device, Grant: r.Grant, Allowed: &on}
}

// setEnabled flips hub_meta.enabled; turning it on is refused while the
// policy is off (the setting is not written).
func (s *supervisor) setEnabled(on bool) ControlAnswer {
	if on && s.o.mobileSync() == policy.MobileOff {
		return ControlAnswer{Error: ErrClassPolicyOff}
	}
	if err := s.st.SetMeta(state.MetaEnabled, strconv.Itoa(boolInt(on))); err != nil {
		return ControlAnswer{Error: ErrClassFailed}
	}
	s.poke()
	return ControlAnswer{OK: true, Enabled: &on}
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// withHub runs fn on the running hub, holding it so it cannot stop
// meanwhile; hub_off when none runs.
func (s *supervisor) withHub(fn func(*hubRuntime) ControlAnswer) ControlAnswer {
	s.hubMu.RLock()
	defer s.hubMu.RUnlock()
	if s.hub == nil {
		return ControlAnswer{Error: ErrClassHubOff}
	}
	return fn(s.hub)
}

// withHubOr runs fn on the running hub, or off when none runs, holding
// hubMu throughout so a hub never starts in the middle of off.
func (s *supervisor) withHubOr(fn func(*hubRuntime) ControlAnswer, off func() ControlAnswer) ControlAnswer {
	s.hubMu.RLock()
	defer s.hubMu.RUnlock()
	if s.hub == nil {
		return off()
	}
	return fn(s.hub)
}

// handle runs a request that needs the running hub.
func (h *hubRuntime) handle(r ControlRequest, pl *pairListener) ControlAnswer {
	switch r.Op {
	case OpUnlink:
		if r.Device == "" {
			return ControlAnswer{Error: ErrClassBadRequest}
		}
		if err := h.removePhone(r.Device); err != nil {
			return ControlAnswer{Error: LinkErrClass(err)}
		}
		return ControlAnswer{OK: true, DeviceID: strings.ToUpper(r.Device)}
	case OpAllow:
		if r.Device == "" {
			return ControlAnswer{Error: ErrClassBadRequest}
		}
		if err := h.center.Allow(r.Device, link.Grant(r.Grant), r.On); err != nil {
			return ControlAnswer{Error: LinkErrClass(err)}
		}
		on := r.On
		return ControlAnswer{OK: true, DeviceID: strings.ToUpper(r.Device), Grant: r.Grant, Allowed: &on}
	case OpPair:
		// The qr and waiting events reach the stream through the center.
		if _, _, err := h.center.Issue(); err != nil {
			return ControlAnswer{Error: ErrClassFailed}
		}
		return ControlAnswer{OK: true}
	case OpConfirm:
		if pl == nil || r.Device == "" {
			return ControlAnswer{Error: ErrClassNoCode}
		}
		code, ok := pl.code(r.Device)
		if !ok {
			return ControlAnswer{Error: ErrClassNoCode}
		}
		if err := h.center.Confirm(r.Device, code, r.Confirm); err != nil {
			return ControlAnswer{Error: LinkErrClass(err)}
		}
		h.afterConfirm(r.Device)
		return ControlAnswer{OK: true, DeviceID: strings.ToUpper(r.Device)}
	}
	return ControlAnswer{Error: ErrClassBadRequest}
}

// LinkErrClass maps a link error to its answer class (the CLI's offline
// path words its refusals through it too).
func LinkErrClass(err error) string {
	switch {
	case errors.Is(err, ErrIdentityMissing):
		return ErrClassNoIdentity
	case errors.Is(err, state.ErrNoDevice):
		return ErrClassNoDevice
	case errors.Is(err, link.ErrUnknownGrant):
		return ErrClassUnknownGrant
	case errors.Is(err, link.ErrNoRequest):
		return ErrClassNoRequest
	case errors.Is(err, link.ErrCodeChanged):
		return ErrClassCodeChanged
	}
	return ErrClassFailed
}

// ControlClient is a connection to a running hub's control socket.
type ControlClient struct {
	c   net.Conn
	enc *json.Encoder
	dec *json.Decoder
}

// Dial connects to the control socket of the hub running in dir.
func Dial(dir string) (*ControlClient, error) {
	c, err := net.DialTimeout("unix", filepath.Join(dir, SocketName), 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("hub: the hub is not running: %w", err)
	}
	return &ControlClient{c: c, enc: json.NewEncoder(c), dec: json.NewDecoder(c)}, nil
}

// Send writes one request.
func (c *ControlClient) Send(r ControlRequest) error { return c.enc.Encode(r) }

// Next reads the next line: an answer or a pairing event.
func (c *ControlClient) Next() (ControlAnswer, error) {
	var a ControlAnswer
	err := c.dec.Decode(&a)
	return a, err
}

// Do sends r and returns its answer, skipping pairing events.
func (c *ControlClient) Do(r ControlRequest) (ControlAnswer, error) {
	if err := c.Send(r); err != nil {
		return ControlAnswer{}, err
	}
	for {
		a, err := c.Next()
		if err != nil {
			return ControlAnswer{}, err
		}
		if a.Event == "" {
			return a, nil
		}
	}
}

// SetReadDeadline bounds the wait of Next and Do (zero: no bound); a read
// past it fails with a net.Error whose Timeout() is true.
func (c *ControlClient) SetReadDeadline(t time.Time) error { return c.c.SetReadDeadline(t) }

// Close closes the connection.
func (c *ControlClient) Close() error { return c.c.Close() }
