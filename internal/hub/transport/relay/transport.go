// Package relay is the hub's transport over the hosted relay (Go hub design
// §6.1, RC §7 hub half): records, change feeds and attachments over the
// pinned copy of the relay's Go client (client/, relayv1/, see VERSION and
// `make relay-go`), live events from its WebSocket.
//
// The client already does RC §7's connection rules — login, ping/pong, close
// codes, backoff, UNAVAILABLE retries, resubscribing one zone at a time after
// a reconnect and a record-less ZoneChanged per zone afterwards. This package
// adds the zones, the per-zone change tokens in the sidecar (Pull), the
// TOKEN_EXPIRED resync, attachments through create_upload/get_download and
// the error mapping (MapError).
//
// The hub registers as DEVICE_KIND_HUB with an empty attestation and logs in
// with its Ed25519 signature only (relay proto README, "Vouched hubs"). It is
// unvouched until a phone vouches for its key (vouch_hub) and puts it into a
// slot: until then the relay opens only get_account_state, subscribe, its
// pair/<slot> zones and close_pairing to it, and answers every other op
// HUB_NOT_VOUCHED (transport.ErrNotVouched), also on an open socket. Vouched
// reads that from the account state; the hub does not count itself on the
// relay until the account state shows it in a paying phone's slot (Admitted).
package relay

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// DeviceKind is the kind the Go hub registers as, in test and live mode
// alike. The relay treats both hub kinds as one (DEVICE_KIND_MAC is the Swift
// app's), so a hub an older build registered as a Mac stays the same device.
const DeviceKind = relayv1.DeviceKind_DEVICE_KIND_HUB

// eventBuffer is the Events channel's capacity. The pump never drops an
// event: when the channel is full it waits (the client keeps folding zone
// events meanwhile and queues its controls).
const eventBuffer = 256

// accountTimeout bounds one get_account_state the pump starts on its own.
const accountTimeout = 30 * time.Second

// transferTimeout bounds one attachment PUT or GET.
const transferTimeout = 5 * time.Minute

// NewClient is a relay client for the hub's relay_auth key at origin,
// registering as DeviceKind.
func NewClient(origin string, relayAuth ed25519.PrivateKey, opts ...client.Option) *client.Client {
	return client.New(origin, relayAuth, DeviceKind, opts...)
}

// Options configures a Transport.
type Options struct {
	// Origin is the relay origin the client signs in to (reported by Origin).
	Origin string
	// HubRelayID is the hub's relay_device_id (the zone owner in data/<hub>
	// and relay/<hub>/<phone>); "" means the client's own. Connect refuses an
	// id that is not the client's.
	HubRelayID string
	// Store holds the per-zone change tokens Pull reads and writes.
	Store *state.Store
	// Clock stamps client_modified_at_ms (nil = time.Now).
	Clock func() time.Time
	// AssetDir is the sealer's own asset directory: Save uploads only regular
	// files under it (symlinks refused), so a file swapped after sealing
	// elsewhere never goes out. "" refuses every asset.
	AssetDir string
	// HTTP carries attachment PUTs and GETs (nil = a client with a 5-minute
	// timeout). Relay ops go through the relay client's own HTTP client. The
	// transport uses a copy with its own redirect rule (see checkRedirect).
	HTTP *http.Client
	// MaxAttachmentBytes caps one download (0 = MaxAttachmentBytes).
	MaxAttachmentBytes int64
}

// MaxAttachmentBytes is the relay's attachment cap (RELAY_MAX_ATTACHMENT_BYTES
// default at the pinned commit): a download past it is refused.
const MaxAttachmentBytes = 100 << 20

// Transport is transport.Transport over the hosted relay; safe for concurrent
// use.
type Transport struct {
	c      *client.Client
	o      Options
	http   *http.Client
	events chan transport.Event
	done   chan struct{}

	mu         sync.Mutex
	conn       *client.Conn
	closed     bool
	account    *relayv1.AccountState
	refreshing bool
	refreshDue bool
	wg         sync.WaitGroup
}

var _ transport.Transport = (*Transport)(nil)

// New returns a transport over c; Connect starts its live events.
func New(c *client.Client, o Options) *Transport {
	if o.HubRelayID == "" {
		o.HubRelayID = c.DeviceID()
	}
	if o.Clock == nil {
		o.Clock = time.Now
	}
	if o.MaxAttachmentBytes <= 0 {
		o.MaxAttachmentBytes = MaxAttachmentBytes
	}
	hc := &http.Client{Timeout: transferTimeout}
	if o.HTTP != nil {
		copied := *o.HTTP
		hc = &copied
	}
	hc.CheckRedirect = checkRedirect
	return &Transport{
		c: c, o: o, http: hc, events: make(chan transport.Event, eventBuffer), done: make(chan struct{}),
	}
}

// Kind implements transport.Transport.
func (t *Transport) Kind() transport.Kind { return transport.KindRelay }

// Events implements transport.Transport. Zone events mean "pull this zone";
// they come after Connect (one per zone), after every reconnect (the client's
// record-less ZoneChanged), on every server ZoneChanged and after a Save or
// Delete the relay refused (the batch may be partly written: re-read).
func (t *Transport) Events() <-chan transport.Event { return t.events }

// Origin is the relay origin this transport was configured with.
func (t *Transport) Origin() string { return t.o.Origin }

// Connect registers the hub (idempotent), opens the WebSocket, subscribes
// zones and reads the account state, then emits a zone event per zone so the
// consumer pulls each from its token. After every reconnect the client
// resubscribes and emits a record-less ZoneChanged per zone; the transport
// turns each into a zone event and reads the account state again.
func (t *Transport) Connect(ctx context.Context, zones []string) error {
	if t.o.HubRelayID != t.c.DeviceID() {
		return errors.New("relay: the hub relay id is not the client's device id")
	}
	t.mu.Lock()
	busy := t.conn != nil || t.closed
	t.mu.Unlock()
	if busy {
		return errors.New("relay: transport already connected or closed")
	}
	if _, err := t.c.Register(ctx); err != nil {
		return fmt.Errorf("relay: register: %w", MapError(err))
	}
	conn, err := t.c.Connect(ctx)
	if err != nil {
		return fmt.Errorf("relay: connect: %w", MapError(err))
	}
	if len(zones) > 0 {
		if err := conn.Subscribe(ctx, zones...); err != nil && !errors.Is(err, client.ErrDisconnected) {
			_ = conn.Close()
			return fmt.Errorf("relay: subscribe: %w", MapError(err))
		}
	}
	if _, err := t.AccountState(ctx); err != nil {
		_ = conn.Close()
		return fmt.Errorf("relay: account state: %w", err)
	}
	t.mu.Lock()
	if t.closed || t.conn != nil {
		t.mu.Unlock()
		_ = conn.Close()
		return errors.New("relay: transport already connected or closed")
	}
	t.conn = conn
	t.wg.Add(2)
	t.mu.Unlock()
	go t.pump(conn)
	go func() {
		defer t.wg.Done()
		for _, z := range zones {
			t.emit(transport.Event{Zone: z})
		}
	}()
	return nil
}

// Close closes the WebSocket and stops the events; ops keep working over
// HTTPS. Events is not closed.
func (t *Transport) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	conn := t.conn
	close(t.done)
	t.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
	t.wg.Wait()
	return nil
}

// emit hands an event to the consumer, waiting for room; it gives up only
// when the transport is closed.
func (t *Transport) emit(ev transport.Event) {
	select {
	case t.events <- ev:
	case <-t.done:
	}
}

// pump turns the client's events into transport events.
func (t *Transport) pump(conn *client.Conn) {
	defer t.wg.Done()
	for ev := range conn.Events() {
		switch {
		case ev.Err != nil:
			t.emit(transport.Event{Zone: ev.Err.Zone, Err: fmt.Errorf("relay: zone dropped: %w", t.noteError(MapError(ev.Err.Err)))})
		case ev.GetZoneChanged() != nil:
			zc := ev.GetZoneChanged()
			resync := zc.GetSeq() == 0 && zc.Record == nil
			if resync {
				// The client's marker after a reconnect (or a folded overflow).
				t.refreshAccount()
			}
			t.emit(transport.Event{Zone: zc.GetZone(), Resync: resync})
		case ev.GetControl() != nil:
			c, ok := controlOf(ev.GetControl())
			if !ok {
				continue
			}
			switch c.Kind {
			case transport.PairingOpened:
			case transport.SlotAdded:
				// Read before the event goes out, so its consumer sees the
				// slot in Vouched: one read per SLOT_ADDED, never a poll.
				t.readAccountNow()
			default:
				t.refreshAccount()
			}
			t.emit(transport.Event{Control: &c})
		}
	}
	select {
	case <-t.done:
	default:
		// The client closed its events on its own: the relay no longer
		// speaks this protocol version.
		t.emit(transport.Event{Err: fmt.Errorf("relay: connection ended: %w", transport.ErrUnsupportedVersion)})
	}
}

// controlOf maps a relay control event; SESSION_EXPIRED never reaches us (the
// client logs in again by itself) and an unknown kind is skipped.
func controlOf(c *relayv1.Control) (transport.Control, bool) {
	var k transport.ControlKind
	switch c.GetKind() {
	case relayv1.ControlKind_CONTROL_KIND_ENTITLEMENT_EXPIRED:
		k = transport.EntitlementExpired
	case relayv1.ControlKind_CONTROL_KIND_SUBSCRIPTION_MOVED:
		k = transport.SubscriptionMoved
	case relayv1.ControlKind_CONTROL_KIND_SLOT_REMOVED:
		k = transport.SlotRemoved
	case relayv1.ControlKind_CONTROL_KIND_PAIRING_OPENED:
		k = transport.PairingOpened
	case relayv1.ControlKind_CONTROL_KIND_SESSION_EXPIRED:
		k = transport.SessionExpired
	case relayv1.ControlKind_CONTROL_KIND_SLOT_ADDED:
		k = transport.SlotAdded
	default:
		return transport.Control{}, false
	}
	return transport.Control{Kind: k, Detail: c.GetDetail()}, true
}

// refreshAccount re-reads the account state in the background, one read at a
// time; a request during a read runs one more read after it. A failed read is
// reported as an event (the cached state stays).
func (t *Transport) refreshAccount() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return
	}
	if t.refreshing {
		t.refreshDue = true
		return
	}
	t.refreshing = true
	t.wg.Add(1)
	go func() {
		defer t.wg.Done()
		for {
			ctx, cancel := context.WithTimeout(context.Background(), accountTimeout)
			go func() {
				select {
				case <-t.done:
					cancel()
				case <-ctx.Done():
				}
			}()
			_, err := t.AccountState(ctx)
			cancel()
			if err != nil && !errors.Is(err, context.Canceled) {
				t.emit(transport.Event{Err: fmt.Errorf("relay: account state: %w", err)})
			}
			t.mu.Lock()
			if !t.refreshDue || t.closed {
				t.refreshing = false
				t.mu.Unlock()
				return
			}
			t.refreshDue = false
			t.mu.Unlock()
		}
	}()
}

// readAccountNow reads the account state once, bounded by accountTimeout and
// by the transport's close; a failure is reported as an event.
func (t *Transport) readAccountNow() {
	ctx, cancel := context.WithTimeout(context.Background(), accountTimeout)
	defer cancel()
	go func() {
		select {
		case <-t.done:
			cancel()
		case <-ctx.Done():
		}
	}()
	if _, err := t.AccountState(ctx); err != nil && !errors.Is(err, context.Canceled) {
		t.emit(transport.Event{Err: fmt.Errorf("relay: account state: %w", err)})
	}
}

// AccountState reads the hub's account state (the phones holding it in a
// slot) and keeps it for Vouched and Admitted.
func (t *Transport) AccountState(ctx context.Context) (*relayv1.AccountState, error) {
	resp, err := t.c.Do(ctx, &relayv1.Request{Op: &relayv1.Request_GetAccountState{GetAccountState: &relayv1.GetAccountState{}}})
	if err != nil {
		return nil, MapError(err)
	}
	st := resp.GetAccountState()
	if st == nil {
		return nil, errors.New("relay: get_account_state: no account state in the answer")
	}
	t.mu.Lock()
	t.account = st
	t.mu.Unlock()
	return st, nil
}

// Vouched reports whether the last account state shows the hub in any
// phone's slot, paying or not: only then does the relay open the data zone,
// the mailboxes and set_hub_readers to it. A HUB_NOT_VOUCHED answer to any op
// clears it until an account state says otherwise.
func (t *Transport) Vouched() bool {
	return t.anyPhone(func(*relayv1.SlotHolder) bool { return true })
}

// Admitted reports whether the last account state shows the hub in a paying
// phone's slot: only then does the hub count itself on the relay.
func (t *Transport) Admitted() bool {
	return t.anyPhone((*relayv1.SlotHolder).GetPaying)
}

// anyPhone: a phone of the last account state matches.
func (t *Transport) anyPhone(match func(*relayv1.SlotHolder) bool) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return slices.ContainsFunc(t.account.GetPhones(), match)
}

// LastAccountState is a copy of the last account state read (an empty one
// before any read, or after HUB_NOT_VOUCHED).
func (t *Transport) LastAccountState() *relayv1.AccountState {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.account == nil {
		return &relayv1.AccountState{}
	}
	return proto.Clone(t.account).(*relayv1.AccountState)
}

// do runs one op over HTTPS and maps its error. HUB_NOT_VOUCHED means the
// hub is in no slot now, whatever the last account state said.
func (t *Transport) do(ctx context.Context, req *relayv1.Request) (*relayv1.Response, error) {
	resp, err := t.c.Do(ctx, req)
	if err != nil {
		return nil, t.noteError(MapError(err))
	}
	return resp, nil
}

// noteError forgets the cached account state's slots on HUB_NOT_VOUCHED and
// returns err.
func (t *Transport) noteError(err error) error {
	if errors.Is(err, transport.ErrNotVouched) {
		t.mu.Lock()
		t.account = &relayv1.AccountState{}
		t.mu.Unlock()
	}
	return err
}

// rereadZones asks the consumer to re-read zones after a refused write: the
// relay may have written part of the batch.
func (t *Transport) rereadZones(zones []string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return
	}
	seen := map[string]bool{}
	var todo []string
	for _, z := range zones {
		if !seen[z] {
			seen[z] = true
			todo = append(todo, z)
		}
	}
	t.wg.Add(1)
	go func() {
		defer t.wg.Done()
		for _, z := range todo {
			t.emit(transport.Event{Zone: z})
		}
	}()
}

func wireExpect(item *relayv1.SaveItem, e transport.Expect) error {
	switch e.Mode {
	case transport.ExpectNone:
	case transport.ExpectAbsent:
		item.Expect = &relayv1.SaveItem_MustNotExist{MustNotExist: true}
	case transport.ExpectSeq:
		item.Expect = &relayv1.SaveItem_ExpectedSeq{ExpectedSeq: e.Seq}
	default:
		return fmt.Errorf("relay: unknown expect mode %d", e.Mode)
	}
	return nil
}

// Save implements transport.Transport. Before any I/O it refuses the whole
// call with secure.ErrUnsealed when a record did not come from the Sealer or
// carries an asset file outside Options.AssetDir. An asset in a pairing zone
// is refused per item with transport.ErrForbidden (the relay allows none
// there). Each other asset is uploaded first (create_upload, then a PUT of the
// sealed file to the opaque URL), then the records are saved with their
// attachment ids. A refused save also emits a zone event per zone in it.
func (t *Transport) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	assets := make([]*os.File, len(items))
	defer func() {
		for _, f := range assets {
			if f != nil {
				_ = f.Close()
			}
		}
	}()
	out := make([]transport.Outcome, len(items))
	wire := make([]*relayv1.SaveItem, 0, len(items))
	index := make([]int, 0, len(items)) // wire position → item index
	for i, it := range items {
		r := it.Record
		if !r.Sealed() {
			return nil, fmt.Errorf("relay: save item %d: %w", i, secure.ErrUnsealed)
		}
		w := &relayv1.SaveItem{Record: &relayv1.Record{
			Zone: r.Zone(), Name: r.WireName(), Envelope: r.Envelope(), ClientModifiedAtMs: t.o.Clock().UnixMilli(),
		}}
		if err := wireExpect(w, it.Expect); err != nil {
			return nil, fmt.Errorf("relay: save item %d: %w", i, err)
		}
		if p := r.AssetPath(); p != "" {
			if isPairZone(r.Zone()) {
				out[i] = transport.Outcome{Refused: fmt.Errorf("relay: attachment in a pairing zone: %w", transport.ErrForbidden)}
				continue
			}
			f, err := t.openAsset(p)
			if err != nil {
				return nil, fmt.Errorf("relay: save item %d: %w", i, err)
			}
			assets[i] = f
		}
		wire = append(wire, w)
		index = append(index, i)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if len(wire) == 0 {
		return out, nil
	}
	for k, w := range wire {
		if f := assets[index[k]]; f != nil {
			id, err := t.upload(ctx, w.GetRecord().GetZone(), f)
			if err != nil {
				return nil, fmt.Errorf("relay: save item %d: upload: %w", index[k], err)
			}
			w.Record.AttachmentId = id
		}
	}
	resp, err := t.do(ctx, &relayv1.Request{Op: &relayv1.Request_Save{Save: &relayv1.Save{Items: wire}}})
	if err != nil {
		zones := make([]string, len(wire))
		for k, w := range wire {
			zones[k] = w.GetRecord().GetZone()
		}
		t.rereadZones(zones)
		return nil, fmt.Errorf("relay: save: %w", err)
	}
	if err := saveOutcomes(resp.GetSave(), index, out); err != nil {
		return nil, fmt.Errorf("relay: save: %w", err)
	}
	return out, nil
}

// saveOutcomes fills out from a save answer: saved records in request order,
// conflicts by their index in the request. An answer whose conflict indexes
// are out of range or repeated, or that does not cover the request exactly,
// is an error.
func saveOutcomes(res *relayv1.SaveResult, index []int, out []transport.Outcome) error {
	conflicts := make(map[int]*relayv1.SaveConflict, len(res.GetConflicts()))
	for _, c := range res.GetConflicts() {
		k := int(c.GetIndex())
		if k >= len(index) {
			return fmt.Errorf("conflict index %d out of range for %d items", k, len(index))
		}
		if _, dup := conflicts[k]; dup {
			return fmt.Errorf("conflict index %d repeated", k)
		}
		conflicts[k] = c
	}
	saved := res.GetSaved()
	if len(conflicts)+len(saved) != len(index) {
		return fmt.Errorf("%d saved and %d conflicts for %d items", len(saved), len(conflicts), len(index))
	}
	next := 0
	for k, i := range index {
		if c, ok := conflicts[k]; ok {
			out[i] = transport.Outcome{Conflict: stored(c.Current)}
			continue
		}
		out[i] = transport.Outcome{Saved: true, RecordSeq: saved[next].GetRecordSeq()}
		next++
	}
	return nil
}

// Delete implements transport.Transport. The relay has no "must be absent"
// delete, so transport.ExpectAbsent is refused before any I/O.
func (t *Transport) Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	wire := make([]*relayv1.DeleteItem, len(items))
	for i, it := range items {
		w := &relayv1.DeleteItem{Name: it.Name}
		switch it.Expect.Mode {
		case transport.ExpectNone:
		case transport.ExpectSeq:
			seq := it.Expect.Seq
			w.ExpectedSeq = &seq
		default:
			return nil, fmt.Errorf("relay: delete item %d: expect mode %d is not supported", i, it.Expect.Mode)
		}
		wire[i] = w
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	resp, err := t.do(ctx, &relayv1.Request{Op: &relayv1.Request_Delete{Delete: &relayv1.Delete{Zone: zone, Items: wire}}})
	if err != nil {
		t.rereadZones([]string{zone})
		return nil, fmt.Errorf("relay: delete: %w", err)
	}
	out := make([]transport.Outcome, len(items))
	for i := range out {
		out[i] = transport.Outcome{Saved: true}
	}
	for _, c := range resp.GetDelete().GetConflicts() {
		i := int(c.GetIndex())
		if i >= len(out) {
			return nil, fmt.Errorf("relay: delete: conflict index %d out of range", i)
		}
		out[i] = transport.Outcome{Conflict: stored(c.Current)}
	}
	return out, nil
}

// stored maps a relay record (nil stays nil). ServerAt is the writer's
// client_modified_at_ms: the relay keeps no server time per record, so a
// writer's skewed clock skews it.
func stored(r *relayv1.Record) *transport.Stored {
	if r == nil {
		return nil
	}
	return &transport.Stored{
		Zone: r.GetZone(), Name: r.GetName(), Envelope: r.GetEnvelope(), RecordSeq: r.GetRecordSeq(),
		ServerAt: time.UnixMilli(r.GetClientModifiedAtMs()), AttachmentID: r.GetAttachmentId(),
	}
}

// Changes implements transport.Transport: one page after since (Reset when
// since is 0). On TOKEN_EXPIRED it also resets the zone's stored token to 0,
// so the next Pull is a full resync of the zone. Consumers use Pull, which
// keeps the zone's token; Changes is the seam's raw page read.
func (t *Transport) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	resp, err := t.do(ctx, &relayv1.Request{Op: &relayv1.Request_Changes{Changes: &relayv1.Changes{Zone: zone, SinceSeq: since}}})
	if errors.Is(err, transport.ErrTokenExpired) {
		if serr := t.o.Store.SetZoneToken(zone, 0); serr != nil {
			return transport.Batch{}, fmt.Errorf("relay: changes: %w (resetting the zone token: %w)", err, serr)
		}
	}
	if err != nil {
		return transport.Batch{}, fmt.Errorf("relay: changes: %w", err)
	}
	page := resp.GetChanges()
	b := transport.Batch{NewSeq: page.GetNewSeq(), More: page.GetMore(), Deleted: page.GetDeleted(), Reset: since == 0}
	for _, r := range page.GetChanged() {
		if r.GetDeleted() {
			b.Deleted = append(b.Deleted, r.GetName())
			continue
		}
		b.Changed = append(b.Changed, *stored(r))
	}
	return b, nil
}

// Pull reads zone's changes from its stored token, page by page: apply sees
// each page and the token moves to the page's new_seq only after apply
// returned nil, so a crash never skips a page. When the token has expired
// (TOKEN_EXPIRED) the zone is pulled again from 0, once; that first page has
// Reset set (as does any pull from token 0), so apply can drop records whose
// tombstones the relay purged meanwhile.
func (t *Transport) Pull(ctx context.Context, zone string, apply func(transport.Batch) error) error {
	since, err := t.o.Store.ZoneToken(zone)
	if err != nil {
		return err
	}
	resynced := false
	for {
		b, err := t.Changes(ctx, zone, since)
		if errors.Is(err, transport.ErrTokenExpired) && !resynced && since != 0 {
			since, resynced = 0, true
			continue
		}
		if err != nil {
			return err
		}
		if err := apply(b); err != nil {
			return err
		}
		if err := t.o.Store.SetZoneToken(zone, b.NewSeq); err != nil {
			return err
		}
		since = b.NewSeq
		if !b.More {
			return nil
		}
	}
}

// Download implements transport.Transport: get_download for the attachment
// of a record in zone, then a GET of the opaque URL into dst (a hub-owned
// path), capped at Options.MaxAttachmentBytes.
func (t *Transport) Download(ctx context.Context, zone, attachmentID, dst string) error {
	resp, err := t.do(ctx, &relayv1.Request{Op: &relayv1.Request_GetDownload{GetDownload: &relayv1.GetDownload{Zone: zone, AttachmentId: attachmentID}}})
	if err != nil {
		return fmt.Errorf("relay: get_download: %w", err)
	}
	return t.fetch(ctx, resp.GetDownload().GetUrl(), dst)
}

func isPairZone(zone string) bool { return strings.HasPrefix(zone, transport.PairZone("")) }

// openAsset opens a record's sealed asset file for upload only when it is a
// regular file under Options.AssetDir, reached without a symlink: the Sealer
// checked the file at seal time, and its own directory is where nothing else
// writes. The returned handle is what gets uploaded, so the path is resolved
// once. Only the last component is opened with O_NOFOLLOW; a directory
// component swapped for a symlink between the parent's resolution and the open
// would escape — accepted, since AssetDir is the hub's private 0700 directory.
// O_NONBLOCK keeps a FIFO from blocking the open; it is then refused as not a
// regular file.
func (t *Transport) openAsset(path string) (*os.File, error) {
	if t.o.AssetDir == "" {
		return nil, fmt.Errorf("%w: no asset directory configured", secure.ErrUnsealed)
	}
	root, err := filepath.EvalSymlinks(t.o.AssetDir)
	if err != nil {
		return nil, fmt.Errorf("relay: asset directory: %w", err)
	}
	if !filepath.IsAbs(path) {
		return nil, fmt.Errorf("%w: asset path is not absolute", secure.ErrUnsealed)
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(filepath.Clean(path)))
	if err != nil {
		return nil, fmt.Errorf("relay: asset path: %w", err)
	}
	rel, err := filepath.Rel(root, parent)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return nil, fmt.Errorf("%w: asset file is outside the sealer's directory", secure.ErrUnsealed)
	}
	f, err := openNoFollow(filepath.Join(parent, filepath.Base(path)))
	if err != nil {
		return nil, fmt.Errorf("%w: asset file: %w", secure.ErrUnsealed, err)
	}
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
		_ = f.Close()
		return nil, fmt.Errorf("%w: asset is not a non-empty regular file", secure.ErrUnsealed)
	}
	return f, nil
}
