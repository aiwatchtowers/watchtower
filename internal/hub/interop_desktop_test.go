//go:build interop

// The desktop host on the relay's stand (relay client Phase 3b Task 24, Ruling
// R24): startDesktopHub runs Run as a Mac's desktop host — the hosted relay
// on the stand through the wire tap, and CloudKit through the real bridge
// client over a bridgefake on <hub dir>/bridge.sock — and serveCloudKitLoop
// lets a phone in another process (the Kit's LoopbackCloudTransport) reach
// that fake's phone side over loopback HTTP. Test-only: both live under the
// interop build tag, and no production code imports them.
//
// The loopback store's protocol (every request POST, JSON, with
// `Authorization: Bearer <token>`; a request without the token is 403):
//
//	/accept-share {user}                                  → {}
//	/changes      {user, zone, since}                     → {changed, deleted, new_seq, more}
//	/save         {user, zone, name, payload, expect, seq} → {outcome: saved|conflict, seq, current}
//	/delete       {user, zone, name, expect, seq}          → {outcome: deleted|conflict, current}
//
// zone is the Kit's CloudZoneID raw value (DataZone or RelayZone, the hub's
// zones of the hub the fake's last Hello named); payload is the sealed
// envelope (base64); expect is none, absent or seq (seq = the change tag the
// write expects). user is the phone's iCloud user record name: "" is the
// Mac's own user (a private-scope phone, written with no creator); any other
// user must have accepted the share (/accept-share, which records it as an
// accepted participant of both zones, so HandleCloudKitHello's creator and
// participant checks pass) and its writes carry it as their creator. A user
// the hub removed from the shares is refused (409 not_participant). The other
// error answers are {error: <class>}: 400 bad_request, 404 not_found, 405,
// 410 token_expired, 503 no_hub / unavailable, 500 failed.
package hub

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/cloudkit/bridgefake"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/policy/policytest"
)

// kitDesktop is the desktop run of the Kit harness
// (RELAY_INTEROP_DESKTOP=1 in scripts/relay-interop-kit-hub.sh): the hub is a
// desktop host and the relay-only TestInterop_KitPhone skips, so the one
// handoff folder serves the desktop test alone.
var kitDesktop = flag.Bool("kit-desktop", false, "the Kit run is the desktop host's (RELAY_INTEROP_DESKTOP=1)")

// ckURLFile is the handoff file that carries the loopback store's URL and
// token to the Kit phone (mode 0600, written whole).
const ckURLFile = "ck.url"

// loopBodyLimit caps a loopback request body (a sealed record is well under
// CloudKit's 1 MB record cap).
const loopBodyLimit = 4 << 20

// startDesktopHub runs a hub as a desktop host on a fresh hubtest-* dir: the
// relay on the stand through the wire tap (the transport of each start is
// h.transport()), CloudKit through the real bridge client over a bridgefake
// served on the hub dir (h.bridge), announcing ["cloudkit","relay"]. The
// never-two-hubs gate opens as in TestFreshDesktopHostStartsWhenEnabled: no
// MobileHub/, a fresh sidecar, then `hub enable` over the control socket.
// The bridge's process is a sleep stub in its own process group, which the
// hub's Supervisor stops and reaps; any left at the test's end are killed.
func startDesktopHub(t *testing.T, opts interopOpts) *interopHub {
	t.Helper()
	origin := needStand(t)
	policytest.Set(t, nil)
	dir := shortDir(t)
	t.Setenv(EnvHubDir, dir)
	t.Setenv(EnvRelayOrigin, origin)
	t.Setenv(EnvTestWorkspace, interopWorkspace)
	o, ok, err := FromEnv(&config.Config{ActiveWorkspace: interopWorkspace}, nil)
	if err != nil || !ok {
		t.Fatalf("FromEnv: ok=%v, %v", ok, err)
	}
	// A fresh sidecar: the gate opens and the hub waits, off, for `hub enable`.
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	stubs := &stubGroups{}
	t.Cleanup(stubs.kill) // registered first: runs after the hub and the bridge stopped
	h := &interopHub{t: t, origin: origin, dir: dir, tap: &wireTap{}, rec: &recorder{}}
	h.bridge = bridgefake.Serve(t, dir)

	o.Mode, o.Host = ModeLive, hostkind.Desktop
	o.Desktop = &Desktop{
		MobileHubDir: filepath.Join(filepath.Dir(dir), "MobileHub"), // never created: no Swift hub
		newCloudKit:  func(c cloudkit.Config) transport.Transport { return cloudkit.New(c) },
		launch:       stubs.launch,
	}
	o.Transports = desktopTransportList(o)
	if got := strings.Join(o.Transports, ","); got != "cloudkit,relay" {
		t.Fatalf("transports %q", got)
	}
	o.httpClient = h.tap.httpClient()
	if opts.httpWrap != nil {
		o.httpClient.Transport = opts.httpWrap(o.httpClient.Transport)
	}
	// A desktop host builds its relay unconnected (zones nil) once per start;
	// the link upkeep connects it.
	if opts.clock != nil {
		o.Clock = opts.clock
	}
	o.CycleTick = opts.cycle
	// The relay keeps the real clock: it stamps client_modified_at_ms, which
	// the stand checks against its own.
	relayOpts := o
	relayOpts.Clock = time.Now
	o.newTransport = func(ctx context.Context, id identity.Identity, st *state.Store, zones []string) (transport.Transport, error) {
		tr, err := relayOpts.relayTransport(ctx, id, st, zones)
		if err != nil {
			t.Logf("hub transport: %v", err)
			return nil, err
		}
		tapped := newTappedTransport(tr.(*relay.Transport))
		h.mu.Lock()
		h.tr = tapped
		h.mu.Unlock()
		return tapped, nil
	}
	o.report = h.rec.report
	o.checkEvery = 100 * time.Millisecond
	o.lockRetry = 50 * time.Millisecond
	o.passEvery, o.linkEvery, o.Register = opts.passEvery, opts.linkEvery, opts.register
	o.Sources, o.away = opts.sources, opts.away

	ctx, cancel := context.WithCancel(context.Background())
	h.cancel, h.done = cancel, make(chan error, 1)
	go func() { h.done <- Run(ctx, o) }()
	t.Cleanup(h.stop) // runs before the bridgefake's Close and the stub sweep
	eventuallyOnStand(t, stepWait, "the control socket", func() bool {
		_, err := os.Stat(filepath.Join(dir, SocketName))
		return err == nil
	})
	if h.ctl, err = Dial(dir); err != nil {
		t.Fatal(err)
	}
	if a, err := h.ctl.Do(ControlRequest{Op: OpEnable}); err != nil || !a.OK {
		t.Fatalf("enable: %+v, %v", a, err)
	}
	h.waitRunning()
	eventuallyOnStand(t, stepWait, "the bridge's Hello", func() bool { return h.bridge.HubID() != "" })
	return h
}

// stubGroups starts the stand-in bridge processes, each its own process
// group's leader, and kills whatever group is left.
type stubGroups struct {
	mu    sync.Mutex
	procs []*os.Process
}

func (s *stubGroups) launch(context.Context) (*os.Process, error) {
	cmd := exec.Command("/bin/sh", "-c", "exec sleep 3600")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	s.procs = append(s.procs, cmd.Process)
	s.mu.Unlock()
	return cmd.Process, nil
}

// kill SIGKILLs every group started and waits for its leader; the
// Supervisor already reaped the ones it stopped (their Wait answers "already
// waited", ignored), so this only sweeps a group a failed test left.
func (s *stubGroups) kill() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.procs {
		_ = syscall.Kill(-p.Pid, syscall.SIGKILL)
		_, _ = p.Wait()
	}
}

// writeCloudKitURL hands the loopback store to the Kit phone: ck.url holds
// {"url","token"}, written whole at mode 0600.
func (k kitRun) writeCloudKitURL(url, token string) {
	k.t.Helper()
	b, err := json.Marshal(struct {
		URL   string `json:"url"`
		Token string `json:"token"`
	}{url, token})
	if err != nil {
		k.t.Fatal(err)
	}
	k.write(ckURLFile, string(b))
}

// ---- the loopback CloudKit store ----

// cloudKitLoop is the loopback store over a bridgefake's phone side.
type cloudKitLoop struct {
	f     *bridgefake.Fake
	token []byte

	// bodies is every authorized request body, as read (the canary check of
	// TestInterop_KitPhoneFollowsASwitch).
	mu     sync.Mutex
	bodies [][]byte
}

// requestBodies is a copy of every authorized request body the store read.
func (l *cloudKitLoop) requestBodies() [][]byte {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([][]byte, len(l.bodies))
	for i, b := range l.bodies {
		out[i] = bytes.Clone(b)
	}
	return out
}

// serveCloudKitLoop serves f's phone records on 127.0.0.1:<random port>
// behind a per-run token of 32 random bytes (hex); it stops at the test's
// end. The URL is http://127.0.0.1:<port>.
func serveCloudKitLoop(t *testing.T, f *bridgefake.Fake) (url, token string) {
	t.Helper()
	url, token, _ = serveTappedCloudKitLoop(t, f)
	return url, token
}

// serveTappedCloudKitLoop is serveCloudKitLoop that also returns the store,
// whose requestBodies the caller reads.
func serveTappedCloudKitLoop(t *testing.T, f *bridgefake.Fake) (url, token string, loop *cloudKitLoop) {
	t.Helper()
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		t.Fatal(err)
	}
	token = hex.EncodeToString(raw[:])
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	loop = &cloudKitLoop{f: f, token: []byte(token)}
	srv := &http.Server{Handler: loop, ReadHeaderTimeout: 10 * time.Second}
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = srv.Serve(l)
	}()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
		<-done
	})
	return "http://" + l.Addr().String(), token, loop
}

// loopRequest is every op's body; each op reads its own fields.
type loopRequest struct {
	User    string `json:"user"`
	Zone    string `json:"zone"`
	Name    string `json:"name"`
	Payload []byte `json:"payload"`
	Expect  string `json:"expect"`
	Seq     uint64 `json:"seq"`
	Since   uint64 `json:"since"`
}

type loopRecord struct {
	Name       string `json:"name"`
	Payload    []byte `json:"payload"`
	Seq        uint64 `json:"seq"`
	Creator    string `json:"creator,omitempty"`
	ServerAtMs int64  `json:"server_at_ms,omitempty"`
}

type loopOutcome struct {
	Outcome string      `json:"outcome"`
	Seq     uint64      `json:"seq,omitempty"`
	Current *loopRecord `json:"current,omitempty"`
}

type loopBatch struct {
	Changed []loopRecord `json:"changed"`
	Deleted []string     `json:"deleted"`
	NewSeq  uint64       `json:"new_seq"`
	More    bool         `json:"more"`
}

func (l *cloudKitLoop) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !l.authorized(r) {
		loopError(w, http.StatusForbidden, "forbidden")
		return
	}
	if r.Method != http.MethodPost {
		loopError(w, http.StatusMethodNotAllowed, "method")
		return
	}
	hub := l.f.HubID()
	if hub == "" {
		loopError(w, http.StatusServiceUnavailable, "no_hub")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, loopBodyLimit))
	if err != nil {
		loopError(w, http.StatusBadRequest, "bad_request")
		return
	}
	l.mu.Lock()
	l.bodies = append(l.bodies, body)
	l.mu.Unlock()
	var req loopRequest
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		loopError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if r.URL.Path == "/accept-share" {
		if req.User == "" {
			loopError(w, http.StatusBadRequest, "bad_request")
			return
		}
		for _, z := range []string{cloudkit.DataZoneName(hub), cloudkit.RelayZoneName(hub)} {
			l.accept(z, req.User)
		}
		loopJSON(w, struct{}{})
		return
	}
	zone, ckZone, ok := loopZone(req.Zone, hub)
	if !ok {
		loopError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if !l.mayUse(ckZone, req.User) {
		loopError(w, http.StatusConflict, "not_participant")
		return
	}
	recs := l.f.PhoneRecords(hub)
	switch r.URL.Path {
	case "/changes":
		b, err := recs.Changes(r.Context(), zone, req.Since)
		if err != nil {
			loopStoreError(w, err)
			return
		}
		out := loopBatch{Changed: []loopRecord{}, Deleted: b.Deleted, NewSeq: b.NewSeq, More: b.More}
		if out.Deleted == nil {
			out.Deleted = []string{}
		}
		for _, s := range b.Changed {
			out.Changed = append(out.Changed, loopRecordOf(s))
		}
		loopJSON(w, out)
	case "/save":
		expect, ok := loopExpect(req.Expect, req.Seq)
		if !ok || req.Name == "" {
			loopError(w, http.StatusBadRequest, "bad_request")
			return
		}
		var o transport.Outcome
		var err error
		if req.User == "" {
			o, err = recs.Write(zone, req.Name, req.Payload, expect)
		} else {
			o, err = recs.WriteAs(req.User, zone, req.Name, req.Payload, expect)
		}
		if err != nil {
			loopStoreError(w, err)
			return
		}
		loopJSON(w, loopOutcomeOf(o, "saved"))
	case "/delete":
		expect, ok := loopExpect(req.Expect, req.Seq)
		if !ok || req.Name == "" {
			loopError(w, http.StatusBadRequest, "bad_request")
			return
		}
		out, err := recs.Delete(r.Context(), zone, []transport.DeleteItem{{Name: req.Name, Expect: expect}})
		if err != nil {
			loopStoreError(w, err)
			return
		}
		loopJSON(w, loopOutcomeOf(out[0], "deleted"))
	default:
		loopError(w, http.StatusNotFound, "not_found")
	}
}

// authorized: the request carries `Authorization: Bearer <token>`.
func (l *cloudKitLoop) authorized(r *http.Request) bool {
	got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return ok && subtle.ConstantTimeCompare([]byte(got), l.token) == 1
}

// accept makes user an accepted participant of the CloudKit zone z.
func (l *cloudKitLoop) accept(z, user string) {
	ps := l.f.ParticipantsOf(z)
	for i := range ps {
		if ps[i].UserRecordName == user {
			ps[i].Accepted = true
			l.f.SetParticipants(z, ps)
			return
		}
	}
	l.f.SetParticipants(z, append(ps, transport.Participant{UserRecordName: user, Accepted: true}))
}

// mayUse: the Mac's own user ("") always; any other user while it is an
// accepted participant of the zone's share.
func (l *cloudKitLoop) mayUse(ckZone, user string) bool {
	if user == "" {
		return true
	}
	for _, p := range l.f.ParticipantsOf(ckZone) {
		if p.UserRecordName == user && p.Accepted {
			return true
		}
	}
	return false
}

// loopZone maps the Kit's zone to PhoneRecords' runtime prefix and the
// CloudKit zone name of hub.
func loopZone(kit, hub string) (zone, ckZone string, ok bool) {
	switch kit {
	case "DataZone":
		return "data/", cloudkit.DataZoneName(hub), true
	case "RelayZone":
		return "relay/", cloudkit.RelayZoneName(hub), true
	}
	return "", "", false
}

func loopExpect(mode string, seq uint64) (transport.Expect, bool) {
	switch mode {
	case "", "none":
		return transport.Expect{}, true
	case "absent":
		return transport.Expect{Mode: transport.ExpectAbsent}, true
	case "seq":
		return transport.Expect{Mode: transport.ExpectSeq, Seq: seq}, seq != 0
	}
	return transport.Expect{}, false
}

func loopRecordOf(s transport.Stored) loopRecord {
	r := loopRecord{Name: s.Name, Payload: s.Envelope, Seq: s.RecordSeq, Creator: s.Creator}
	if !s.ServerAt.IsZero() {
		r.ServerAtMs = s.ServerAt.UnixMilli()
	}
	return r
}

// loopOutcomeOf is one item's outcome: done ("saved"/"deleted") with the new
// tag, or a conflict with the current record (none when it is absent).
func loopOutcomeOf(o transport.Outcome, done string) loopOutcome {
	if o.Saved {
		return loopOutcome{Outcome: done, Seq: o.RecordSeq}
	}
	out := loopOutcome{Outcome: "conflict"}
	if o.Conflict != nil {
		cur := loopRecordOf(*o.Conflict)
		out.Current = &cur
	}
	return out
}

func loopStoreError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, transport.ErrTokenExpired):
		loopError(w, http.StatusGone, "token_expired")
	case errors.Is(err, transport.ErrUnavailable):
		loopError(w, http.StatusServiceUnavailable, "unavailable")
	default:
		loopError(w, http.StatusInternalServerError, "failed")
	}
}

func loopJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func loopError(w http.ResponseWriter, status int, class string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": class})
}

// ---- tests ----

// loopHelloed is a bridgefake a hub has said Hello to (hub_id hub), as the
// loopback store needs before it serves a zone.
func loopHelloed(t *testing.T, hub string) *bridgefake.Fake {
	t.Helper()
	dir := bridgefake.Dir(t)
	f := bridgefake.Serve(t, dir)
	const rid = "loopbackrid"
	c := cloudkit.New(cloudkit.Config{Dir: dir, HubID: hub, RelayID: rid})
	t.Cleanup(func() { _ = c.Close() })
	if _, err := c.Changes(context.Background(), transport.DataZone(rid), 0); err != nil {
		t.Fatal(err)
	}
	if f.HubID() != hub {
		t.Fatalf("hello named %q", f.HubID())
	}
	return f
}

// loopPost sends body to url+path with the Authorization header auth ("" =
// none); it returns the status and the decoded answer.
func loopPost(t *testing.T, url, path, auth string, body any) (int, map[string]any) {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodPost, url+path, strings.NewReader(string(b)))
	if err != nil {
		t.Fatal(err)
	}
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	var out map[string]any
	dec := json.NewDecoder(resp.Body)
	dec.UseNumber() // tags are full-range uint64s
	_ = dec.Decode(&out)
	return resp.StatusCode, out
}

// TestLoopbackRefusesWithoutTheToken: every op without the run's token —
// none, another token, the token under another scheme or as a prefix — is
// 403 and changes nothing; with it the ops serve the fake's phone side, a
// shared user only once it accepted the share, as its records' creator.
func TestLoopbackRefusesWithoutTheToken(t *testing.T) {
	const hub = "hub-loopback"
	f := loopHelloed(t, hub)
	url, token := serveCloudKitLoop(t, f)
	if len(token) != 64 {
		t.Fatalf("token of %d hex chars, want 32 bytes", len(token))
	}
	if _, again := serveCloudKitLoop(t, f); again == token {
		t.Fatal("two stores share a token")
	}
	save := map[string]any{"user": "", "zone": "RelayZone", "name": "hello-a", "payload": []byte("env"), "expect": "absent"}
	ops := map[string]map[string]any{
		"/save":         save,
		"/delete":       {"user": "", "zone": "RelayZone", "name": "hello-a", "expect": "none"},
		"/changes":      {"user": "", "zone": "RelayZone", "since": 0},
		"/accept-share": {"user": "_phone"},
		"/nowhere":      {},
	}
	for path, body := range ops {
		for _, auth := range []string{"", "Bearer " + strings.Repeat("0", 64), "Basic " + token, "Bearer " + token[:32], "bearer " + token, token} {
			if code, out := loopPost(t, url, path, auth, body); code != http.StatusForbidden || out["error"] != "forbidden" {
				t.Fatalf("%s with %q: %d %v, want 403", path, auth, code, out)
			}
		}
	}
	if b, err := f.PhoneRecords(hub).Changes(context.Background(), "relay/", 0); err != nil || len(b.Changed)+len(b.Deleted) != 0 {
		t.Fatalf("a refused request changed the store: %+v %v", b, err)
	}
	if ps := f.ParticipantsOf(cloudkit.RelayZoneName(hub)); len(ps) != 0 {
		t.Fatalf("a refused accept-share added %v", ps)
	}
	resp, err := http.Get(url + "/changes")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("GET without the token: %d", resp.StatusCode)
	}

	bearer := "Bearer " + token
	// The Mac's own user writes with no share.
	code, out := loopPost(t, url, "/save", bearer, save)
	if code != http.StatusOK || out["outcome"] != "saved" {
		t.Fatalf("save: %d %v", code, out)
	}
	tag, err := strconv.ParseUint(string(out["seq"].(json.Number)), 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	if code, out = loopPost(t, url, "/save", bearer, save); code != http.StatusOK || out["outcome"] != "conflict" {
		t.Fatalf("a second absent save: %d %v", code, out)
	}
	// A shared user is refused until it accepted the share.
	shared := map[string]any{"user": "_phone", "zone": "RelayZone", "name": "hello-b", "payload": []byte("env2"), "expect": "absent"}
	if code, out = loopPost(t, url, "/save", bearer, shared); code != http.StatusConflict || out["error"] != "not_participant" {
		t.Fatalf("save before accept-share: %d %v", code, out)
	}
	if code, _ = loopPost(t, url, "/accept-share", bearer, map[string]any{"user": "_phone"}); code != http.StatusOK {
		t.Fatalf("accept-share: %d", code)
	}
	for _, z := range []string{cloudkit.DataZoneName(hub), cloudkit.RelayZoneName(hub)} {
		if ps := f.ParticipantsOf(z); len(ps) != 1 || ps[0] != (transport.Participant{UserRecordName: "_phone", Accepted: true}) {
			t.Fatalf("%s participants %v", z, ps)
		}
	}
	if code, out = loopPost(t, url, "/save", bearer, shared); code != http.StatusOK || out["outcome"] != "saved" {
		t.Fatalf("save after accept-share: %d %v", code, out)
	}
	code, out = loopPost(t, url, "/changes", bearer, map[string]any{"user": "_phone", "zone": "RelayZone", "since": 0})
	if code != http.StatusOK {
		t.Fatalf("changes: %d %v", code, out)
	}
	creators := map[string]any{}
	for _, r := range out["changed"].([]any) {
		rec := r.(map[string]any)
		creators[rec["name"].(string)] = rec["creator"]
	}
	if creators["hello-a"] != nil || creators["hello-b"] != "_phone" {
		t.Fatalf("creators %v", creators)
	}
	// A conditional delete over the tag.
	if code, out = loopPost(t, url, "/delete", bearer, map[string]any{"user": "", "zone": "RelayZone", "name": "hello-a", "expect": "seq", "seq": tag + 1000}); code != http.StatusOK || out["outcome"] != "conflict" {
		t.Fatalf("delete over another tag: %d %v", code, out)
	}
	if code, out = loopPost(t, url, "/delete", bearer, map[string]any{"user": "", "zone": "RelayZone", "name": "hello-a", "expect": "seq", "seq": tag}); code != http.StatusOK || out["outcome"] != "deleted" {
		t.Fatalf("delete over its tag: %d %v", code, out)
	}
	// The hub took the user off the share: refused again.
	f.SetParticipants(cloudkit.RelayZoneName(hub), nil)
	if code, out = loopPost(t, url, "/changes", bearer, map[string]any{"user": "_phone", "zone": "RelayZone", "since": 0}); code != http.StatusConflict {
		t.Fatalf("changes after removal: %d %v", code, out)
	}
}

// TestLoopbackListensOnLoopbackOnly: the store is bound to 127.0.0.1 alone —
// its URL names it, and the same port on the Mac's other addresses (and on
// IPv6 loopback) does not answer.
func TestLoopbackListensOnLoopbackOnly(t *testing.T) {
	f := loopHelloed(t, "hub-loopback")
	url, _ := serveCloudKitLoop(t, f)
	host, port, err := net.SplitHostPort(strings.TrimPrefix(url, "http://"))
	if err != nil || host != "127.0.0.1" || !strings.HasPrefix(url, "http://") {
		t.Fatalf("url %q (%v)", url, err)
	}
	c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", port), 2*time.Second)
	if err != nil {
		t.Fatalf("loopback: %v", err)
	}
	_ = c.Close()
	others := []string{"::1"}
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && !ipn.IP.IsLoopback() && !ipn.IP.IsLinkLocalUnicast() {
			others = append(others, ipn.IP.String())
		}
	}
	for _, ip := range others {
		if c, err := net.DialTimeout("tcp", net.JoinHostPort(ip, port), 2*time.Second); err == nil {
			_ = c.Close()
			t.Fatalf("the store answers on %s", ip)
		}
	}
	t.Logf("checked %d other addresses", len(others))
}

// TestInterop_DesktopHostOnTheStand: startDesktopHub runs a desktop host on
// the stand — both transports announced, the bridge said Hello with the
// hub's id — and the loopback store serves that hub's zones.
func TestInterop_DesktopHostOnTheStand(t *testing.T) {
	h := startDesktopHub(t, interopOpts{})
	s := h.rec.last()
	if s.Host != string(hostkind.Desktop) || s.HubID == "" || h.bridge.HubID() != s.HubID {
		t.Fatalf("status %+v, bridge hub %q", s, h.bridge.HubID())
	}
	if h.transport() == nil {
		t.Fatal("the relay was not built through the tap")
	}
	url, token := serveCloudKitLoop(t, h.bridge)
	if code, out := loopPost(t, url, "/changes", "Bearer "+token, map[string]any{"user": "", "zone": "DataZone", "since": 0}); code != http.StatusOK {
		t.Fatalf("changes: %d %v", code, out)
	}
	// The handoff the Kit reads (LoopbackCloudEndpoint): {"url","token"} at 0600.
	k := kitRun{t: t, dir: t.TempDir()}
	k.writeCloudKitURL(url, token)
	fi, err := os.Stat(filepath.Join(k.dir, ckURLFile))
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("ck.url: %v %v", fi, err)
	}
	var got struct{ URL, Token string }
	b, _ := os.ReadFile(filepath.Join(k.dir, ckURLFile))
	if err := json.Unmarshal(b, &got); err != nil || got.URL != url || got.Token != token {
		t.Fatalf("ck.url holds %q (%v)", b, err)
	}
}
