package hub

import (
	"context"
	"crypto/ed25519"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"watchtower/docs/guide"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
)

// The running hub's own cadence.
const (
	// passEvery is the processor's backstop pass (events are best effort).
	passEvery = 30 * time.Second
	// linkEvery is the backstop for the readers, the pair keyboxes and the
	// mailbox subscriptions: no event fires after promote_pairing.
	linkEvery = time.Minute
	// houseEvery is the housekeeping backstop between daemon cycles: link
	// sweep, epoch rotation, the daily hygiene (which gates itself).
	houseEvery = 10 * time.Minute
	// opTimeout bounds one network step of the worker.
	opTimeout = 2 * time.Minute
)

// assetDirName is the sealer's own asset directory inside the hub dir: the
// relay transport uploads only files under it.
const assetDirName = "assets"

// workbenchOnly is what MobileSync = workbench_only keeps (the Swift
// SliceKind.workbenchOnly): the sources' workbench kinds and the hub's own
// liveness and link records.
func workbenchOnly(k slices.Kind) bool {
	if k == slices.KindHeartbeat || k == slices.KindDeviceGrant {
		return true
	}
	for _, w := range sources.WorkbenchOnlyKinds {
		if w == k {
			return true
		}
	}
	return false
}

// readersSetter is the hosted relay's set_hub_readers for the linked phones.
type readersSetter interface {
	SetLinkedReaders(ctx context.Context, linked []string) error
}

// zoneWatcher is the hosted relay's subscription of a zone added after
// Connect (a newly linked phone's mailbox).
type zoneWatcher interface {
	WatchZone(ctx context.Context, zone string) error
}

// admission is the hosted relay's view of whether the hub is in a paying
// phone's slot.
type admission interface{ Admitted() bool }

// hubRuntime is the hub while it runs: the identity it borrows to the
// keyring, the transport, the link center, the processor and the publisher,
// one worker goroutine and the publisher's.
type hubRuntime struct {
	sup     *supervisor
	st      *state.Store
	mode    string
	name    string
	id      identity.Identity
	kr      *identity.Keyring
	tr      transport.Transport
	relayID string
	data    string
	center  *link.Center
	proc    *actions.Processor
	pub     *slices.Publisher
	wiring  *wiring // nil without a database

	cancel  context.CancelFunc
	wg      sync.WaitGroup
	watched map[string]bool // zones subscribed (worker only)
	// subRetry backs off a zone whose subscription the relay refused, and
	// admitted is the admission the last link upkeep saw (worker only).
	subRetry map[string]*subRetry
	admitted bool

	passKick, linkKick, houseKick chan struct{}

	mu          sync.Mutex
	unreachable bool
	lastRelay   time.Time
	lastTouch   time.Time // a phone's last write the hub saw (the active poll)
}

// loadIdentity reads the hub identity from the hub dir's 0600 file,
// creating it on the first start (spec §7.3: a headless host's store).
func loadIdentity(dir string) (identity.Identity, error) {
	fs := identity.FileStore{Path: filepath.Join(dir, identity.FileName)}
	id, err := fs.Load()
	if errors.Is(err, identity.ErrNoIdentity) {
		if id, err = identity.New(); err != nil {
			return identity.Identity{}, fmt.Errorf("%w: %w", ErrStartFailed, err)
		}
		if err := fs.Save(id); err != nil {
			id.Zero()
			return identity.Identity{}, fmt.Errorf("%w: %w", ErrStartFailed, err)
		}
		return id, nil
	}
	if err != nil {
		return identity.Identity{}, fmt.Errorf("%w: %w", ErrStartFailed, err)
	}
	return id, nil
}

func dataZoneOf(id identity.Identity) string {
	return transport.DataZone(identity.RelayDeviceID(id.RelayAuth.Public().(ed25519.PublicKey)))
}

// relayTransport is the production transport: the hosted relay at
// RelayOrigin, signed in with relay_auth, its zone tokens in the sidecar
// and its uploads confined to the hub's asset dir. With zones it connects
// (live events); without, it serves ops over HTTPS only (the policy wipe).
func (o Options) relayTransport(ctx context.Context, id identity.Identity, st *state.Store, zones []string) (transport.Transport, error) {
	assets := filepath.Join(o.Dir, assetDirName)
	if err := os.MkdirAll(assets, 0o700); err != nil {
		return nil, fmt.Errorf("%w: creating the asset dir: %w", ErrStartFailed, err)
	}
	var opts []client.Option
	if o.httpClient != nil {
		opts = append(opts, client.WithHTTPClient(o.httpClient))
	}
	t := relay.New(relay.NewClient(o.RelayOrigin, id.RelayAuth, opts...), relay.Options{
		Origin: o.RelayOrigin, Store: st, Clock: o.Clock, AssetDir: assets, HTTP: o.httpClient,
	})
	if len(zones) == 0 {
		return t, nil
	}
	// The relay refuses a subscription to the hub's own zones (FORBIDDEN)
	// until a phone holds the hub in a slot, and Connect subscribes all or
	// none: connect with none, so a hub not paired yet still gets
	// PAIRING_OPENED, and the link upkeep subscribes each zone (WatchZone),
	// retrying a refused one on its timer.
	if err := t.Connect(ctx, nil); err != nil {
		_ = t.Close()
		return nil, err
	}
	return t, nil
}

func closeTransport(t transport.Transport) {
	if c, ok := t.(io.Closer); ok {
		_ = c.Close()
	}
}

// newHubRuntime starts the hub: identity → keyring → transport → link,
// processor and publisher, then its goroutines.
func newHubRuntime(ctx context.Context, s *supervisor, mode, name string) (*hubRuntime, error) {
	o, st := s.o, s.st
	if err := ensureEnabledAt(st, o.Clock()); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrStartFailed, err)
	}
	id, err := loadIdentity(o.Dir)
	if err != nil {
		return nil, err
	}
	h := &hubRuntime{
		sup: s, st: st, mode: mode, name: name, id: id, watched: map[string]bool{}, subRetry: map[string]*subRetry{},
		passKick: make(chan struct{}, 1), linkKick: make(chan struct{}, 1), houseKick: make(chan struct{}, 1),
	}
	ok := false
	defer func() {
		if !ok {
			if h.tr != nil {
				closeTransport(h.tr)
			}
			if h.kr != nil {
				h.kr.Wipe()
			}
			h.id.Zero()
		}
	}()
	h.kr, err = identity.NewKeyring(h.id, st, o.Clock)
	if errors.Is(err, identity.ErrSealedKeyUnreadable) {
		// The sidecar's sealed keys do not open under this identity.
		return nil, fmt.Errorf("%w: %w", ErrSidecarUnreadable, err)
	}
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrStartFailed, err)
	}
	authPub := h.id.RelayAuth.Public().(ed25519.PublicKey)
	h.relayID = identity.RelayDeviceID(authPub)
	h.data = transport.DataZone(h.relayID)
	zones, err := h.zones()
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrStartFailed, err)
	}
	if h.tr, err = o.newTransport(ctx, h.id, st, zones); err != nil {
		return nil, err
	}
	if _, ok := h.tr.(zoneWatcher); !ok {
		// A transport that sends every zone's events (memfake).
		for _, z := range zones {
			h.watched[z] = true
		}
	}

	sealer := secure.NewSealer(h.kr)
	opener := secure.NewOpener(h.kr, h.kr)
	var pub *slices.Publisher
	h.center = link.NewCenter(link.Config{
		Store: st, Keys: h.kr, Opener: opener, Host: link.HeadlessHost(name, authPub), Clock: o.Clock,
		Publish: func(kinds ...string) {
			pub.PublishSoon(toKinds(kinds)...)
			h.kick(h.linkKick)
		},
	})
	d := actions.NewDispatcher()
	actions.RegisterProbe(d)
	if o.Register != nil {
		o.Register(d)
	}
	h.proc = actions.NewProcessor(actions.Config{
		Store: st, Transport: h.tr, Sealer: sealer, Opener: opener, Keys: h.kr, Dispatcher: d,
		HubRelayID: h.relayID, Clock: o.Clock,
		Nudge: func(kinds []string) { pub.PublishSoon(toKinds(kinds)...) },
	})
	sweepTemps(o)
	if o.DB != nil {
		// Registered after the processor exists: the handlers' start may
		// already late-echo a held line it ends. No pass runs before the
		// worker starts, so the table is complete by the first dispatch.
		if h.wiring, err = h.buildWiring(o, st, mode, d, h.proc.LateEcho); err != nil {
			return nil, fmt.Errorf("%w: %w", ErrStartFailed, err)
		}
		// PROJ-16: a phone whose typing is taken away fails its held lines.
		h.center.OnRevoke(h.wiring.handlers.Revoked)
	}
	srcs := []slices.Source{slices.GrantSource(h.center), slices.HeartbeatSource(h.heartbeat(st, name))}
	if h.wiring != nil {
		srcs = append(srcs, h.wiring.set.Sources...)
	}
	if o.Sources != nil {
		srcs = append(srcs, o.Sources(st)...)
	}
	if mode == policy.MobileWorkbenchOnly {
		kept := srcs[:0]
		for _, src := range srcs {
			if workbenchOnly(src.Kind()) {
				kept = append(kept, src)
			}
		}
		srcs = kept
	}
	pub = slices.NewPublisher(slices.Config{
		Store: st, Transport: h.tr, Sealer: sealer, DataZone: h.data, Sources: srcs, Clock: o.Clock,
		Linked: func() (bool, error) {
			devices, err := st.Devices()
			return len(devices) > 0, err
		},
	})
	h.pub = pub

	hctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	if h.wiring != nil {
		h.wiring.openWatch(ctx, o.DB, h.touched, o.Clock)
		// Seeded before the publisher's start cycle reads the timeline.
		h.startWiring(hctx, h.wiring)
	}
	h.trace("publisher")
	h.wg.Add(3)
	go func() {
		defer h.wg.Done()
		_ = pub.Run(hctx)
	}()
	go func() {
		defer h.wg.Done()
		h.forwardPairEvents(hctx)
	}()
	go func() {
		defer h.wg.Done()
		h.work(hctx)
	}()
	h.kick(h.passKick)
	h.kick(h.linkKick)
	h.kick(h.houseKick)
	ok = true
	return h, nil
}

// ensureEnabledAt stamps hub_meta.enabled_at once, as the Swift hub does
// (seconds since 1970 as a decimal string).
func ensureEnabledAt(st *state.Store, now time.Time) error {
	if _, ok, err := st.Meta(state.MetaEnabledAt); err != nil || ok {
		return err
	}
	return st.SetMeta(state.MetaEnabledAt, strconv.FormatFloat(float64(now.UnixNano())/1e9, 'f', -1, 64))
}

// heartbeat is the heartbeat source's facts.
func (h *hubRuntime) heartbeat(st *state.Store, name string) slices.HeartbeatFacts {
	f := slices.HeartbeatFacts{
		HubID: h.kr.HubID().String(), MacName: name, AppVersion: guide.Version, Flavor: wire.FlavorDefault,
		Clock: h.sup.o.Clock,
		LastPublishAt: func() (time.Time, bool) {
			if h.pub == nil {
				return time.Time{}, false
			}
			return h.pub.LastPublishAt()
		},
		LastRelayAt: func() (time.Time, bool) {
			h.mu.Lock()
			defer h.mu.Unlock()
			return h.lastRelay, !h.lastRelay.IsZero()
		},
	}
	if raw, ok, err := st.Meta(state.MetaEnabledAt); err == nil && ok {
		if secs, err := strconv.ParseFloat(raw, 64); err == nil {
			f.EnabledAt = time.Unix(0, int64(secs*1e9)).UTC()
		}
	}
	if h.sup.o.DB != nil {
		f.Accounts = slices.DBAccounts(h.sup.o.DB.DB)
	}
	return f
}

// publishSoon marks kinds dirty on the publisher (none before it is built).
func (h *hubRuntime) publishSoon(kinds ...slices.Kind) {
	if h.pub != nil {
		h.pub.PublishSoon(kinds...)
	}
}

// phoneLinked is the runners' gate: they work only while a phone is linked.
func (h *hubRuntime) phoneLinked() bool {
	devices, err := h.st.Devices()
	return err == nil && len(devices) > 0
}

// touch records that a phone wrote to the hub just now.
func (h *hubRuntime) touch() {
	h.mu.Lock()
	h.lastTouch = h.sup.o.Clock()
	h.mu.Unlock()
}

// touched is when a phone last wrote to the hub (zero = not since start).
func (h *hubRuntime) touched() time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.lastTouch
}

// trace tells a test the start's steps in order.
func (h *hubRuntime) trace(step string) {
	if h.sup.o.trace != nil {
		h.sup.o.trace(step)
	}
}

func toKinds(kinds []string) []slices.Kind {
	out := make([]slices.Kind, len(kinds))
	for i, k := range kinds {
		out[i] = slices.Kind(k)
	}
	return out
}

// zones is the data zone and the mailbox of each linked phone with a relay
// device id.
func (h *hubRuntime) zones() ([]string, error) {
	devices, err := h.st.Devices()
	if err != nil {
		return nil, err
	}
	zones := []string{h.data}
	for _, d := range devices {
		if d.RelayDeviceID != "" {
			zones = append(zones, transport.MailboxZone(h.relayID, d.RelayDeviceID))
		}
	}
	return zones, nil
}

// kick wakes the worker for one kind of work.
func (h *hubRuntime) kick(c chan struct{}) {
	select {
	case c <- struct{}{}:
	default:
	}
}

// reason is the running hub's status reason.
func (h *hubRuntime) reason() string {
	h.mu.Lock()
	unreachable := h.unreachable
	h.mu.Unlock()
	if unreachable {
		return ReasonRelayUnreachable
	}
	if a, ok := h.tr.(admission); ok && !a.Admitted() {
		return ReasonNotAdmitted
	}
	return ""
}

func (h *hubRuntime) setUnreachable(v bool) {
	h.mu.Lock()
	changed := h.unreachable != v
	h.unreachable = v
	h.mu.Unlock()
	if changed {
		h.sup.poke()
	}
}

// work is the hub's one worker: transport events, mailbox passes, link
// upkeep and housekeeping, one at a time.
func (h *hubRuntime) work(ctx context.Context) {
	passes := time.NewTicker(h.sup.o.passEvery)
	defer passes.Stop()
	links := time.NewTicker(h.sup.o.linkEvery)
	defer links.Stop()
	house := time.NewTicker(houseEvery)
	defer house.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-h.tr.Events():
			h.onEvent(ctx, ev)
		case <-h.passKick:
			h.pass(ctx)
		case <-passes.C:
			h.pass(ctx)
		case <-h.linkKick:
			h.linkUpkeep(ctx)
		case <-links.C:
			h.linkUpkeep(ctx)
		case <-h.houseKick:
			h.housekeeping(ctx)
		case <-house.C:
			h.housekeeping(ctx)
		}
	}
}

// onEvent handles one transport event.
func (h *hubRuntime) onEvent(ctx context.Context, ev transport.Event) {
	switch {
	case ev.Err != nil && ev.Zone != "":
		// The relay dropped this zone's subscription (refused on a
		// resubscribe): the link upkeep subscribes it again.
		log.Printf("hub: the %s subscription dropped (%s): subscribed again", zoneKind(ev.Zone, h.data), errClass(ev.Err))
		delete(h.watched, ev.Zone)
		delete(h.subRetry, ev.Zone)
		h.kick(h.linkKick)
	case ev.Err != nil:
		log.Printf("hub: transport event: %s", errClass(ev.Err))
		h.setUnreachable(true)
	case ev.Control != nil:
		h.onControl(ctx, *ev.Control)
	case ev.Zone != "":
		h.setUnreachable(false)
		if ev.Resync {
			// A reconnect: what the phones wait for goes out again, and
			// the account state the relay re-read may have new readers.
			h.pub.PublishSoon(slices.UrgentKinds...)
			h.kick(h.linkKick)
		}
		switch {
		case strings.HasPrefix(ev.Zone, transport.PairZone("")):
			h.pairing(ctx, strings.TrimPrefix(ev.Zone, transport.PairZone("")))
		case strings.HasPrefix(ev.Zone, transport.MailboxZone(h.relayID, "")):
			h.touch()
			h.pass(ctx)
		}
	}
}

// onControl handles a server control event.
func (h *hubRuntime) onControl(ctx context.Context, c transport.Control) {
	switch c.Kind {
	case transport.PairingOpened:
		h.pairing(ctx, c.Detail)
	case transport.EntitlementExpired, transport.SlotRemoved, transport.SubscriptionMoved:
		log.Printf("hub: relay control %d: readers synced again", c.Kind)
		h.kick(h.linkKick)
	case transport.SessionExpired:
		// The relay client signs in again by itself.
	}
}

// pairing reads a pairing slot's zone and answers its hellos.
func (h *hubRuntime) pairing(ctx context.Context, slot string) {
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	if err := h.center.OnPairingOpened(ctx, h.tr, slot); err != nil {
		log.Printf("hub: pairing slot read failed (%s)", errClass(err))
	}
}

// pass is one processor pass, run again at once while it left records.
func (h *hubRuntime) pass(ctx context.Context) {
	for range 10 {
		pctx, cancel := context.WithTimeout(ctx, opTimeout)
		rep, err := h.proc.Pass(pctx)
		cancel()
		if err != nil {
			log.Printf("hub: mailbox pass failed (%s)", errClass(err))
			return
		}
		h.mu.Lock()
		h.lastRelay = h.sup.o.Clock()
		if rep.Read > 0 {
			h.lastTouch = h.lastRelay
		}
		h.mu.Unlock()
		if rep.Remaining == 0 {
			return
		}
	}
	h.kick(h.passKick)
}

// linkUpkeep follows a link change (and backs it up on a timer): the pair
// keyboxes, the data zone's readers, the new phones' mailbox subscriptions,
// a pass over the mailboxes and the status.
func (h *hubRuntime) linkUpkeep(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	if err := h.center.PublishPairKeyboxes(ctx, h.tr); err != nil {
		log.Printf("hub: pair keyboxes not written (%s)", errClass(err))
	}
	if rs, ok := h.tr.(readersSetter); ok {
		if err := h.center.SyncReaders(ctx, rs.SetLinkedReaders); err != nil {
			log.Printf("hub: readers not synced (%s)", errClass(err))
		}
	}
	if zw, ok := h.tr.(zoneWatcher); ok {
		h.watchZones(ctx, zw)
	}
	h.pass(ctx)
	h.sup.poke()
}

// subRetry is one refused zone subscription: how often it failed in a row
// and when the next attempt is due.
type subRetry struct {
	fails int
	next  time.Time
}

// maxSubBackoff caps the wait between attempts to subscribe a refused zone.
const maxSubBackoff = houseEvery

// zoneKind names a zone in a log line (never its id).
func zoneKind(zone, data string) string {
	switch {
	case zone == data:
		return "data zone"
	case strings.HasPrefix(zone, transport.PairZone("")):
		return "pair zone"
	default:
		return "mailbox"
	}
}

// watchZones subscribes the hub's zones not subscribed yet. The relay
// refuses them (FORBIDDEN) until a phone holds the hub in a slot: a refused
// zone waits linkEvery, doubling up to maxSubBackoff, and is logged once
// until it succeeds; the hub becoming admitted (promote_pairing, which
// sends the hub no event) clears the waits. A subscription that takes means
// the relay is reachable.
func (h *hubRuntime) watchZones(ctx context.Context, zw zoneWatcher) {
	if a, ok := h.tr.(admission); ok {
		admitted := a.Admitted()
		if admitted && !h.admitted {
			clear(h.subRetry)
		}
		h.admitted = admitted
	}
	zones, err := h.zones()
	if err != nil {
		log.Printf("hub: reading the linked phones failed (%s)", errClass(err))
	}
	now := h.sup.o.Clock()
	for _, z := range zones {
		if h.watched[z] {
			continue
		}
		r := h.subRetry[z]
		if r != nil && now.Before(r.next) {
			continue
		}
		if err := zw.WatchZone(ctx, z); err != nil {
			if r == nil {
				r = &subRetry{}
				h.subRetry[z] = r
				log.Printf("hub: the %s not subscribed (%s): retried with backoff", zoneKind(z, h.data), errClass(err))
			}
			r.fails++
			wait := h.sup.o.linkEvery << min(r.fails-1, 10)
			r.next = now.Add(min(wait, maxSubBackoff))
			continue
		}
		delete(h.subRetry, z)
		h.watched[z] = true
		h.setUnreachable(false)
	}
}

// housekeeping is the per-cycle upkeep: expired link requests, the epoch's
// age and seq cap, and the daily hygiene (CloudKit sweep, ledger prune).
func (h *hubRuntime) housekeeping(ctx context.Context) {
	if err := h.center.Sweep(); err != nil {
		log.Printf("hub: link sweep failed (%s)", errClass(err))
	}
	rotated, err := h.kr.RotateIfDue()
	if err != nil {
		log.Printf("hub: epoch rotation check failed (%s)", errClass(err))
	}
	if rotated {
		h.pub.PublishSoon(slices.AllKinds...)
	}
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	defer cancel()
	if h.mode == policy.MobileWorkbenchOnly {
		// What the switch to workbench_only failed to delete: no source
		// publishes those kinds now, so whatever is left is retried here.
		if left, err := publishedRecords(h.st, workbenchOnly); err != nil {
			log.Printf("hub: reading what was published failed (%s)", errClass(err))
		} else {
			wipe(ctx, h.st, h.tr, h.data, left)
		}
	}
	if rep, err := h.proc.Hygiene(ctx); err != nil {
		log.Printf("hub: hygiene failed (%s)", errClass(err))
	} else if rep.Ran {
		log.Printf("hub: hygiene: %d mailbox records deleted, %d ledger rows pruned", rep.Deleted, rep.Pruned)
	}
	h.sup.poke()
}

// forwardPairEvents hands the link center's pairing narration to the
// control socket's pairing streams.
func (h *hubRuntime) forwardPairEvents(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-h.center.Events():
			h.sup.broadcast(ev)
		}
	}
}

// stop ends the goroutines; with keep set it then deletes from the data
// zone the published records whose kind keep refuses. The transport closes
// and the identity is zeroed last.
func (h *hubRuntime) stop(keep func(slices.Kind) bool) {
	h.cancel()
	h.wg.Wait()
	h.wiring.close()
	if keep != nil {
		ctx, cancel := context.WithTimeout(context.Background(), opTimeout)
		if published, err := publishedRecords(h.st, keep); err != nil {
			log.Printf("hub: reading what was published failed (%s)", errClass(err))
		} else {
			wipe(ctx, h.st, h.tr, h.data, published)
		}
		cancel()
	}
	closeTransport(h.tr)
	h.kr.Wipe()
	h.id.Zero()
}

// published is one record the publisher pushed: its plain record name and
// wire name.
type published struct{ record, wire string }

// publishedRecords lists the pushed records (slice_state) whose kind keep
// refuses.
func publishedRecords(st *state.Store, keep func(slices.Kind) bool) ([]published, error) {
	var out []published
	for _, k := range slices.AllKinds {
		if keep(k) {
			continue
		}
		recs, err := st.SliceHashes(string(k))
		if err != nil {
			return nil, err
		}
		for name, r := range recs {
			if r.WireName != "" {
				out = append(out, published{record: name, wire: r.WireName})
			}
		}
	}
	return out, nil
}

// wipe deletes recs from the data zone and forgets each one deleted (or
// already gone), so a later publish reseals it.
func wipe(ctx context.Context, st *state.Store, tr transport.Transport, zone string, recs []published) {
	if len(recs) == 0 {
		return
	}
	items := make([]transport.DeleteItem, len(recs))
	for i, r := range recs {
		items[i] = transport.DeleteItem{Name: r.wire}
	}
	out, err := tr.Delete(ctx, zone, items)
	if err != nil {
		log.Printf("hub: deleting %d published records failed (%s): retried", len(recs), errClass(err))
		return
	}
	var gone []string
	for i, o := range out {
		if i < len(recs) && o.Refused == nil {
			gone = append(gone, recs[i].record)
		}
	}
	err = st.WithTx(ctx, func(tx *sql.Tx) error {
		for _, r := range gone {
			if err := state.DeleteSliceState(tx, r); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		log.Printf("hub: forgetting deleted records failed (%s)", errClass(err))
		return
	}
	log.Printf("hub: %d published records deleted from the data zone", len(gone))
}
