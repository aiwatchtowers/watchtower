//go:build interop && relaystaging

// The staging traffic measurement (relay client Phase 5, "Measuring the
// cost" M-B, traffic half: no APNs, no wakes, no iPhone; board #1604): an
// in-process Go hub built with the staging epoch (the identity package's
// relaystaging init reads WATCHTOWER_RELAYSTAGING_EPOCH at process start)
// publishes a synthetic workload to the relay at
// WATCHTOWER_STAGING_RELAY_ORIGIN, a Go phone with a stable device key links
// to it and reads the data zone as it changes, downloading every
// attachment, and the test prints per rotation the hub's republish line, the
// hub's and the phone's wire bytes and the verdict against the owner's 1 GB
// thresholds (ask #1131). Never part of the interop run: its names are
// outside ^TestInterop_ and the file needs the relaystaging tag as well.
//
// Run it (placeholders only; see docs/features/relay-client.md "Measuring"):
//
//	WATCHTOWER_RELAYSTAGING_EPOCH=2h \
//	WATCHTOWER_STAGING_RELAY_ORIGIN=<staging origin> \
//	WATCHTOWER_STAGING_ADMIN_TOKEN_FILE=<admin token file> \
//	go test -tags 'interop relaystaging' ./internal/hub \
//	    -run '^TestStagingMeasure_Rotations$' -timeout 30h -v
//
// TestStagingMeasure_PhoneID prints the phone's relay_device_id (for
// RELAY_ATTEST_EXEMPT_DEVICES) and creates its key when missing;
// TestStagingMeasure_LocalSmoke runs the same harness against relaytest
// (WATCHTOWER_RELAYSTAGING_EPOCH of a minute or less).
package hub

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/relaytest"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy/policytest"
)

// The harness's environment.
const (
	envStagingOrigin   = "WATCHTOWER_STAGING_RELAY_ORIGIN"
	envStagingToken    = "WATCHTOWER_STAGING_ADMIN_TOKEN_FILE"
	envStagingEpoch    = "WATCHTOWER_RELAYSTAGING_EPOCH"
	envMeasurePhoneKey = "WATCHTOWER_MEASURE_PHONE_KEY" // default: defaultPhoneKeyPath
	envMeasureWorkload = "WATCHTOWER_MEASURE_WORKLOAD"  // owner (default), heavy, or key=value pairs
	envMeasureRuns     = "WATCHTOWER_MEASURE_ROTATIONS" // default 3
)

// The harness's waits: the phone polls the data zone every phonePoll (the
// relay allows 50 ops/s per session); after a complete republish it has
// catchUpWait to read and download all of it.
const (
	phonePoll   = 2 * time.Second
	catchUpWait = 45 * time.Minute
	// cycleEvery stands in for the daemon cycle a headless hub runs in
	// (`sync --daemon` kicks the hub's housekeeping, where a due rotation
	// happens; without it only the 10-minute backstop would).
	cycleEvery = 30 * time.Second
	linkWait   = 2 * time.Minute
)

// ---- byte meters ----

// byteMeter counts every byte both ways of every TCP connection a client
// opens (TLS included on https: what crosses the wire), without keeping
// them.
type byteMeter struct{ in, out atomic.Int64 }

type meteredConn struct {
	net.Conn
	m *byteMeter
}

func (c meteredConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.m.in.Add(int64(n))
	return n, err
}

func (c meteredConn) Write(b []byte) (int, error) {
	n, err := c.Conn.Write(b)
	c.m.out.Add(int64(n))
	return n, err
}

func (m *byteMeter) dial(ctx context.Context, network, addr string) (net.Conn, error) {
	var d net.Dialer
	c, err := d.DialContext(ctx, network, addr)
	if err != nil {
		return nil, err
	}
	return meteredConn{Conn: c, m: m}, nil
}

// client is an HTTP/1.1 client over the meter, no compression, with the
// relay transport's 5-minute attachment timeout (the WebSocket takes it for
// its handshake only).
func (m *byteMeter) client() *http.Client {
	return &http.Client{Timeout: 5 * time.Minute, Transport: &http.Transport{
		DialContext: m.dial, DisableCompression: true, ForceAttemptHTTP2: false, MaxIdleConnsPerHost: 4,
	}}
}

type meterReading struct{ in, out int64 }

func (m *byteMeter) read() meterReading { return meterReading{in: m.in.Load(), out: m.out.Load()} }

func (r meterReading) minus(o meterReading) meterReading {
	return meterReading{in: r.in - o.in, out: r.out - o.out}
}

// ---- the hub's republish lines ----

// republishWatch tees the log package's output and hands every republish
// line it sees to lines.
type republishWatch struct {
	mu    sync.Mutex
	buf   []byte
	lines chan republishReading
}

func watchRepublish(t *testing.T) *republishWatch {
	t.Helper()
	w := &republishWatch{lines: make(chan republishReading, 64)}
	prev := log.Writer()
	log.SetOutput(io.MultiWriter(prev, w))
	t.Cleanup(func() { log.SetOutput(prev) })
	return w
}

func (w *republishWatch) Write(b []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, b...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		if r, ok := parseRepublish(string(w.buf[:i])); ok {
			select {
			case w.lines <- r:
			default:
			}
		}
		w.buf = w.buf[i+1:]
	}
	return len(b), nil
}

// ---- the relay's admin endpoints ----

// stagingAdmin is the relay's /dev endpoints (entitlement without the App
// Store); token is the staging admin bearer (empty on a local stand).
type stagingAdmin struct {
	origin, token string
	http          *http.Client
}

func (a *stagingAdmin) post(ctx context.Context, path string, body, out any) error {
	b, err := json.Marshal(body)
	if err != nil {
		return err
	}
	deadline := time.Now().Add(stepWait)
	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.origin+"/dev/"+path, bytes.NewReader(b))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")
		if a.token != "" {
			req.Header.Set("Authorization", "Bearer "+a.token)
		}
		res, err := a.http.Do(req)
		if err != nil {
			return fmt.Errorf("/dev/%s: %w", path, err)
		}
		data, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
		_ = res.Body.Close()
		switch {
		case res.StatusCode == http.StatusOK:
			if out == nil {
				return nil
			}
			return json.Unmarshal(data, out)
		case res.StatusCode == http.StatusServiceUnavailable && time.Now().Before(deadline):
			time.Sleep(time.Second)
		default:
			// The body is the relay's own error text; it carries no token.
			return fmt.Errorf("/dev/%s: HTTP %d %s", path, res.StatusCode, bytes.TrimSpace(data))
		}
	}
}

// entitle gives phone's account an active entitlement for 30 days; account
// is the one register returned, or /dev/account's for the phone.
func (a *stagingAdmin) entitle(ctx context.Context, phone, account string) error {
	if account == "" {
		var acct struct {
			AccountID string `json:"accountId"`
		}
		if err := a.post(ctx, "account", map[string]any{"phoneId": phone}, &acct); err != nil {
			return err
		}
		if account = acct.AccountID; account == "" {
			return errors.New("/dev/account answered no accountId")
		}
	}
	return a.post(ctx, "entitlement", map[string]any{
		"accountId": account, "state": "active", "forMs": int64(30 * 24 * time.Hour / time.Millisecond),
	}, nil)
}

// ---- the phone's key ----

// defaultPhoneKeyPath is ~/.config/watchtower/relay-staging-measure-phone.key
// (beside the staging admin token, outside any repo).
func defaultPhoneKeyPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "watchtower", "relay-staging-measure-phone.key"), nil
}

// phoneKey loads the phone's Ed25519 seed (hex, 0600) from path, creating
// it when missing: the same relay_device_id every run.
func phoneKey(path string) (ed25519.PrivateKey, bool, error) {
	if b, err := os.ReadFile(path); err == nil {
		seed, err := hex.DecodeString(strings.TrimSpace(string(b)))
		if err != nil || len(seed) != ed25519.SeedSize {
			return nil, false, fmt.Errorf("%s is not a hex Ed25519 seed", path)
		}
		return ed25519.NewKeyFromSeed(seed), false, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, false, err
	}
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return nil, false, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, false, err
	}
	if err := os.WriteFile(path, []byte(hex.EncodeToString(seed)+"\n"), 0o600); err != nil {
		return nil, false, err
	}
	return ed25519.NewKeyFromSeed(seed), true, nil
}

func loadPhoneKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	path := os.Getenv(envMeasurePhoneKey)
	if path == "" {
		var err error
		if path, err = defaultPhoneKeyPath(); err != nil {
			t.Fatal(err)
		}
	}
	key, created, err := phoneKey(path)
	if err != nil {
		t.Fatal(err)
	}
	id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	t.Logf("measure: phone relay_device_id=%s (created=%v): it must be on the relay's RELAY_ATTEST_EXEMPT_DEVICES", id, created)
	return key
}

// ---- the synthetic workload ----

// staticSource is one kind's fixed items.
type staticSource struct {
	kind  hubslices.Kind
	items []hubslices.Item
}

func (s staticSource) Kind() hubslices.Kind { return s.kind }

func (s staticSource) Items(context.Context) ([]hubslices.Item, error) {
	out := make([]hubslices.Item, len(s.items))
	for i, it := range s.items {
		it.Payload = bytes.Clone(it.Payload)
		out[i] = it
	}
	return out, nil
}

// buildWorkload seals w's transcript assets into the hub's asset dir (the
// relay transport uploads only from there) and returns its sources and the
// sealed asset bytes. Synthetic content only: random asset bytes, filler
// payloads.
func buildWorkload(t *testing.T, hubDir string, w measureWorkload) ([]hubslices.Source, int64) {
	t.Helper()
	dir := filepath.Join(hubDir, assetDirName, "measure")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	var sealedBytes int64
	transcripts := staticSource{kind: "meeting_transcript"}
	for i := range w.Transcripts {
		plain := make([]byte, w.AssetBytes)
		if _, err := rand.Read(plain); err != nil {
			t.Fatal(err)
		}
		var aid secure.ID
		key := make([]byte, 32)
		if _, err := rand.Read(aid[:]); err != nil {
			t.Fatal(err)
		}
		if _, err := rand.Read(key); err != nil {
			t.Fatal(err)
		}
		sealed, d, err := secure.EncryptAsset(plain, aid, key, secure.ChunkSize)
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, "t"+strconv.Itoa(i)+".asset")
		if err := os.WriteFile(path, sealed, 0o600); err != nil {
			t.Fatal(err)
		}
		sealedBytes += int64(len(sealed))
		id := "measure-t" + strconv.Itoa(i)
		payload, _ := json.Marshal(map[string]any{"id": id, "title": "synthetic transcript " + strconv.Itoa(i)})
		transcripts.items = append(transcripts.items, hubslices.Item{ID: id, Payload: payload, Asset: &d, AssetPath: path})
	}
	records := staticSource{kind: "inbox_item"}
	for i := range w.Records {
		id := "measure-r" + strconv.Itoa(i)
		filler := make([]byte, max(w.RecordBytes-64, 1)/2)
		_, _ = rand.Read(filler)
		payload, _ := json.Marshal(map[string]any{"id": id, "text": hex.EncodeToString(filler)})
		records.items = append(records.items, hubslices.Item{ID: id, Payload: payload})
	}
	return []hubslices.Source{transcripts, records}, sealedBytes
}

// ---- the hub ----

// measureHub is one in-process hub against the measured relay.
type measureHub struct {
	dir    string
	rec    *recorder
	ctl    *ControlClient
	meter  *byteMeter
	cancel context.CancelFunc
	done   chan error
}

func startMeasureHub(t *testing.T, origin, dir string, srcs []hubslices.Source, cycle time.Duration) *measureHub {
	t.Helper()
	policytest.Set(t, nil)
	t.Setenv(EnvHubDir, dir)
	t.Setenv(EnvRelayOrigin, origin)
	t.Setenv(EnvTestWorkspace, interopWorkspace)
	o, ok, err := FromEnv(&config.Config{ActiveWorkspace: interopWorkspace}, nil)
	if err != nil || !ok {
		t.Fatalf("FromEnv: ok=%v, %v", ok, err)
	}
	h := &measureHub{dir: dir, rec: &recorder{}, meter: &byteMeter{}}
	o.httpClient = h.meter.client()
	o.report = h.rec.report
	o.linkEvery = time.Second
	o.Sources = func(*state.Store) []hubslices.Source { return srcs }
	ctx, cancel := context.WithCancel(context.Background())
	tick := make(chan struct{})
	o.CycleTick = tick
	go func() {
		tk := time.NewTicker(cycle)
		defer tk.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tk.C:
				select {
				case tick <- struct{}{}:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	h.cancel, h.done = cancel, make(chan error, 1)
	go func() { h.done <- Run(ctx, o) }()
	t.Cleanup(func() {
		if h.ctl != nil {
			_ = h.ctl.Close()
		}
		cancel()
		select {
		case <-h.done:
		case <-time.After(30 * time.Second):
			t.Error("Run did not return after cancel")
		}
	})
	eventually(t, stepWait, "the control socket", func() bool {
		_, err := os.Stat(filepath.Join(dir, SocketName))
		return err == nil
	})
	if h.ctl, err = Dial(dir); err != nil {
		t.Fatal(err)
	}
	if a, err := h.ctl.Do(ControlRequest{Op: OpEnable}); err != nil || !a.OK {
		t.Fatalf("enable: %+v, %v", a, err)
	}
	eventually(t, stepWait, "the hub running", func() bool { return h.rec.last().State == StateRunning })
	return h
}

func (h *measureHub) next(t *testing.T, event string) ControlAnswer {
	t.Helper()
	_ = h.ctl.SetReadDeadline(time.Now().Add(linkWait))
	defer func() { _ = h.ctl.SetReadDeadline(time.Time{}) }()
	for {
		a, err := h.ctl.Next()
		if err != nil {
			t.Fatalf("waiting for %s: %v", event, err)
		}
		if a.Error != "" || a.Event == link.EventRefused {
			t.Fatalf("waiting for %s: %+v", event, a)
		}
		if a.Event == event {
			return a
		}
	}
}

// ---- the phone ----

// measurePhone is the Go phone with a stable key and its own byte meter.
type measurePhone struct {
	phone *hubtest.Phone
	store *hubtest.RelayStore
	meter *byteMeter
	hubID string // the hub's relay_device_id
	data  string // its data zone

	// The data zone as read so far.
	cursor uint64
	live   map[string]liveRecord
	got    map[string]bool // attachments downloaded
	// App-level counts: envelope bytes read by changes, attachment bytes.
	envBytes, assetBytes int64
}

type liveRecord struct {
	epoch      uint32 // 0 when the header does not parse
	attachment string
}

// linkMeasurePhone links the stable-key phone to h: the stand's linkPhone
// with the admin's entitlement and a metered client.
func linkMeasurePhone(t *testing.T, h *measureHub, origin string, key ed25519.PrivateKey, admin *stagingAdmin) *measurePhone {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), restartWait)
	defer cancel()
	if err := h.ctl.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	lp, err := wire.ParseLinkURL(h.next(t, link.EventQR).URL)
	if err != nil {
		t.Fatal(err)
	}
	m := &measurePhone{store: &hubtest.RelayStore{}, meter: &byteMeter{}, hubID: lp.RelayDeviceID,
		data: transport.DataZone(lp.RelayDeviceID), live: map[string]liveRecord{}, got: map[string]bool{}}
	if m.phone, err = hubtest.FromLinkWithKey(lp, m.store, nil, key); err != nil {
		t.Fatal(err)
	}
	m.store.C = hubtest.NewPhoneClient(origin, m.phone, client.WithHTTPClient(m.meter.client()))
	if _, err := m.store.Register(ctx); err != nil {
		t.Fatalf("phone register (is %s on RELAY_ATTEST_EXEMPT_DEVICES?): %v", m.phone.RelayDeviceID(), err)
	}
	if admin != nil {
		if err := admin.entitle(ctx, m.phone.RelayDeviceID(), m.store.C.AccountID()); err != nil {
			t.Fatalf("entitlement: %v", err)
		}
	}
	slot, err := m.store.OpenPairing(ctx, lp.RelayDeviceID)
	if err != nil {
		t.Fatal(err)
	}
	pair := transport.PairZone(slot)
	if err := m.phone.Hello(pair); err != nil {
		t.Fatal(err)
	}
	h.next(t, link.EventSAS)
	var awaiting wire.Keybox
	eventuallyEvery(t, linkWait, time.Second, "the awaiting keybox", func() bool {
		kb, ok, err := m.phone.ReadKeybox(pair)
		awaiting = kb
		return err == nil && ok && kb.Grant.ConfirmNonce != nil
	})
	if _, err := m.phone.SAS(*awaiting.Grant.ConfirmNonce); err != nil {
		t.Fatal(err)
	}
	if err := h.ctl.Send(ControlRequest{Op: OpConfirm, Device: m.phone.ID().String(), Confirm: true}); err != nil {
		t.Fatal(err)
	}
	h.next(t, link.EventLinked)
	eventuallyEvery(t, linkWait, time.Second, "the keys in the pair zone", func() bool {
		kb, ok, err := m.phone.ReadKeybox(pair)
		return err == nil && ok && kb.Keys != nil
	})
	if err := m.phone.VouchLink(ctx, lp); err != nil {
		t.Fatal(err)
	}
	if err := m.store.PromotePairing(ctx, slot); err != nil {
		t.Fatal(err)
	}
	// The slot goes at the end, so the stable phone's account never fills
	// its slots across runs.
	t.Cleanup(func() { m.removeSlot(t) })
	eventually(t, linkWait, "the hub admitted with one phone", func() bool {
		s, err := ReadStatus(h.dir)
		return err == nil && s.State == StateRunning && s.Reason == "" && s.Phones == 1
	})
	return m
}

func (m *measurePhone) removeSlot(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := m.store.C.Do(ctx, &relayv1.Request{Op: &relayv1.Request_RemoveSlot{RemoveSlot: &relayv1.RemoveMacSlot{
		PhoneDeviceId: m.phone.RelayDeviceID(), MacDeviceId: m.hubID,
	}}}); err != nil {
		t.Logf("measure: remove_slot at the end: %v (remove it by hand if the account's slots fill)", relay.MapError(err))
	}
}

// sync reads the data zone since the cursor and downloads every attachment
// of a live record not downloaded yet.
func (m *measurePhone) sync(ctx context.Context) error {
	for {
		b, err := m.store.Changes(ctx, m.data, m.cursor)
		if err != nil {
			return err
		}
		for _, name := range b.Deleted {
			delete(m.live, name)
		}
		for _, r := range b.Changed {
			m.envBytes += int64(len(r.Envelope))
			if strings.HasPrefix(r.Name, "keybox-") || strings.HasPrefix(r.Name, secure.SignalPrefix) {
				continue
			}
			lr := liveRecord{attachment: r.AttachmentID}
			if h, err := secure.ParseHeader(r.Envelope); err == nil {
				lr.epoch = h.Epoch
			}
			m.live[r.Name] = lr
		}
		m.cursor = b.NewSeq
		if !b.More {
			break
		}
	}
	for _, r := range m.live {
		if r.attachment == "" || m.got[r.attachment] {
			continue
		}
		n, err := m.download(ctx, r.attachment)
		if err != nil {
			return err
		}
		m.assetBytes += n
		m.got[r.attachment] = true
	}
	return nil
}

func (m *measurePhone) download(ctx context.Context, attachment string) (int64, error) {
	resp, err := m.store.C.Do(ctx, &relayv1.Request{Op: &relayv1.Request_GetDownload{GetDownload: &relayv1.GetDownload{
		Zone: m.data, AttachmentId: attachment,
	}}})
	if err != nil {
		return 0, fmt.Errorf("get_download: %w", relay.MapError(err))
	}
	u := resp.GetDownload().GetUrl()
	if u == "" {
		return 0, errors.New("get_download: no URL")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return 0, errors.New("download: bad URL") // never print the signed URL
	}
	res, err := m.meter.client().Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return 0, fmt.Errorf("download: %w", err)
	}
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode/100 != 2 {
		return 0, fmt.Errorf("download: HTTP %d", res.StatusCode)
	}
	return io.Copy(io.Discard, res.Body)
}

// caughtUp: at least want data records, all sealed in one epoch at or above
// minEpoch, and every attachment of them downloaded.
func (m *measurePhone) caughtUp(want int, minEpoch uint32) (bool, uint32) {
	if len(m.live) < want {
		return false, 0
	}
	var epoch uint32
	for _, r := range m.live {
		if r.epoch == 0 {
			continue
		}
		if epoch == 0 {
			epoch = r.epoch
		}
		if r.epoch != epoch || r.epoch < minEpoch || (r.attachment != "" && !m.got[r.attachment]) {
			return false, 0
		}
	}
	return epoch != 0, epoch
}

// ---- the run ----

type measureRun struct {
	origin    string
	admin     *stagingAdmin // nil: no entitlement call (relaytest pays by default)
	workload  measureWorkload
	rotations int
	epoch     time.Duration
	catchUp   time.Duration // 0 = catchUpWait
	cycle     time.Duration // 0 = cycleEvery
}

func runStagingMeasure(t *testing.T, r measureRun) {
	key := loadPhoneKey(t)
	t.Logf("measure: origin set, epoch %s, workload %s, %d rotations", r.epoch, r.workload, r.rotations)
	if r.catchUp == 0 {
		r.catchUp = catchUpWait
	}
	if r.cycle == 0 {
		r.cycle = cycleEvery
	}
	need := time.Duration(r.rotations+1)*2*r.epoch + r.catchUp
	if dl, ok := t.Deadline(); ok && time.Until(dl) < need {
		t.Fatalf("the test deadline is %s away; this run needs up to %s: pass -timeout %s", time.Until(dl).Round(time.Minute), need, need.Round(time.Hour)+time.Hour)
	}
	watch := watchRepublish(t)
	dir := shortDir(t)
	srcs, sealed := buildWorkload(t, dir, r.workload)
	t.Logf("measure: workload sealed: %d asset bytes in %d files, %d records", sealed, r.workload.Transcripts, r.workload.Records)
	h := startMeasureHub(t, r.origin, dir, srcs, r.cycle)
	p := linkMeasurePhone(t, h, r.origin, key, r.admin)

	ctx := context.Background()
	want := r.workload.Records + r.workload.Transcripts
	// waitCaughtUp polls the zone until the phone holds the whole workload
	// in one epoch at or above minEpoch, every attachment downloaded.
	waitCaughtUp := func(what string, minEpoch uint32) uint32 {
		t.Helper()
		deadline := time.Now().Add(r.catchUp)
		for {
			if err := p.sync(ctx); err != nil {
				t.Logf("measure: phone sync: %v", err)
			} else if ok, e := p.caughtUp(want, minEpoch); ok {
				return e
			}
			if time.Now().After(deadline) {
				t.Fatalf("the phone did not catch up with %s within %s (%d live records)", what, r.catchUp, len(p.live))
			}
			time.Sleep(phonePoll)
		}
	}
	epoch := waitCaughtUp("the first publish", 0)
	type snap struct {
		hub, phone meterReading
		env, asset int64
	}
	take := func() snap {
		return snap{hub: h.meter.read(), phone: p.meter.read(), env: p.envBytes, asset: p.assetBytes}
	}
	base := take()
	t.Logf("measure: first publish read: epoch %d, %d records, hub wire out %d B, phone wire in %d B (envelopes %d B, attachments %d B)",
		epoch, len(p.live), base.hub.out, base.phone.in, base.env, base.asset)

	failed := 0
	for i := 1; i <= r.rotations; i++ {
		// The phone keeps reading while the hub rotates and republishes, as
		// a phone on the relay does.
		var line republishReading
		deadline := time.Now().Add(2*r.epoch + 10*time.Minute)
	wait:
		for {
			select {
			case line = <-watch.lines:
				break wait
			case <-time.After(phonePoll):
			}
			if err := p.sync(ctx); err != nil {
				t.Logf("measure: phone sync: %v", err)
			}
			if time.Now().After(deadline) {
				t.Fatalf("rotation %d: no republish line within %s", i, 2*r.epoch+10*time.Minute)
			}
		}
		if line.Outcome == "complete" {
			epoch = waitCaughtUp(fmt.Sprintf("rotation %d", i), epoch+1)
		}
		now := take()
		hub, phone := now.hub.minus(base.hub), now.phone.minus(base.phone)
		pass, verdict := judgeRotation(line, phone.in)
		if !pass {
			failed++
		}
		t.Logf("measure: rotation %d: hub line %s, %d records, %d asset bytes, %d envelope bytes, %d s (upload %d B)",
			i, line.Outcome, line.Records, line.AssetBytes, line.EnvelopeBytes, line.Seconds, line.Upload())
		t.Logf("measure: rotation %d: hub wire out %d B in %d B; phone wire in %d B out %d B (envelopes %d B, attachments %d B); epoch %d",
			i, hub.out, hub.in, phone.in, phone.out, now.env-base.env, now.asset-base.asset, epoch)
		t.Logf("measure: rotation %d: %s (limit %d B each)", i, verdict, rotationLimitBytes)
		base = now
	}
	if failed > 0 {
		t.Fatalf("measure: %d of %d rotations failed", failed, r.rotations)
	}
}

// eventuallyEvery is eventually polling every d (the relay's op limits).
func eventuallyEvery(t *testing.T, wait, d time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(wait)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(d)
	}
}

func measureEpoch(t *testing.T) time.Duration {
	t.Helper()
	v := os.Getenv(envStagingEpoch)
	if v == "" {
		t.Fatalf("%s is not set: the build's 10-minute epoch is not for this run (the plan's M-B uses 2h)", envStagingEpoch)
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		t.Fatalf("%s=%q is not a positive duration", envStagingEpoch, v)
	}
	return d
}

func measureRotations(t *testing.T) int {
	t.Helper()
	v := os.Getenv(envMeasureRuns)
	if v == "" {
		return 3
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 {
		t.Fatalf("%s=%q is not a positive number", envMeasureRuns, v)
	}
	return n
}

func isLoopback(origin string) bool {
	u, err := url.Parse(origin)
	if err != nil {
		return false
	}
	switch u.Hostname() {
	case "127.0.0.1", "localhost", "::1":
		return true
	}
	return false
}

// TestStagingMeasure_Rotations is the M-B traffic run against
// WATCHTOWER_STAGING_RELAY_ORIGIN (skipped without it). A non-loopback
// origin needs WATCHTOWER_STAGING_ADMIN_TOKEN_FILE; the phone's
// relay_device_id must already be on RELAY_ATTEST_EXEMPT_DEVICES.
func TestStagingMeasure_Rotations(t *testing.T) {
	origin := strings.TrimRight(os.Getenv(envStagingOrigin), "/")
	if origin == "" {
		t.Skipf("no %s", envStagingOrigin)
	}
	run := measureRun{origin: origin, rotations: measureRotations(t), epoch: measureEpoch(t)}
	var err error
	if run.workload, err = parseWorkload(os.Getenv(envMeasureWorkload)); err != nil {
		t.Fatal(err)
	}
	admin := &stagingAdmin{origin: origin, http: &http.Client{Timeout: 30 * time.Second}}
	if f := os.Getenv(envStagingToken); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("the admin token file: %v", err)
		}
		admin.token = strings.TrimSpace(string(b))
	}
	if admin.token == "" && !isLoopback(origin) {
		t.Fatalf("%s names no readable, non-empty token: the staging relay's /dev endpoints need it", envStagingToken)
	}
	run.admin = admin
	runStagingMeasure(t, run)
}

// TestStagingMeasure_PhoneID prints the stable phone's relay_device_id,
// creating its key when missing; nothing reaches a relay.
func TestStagingMeasure_PhoneID(t *testing.T) {
	loadPhoneKey(t)
}

// TestStagingMeasure_LocalSmoke runs the harness against relaytest, with a
// small workload and two rotations: run it with
// WATCHTOWER_RELAYSTAGING_EPOCH of a minute or less (skipped otherwise).
func TestStagingMeasure_LocalSmoke(t *testing.T) {
	v := os.Getenv(envStagingEpoch)
	d, err := time.ParseDuration(v)
	if v == "" || err != nil || d <= 0 || d > time.Minute {
		t.Skipf("set %s to a minute or less", envStagingEpoch)
	}
	t.Setenv(envMeasurePhoneKey, filepath.Join(t.TempDir(), "phone.key"))
	srv := relaytest.Start(t)
	runStagingMeasure(t, measureRun{origin: srv.URL, rotations: 2, epoch: d, catchUp: 2 * time.Minute, cycle: 2 * time.Second,
		workload: measureWorkload{Name: "smoke", Transcripts: 2, AssetBytes: 64 << 10, Records: 40, RecordBytes: 512}})
}
