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
	"sort"
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
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
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
	// linkSoonEvery and linkSoonFor: after a link change (a phone linked or
	// unlinked) the link check runs every linkSoonEvery until every linked
	// phone holds the hub in a slot, for at most linkSoonFor, so a phone
	// promoted after its link (promote_pairing sends the hub no event) is a
	// reader, and in live mode ends the pause, within seconds instead of at
	// the next linkEvery.
	linkSoonEvery = 2 * time.Second
	linkSoonFor   = 2 * time.Minute
	// houseEvery is the housekeeping backstop between daemon cycles: link
	// sweep, epoch rotation, the daily hygiene (which gates itself).
	houseEvery = 10 * time.Minute
	// opTimeout bounds one network step of the worker.
	opTimeout = 2 * time.Minute
)

// assetDirName is the sealer's own asset directory inside the hub dir: the
// relay transport uploads only files under it, and the CloudKit bridge reads
// assets only from it (one constant for both).
const assetDirName = cloudkit.AssetsDirName

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

// readersSetter is the hosted relay's set_hub_readers for the linked phones
// held in a slot by the account state given.
type readersSetter interface {
	SetReadersFrom(ctx context.Context, st *relayv1.AccountState, linked []string) error
}

// zoneWatcher is the hosted relay's subscription of a zone added after
// Connect (a newly linked phone's mailbox).
type zoneWatcher interface {
	WatchZone(ctx context.Context, zone string) error
}

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
	// paying is the relay-only rules' watch (nil when they are off), and
	// paused is true while no phone pays (guarded by mu).
	paying *PayingWatch
	paused bool
	// acct is the account-state door (nil without one); unvouched is true
	// while the relay has not vouched for the hub (mu); gateHeld is the
	// hold applyGate last applied (gateMu, which orders holds and releases).
	acct      *accountReader
	unvouched bool
	gateMu    sync.Mutex
	gateHeld  bool

	cancel  context.CancelFunc
	wg      sync.WaitGroup
	watched map[string]bool // zones subscribed (worker only)
	// subRetry backs off a zone whose subscription the relay refused, and
	// wasVouched is the vouch state the last link upkeep saw (worker only).
	subRetry   map[string]*subRetry
	wasVouched bool
	// lastPass is when the last mailbox pass started (worker only): the
	// CloudKit cadence counts from it (cloudkit_runtime.go).
	lastPass time.Time

	passKick, linkKick, houseKick chan struct{}
	// soonKick opens the link check's short-retry window (linkSoonFor).
	soonKick chan struct{}

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
		soonKick: make(chan struct{}, 1),
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
	if as, ok := h.tr.(accountStater); ok {
		h.acct = &accountReader{read: as.AccountState, vouched: h.vouched, clock: o.Clock}
	}
	if o.RelayOnlyRules {
		if h.acct == nil {
			return nil, fmt.Errorf("%w: the transport has no account state", ErrStartFailed)
		}
		h.paying = NewPayingWatch(h.readAccount)
		if o.payTimer != nil {
			h.paying.timer = o.payTimer
		}
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
			h.kick(h.soonKick)
			if h.paying != nil {
				// A link changed: a newly promoted phone may pay.
				h.paying.Recheck()
			}
		},
	})
	d := actions.NewDispatcher()
	actions.RegisterProbe(d)
	if o.Register != nil {
		o.Register(d)
	}
	h.proc = actions.NewProcessor(actions.Config{
		Store: st, Transport: h.tr, Sealer: sealer, Opener: opener, Keys: h.kr, Dispatcher: d,
		HubRelayID: h.relayID, Clock: o.Clock, Links: h.center,
		Nudge: func(kinds []string) { pub.PublishSoon(toKinds(kinds)...) },
		Hello: h.cloudKitHello,
	})
	sweepTemps(o, st)
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
		OnError: h.observe,
		Linked: func() (bool, error) {
			devices, err := st.Devices()
			return len(devices) > 0, err
		},
	})
	h.pub = pub
	if h.paying != nil {
		// Paused until the first account state shows a paying phone.
		h.paused = true
		log.Printf("hub: relay-only rules on: paused until the account state shows a paying phone")
	}
	if a, ok := h.tr.(relayAdmission); ok && h.acct != nil {
		// The account state Connect read takes the one door: it stamps the
		// phones it lists and sets the vouch state.
		st := a.LastAccountState()
		h.acct.seed(st)
		h.followAccount(st)
	}
	h.applyGate()

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
	if h.paying != nil {
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			_ = h.paying.Run(hctx, h.setPaying)
		}()
	}
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
		Recordings: func() bool {
			on, _, err := st.Recordings()
			if err != nil {
				log.Printf("hub: recording switch unreadable (%s): heartbeat says off", errClass(err))
				return false
			}
			return on
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
	if h.sup != nil && h.sup.o.published != nil {
		h.sup.o.published(kinds)
	}
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
	if h.isUnvouched() {
		return h.vouchReason()
	}
	if h.isPaused() {
		return ReasonNeedsRelay
	}
	if a, ok := h.tr.(relayAdmission); ok && !a.Admitted() {
		return ReasonNotAdmitted
	}
	return ""
}

// observe hands a relay write's error to the gate (HUB_NOT_VOUCHED holds
// the hub) and to the PayingWatch (ENTITLEMENT_INACTIVE re-reads the
// account state).
func (h *hubRuntime) observe(err error) {
	h.noteNotVouched(err)
	if h.paying != nil {
		h.paying.Observe(transport.Event{}, err)
	}
}

// isPaused: the relay-only rules hold the hub paused (no paying phone).
func (h *hubRuntime) isPaused() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.paused
}

// setPaying follows the PayingWatch (spec §7.3): no paying phone pauses the
// publisher and the processor, keeping every queue and the sidecar; a paying
// phone again resumes them with one full diff and one mailbox pass, which
// writes the queued echoes and controls.
func (h *hubRuntime) setPaying(paying bool) {
	h.mu.Lock()
	was := h.paused
	h.paused = !paying
	changed := was != h.paused
	h.mu.Unlock()
	if !changed {
		return
	}
	if paying {
		log.Printf("hub: resumed (a paying phone)")
	} else {
		log.Printf("hub: paused (%s)", ReasonNeedsRelay)
	}
	h.applyGate()
	h.sup.poke()
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
	h.cloudKitStart(ctx)
	passes := time.NewTicker(h.passTickEvery())
	defer passes.Stop()
	links := time.NewTicker(h.sup.o.linkEvery)
	defer links.Stop()
	house := time.NewTicker(houseEvery)
	defer house.Stop()
	soon := &soonWindow{stop: func() {}}
	defer func() { soon.stop() }()
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-h.tr.Events():
			h.onEvent(ctx, ev)
		case <-h.passKick:
			h.pass(ctx)
		case <-passes.C:
			h.passTick(ctx)
		case <-h.linkKick:
			h.linkUpkeep(ctx)
		case <-links.C:
			h.linkUpkeep(ctx)
		case <-h.soonKick:
			soon.until, soon.checked = h.sup.o.Clock().Add(linkSoonFor), false
			if soon.c == nil {
				soon.c, soon.stop = h.sup.o.soonTimer(linkSoonEvery)
			}
		case <-soon.c:
			h.soonTick(ctx, soon)
		case <-h.houseKick:
			h.housekeeping(ctx)
		case <-house.C:
			h.housekeeping(ctx)
		}
	}
}

// onEvent handles one transport event.
func (h *hubRuntime) onEvent(ctx context.Context, ev transport.Event) {
	if h.cloudKitEvent(ctx, ev) {
		return
	}
	h.noteNotVouched(ev.Err)
	if h.paying != nil {
		h.paying.Observe(ev, nil)
	}
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
		case h.isMailbox(ev.Zone):
			h.touch()
			h.pass(ctx)
		}
	}
}

// isMailbox: zone is a phone's mailbox — relay/<relay id>/<phone>, or the
// shared mailbox relay/<relay id>/* every phone has on CloudKit.
func (h *hubRuntime) isMailbox(zone string) bool {
	return strings.HasPrefix(zone, transport.MailboxZone(h.relayID, ""))
}

// onControl handles a server control event.
func (h *hubRuntime) onControl(ctx context.Context, c transport.Control) {
	switch c.Kind {
	case transport.PairingOpened:
		h.pairing(ctx, c.Detail)
	case transport.EntitlementExpired, transport.SlotRemoved, transport.SubscriptionMoved:
		log.Printf("hub: relay control %d: readers synced again", c.Kind)
		h.kick(h.linkKick)
	case transport.SlotAdded:
		h.onSlotAdded()
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
	if h.isHeld() {
		return
	}
	if h.sup.o.onPass != nil {
		h.sup.o.onPass()
	}
	h.lastPass = h.sup.o.Clock()
	defer h.sweepShares(ctx)
	for range 10 {
		pctx, cancel := context.WithTimeout(ctx, opTimeout)
		rep, err := h.proc.Pass(pctx)
		cancel()
		if err != nil {
			h.observe(err)
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
		h.observe(err)
		log.Printf("hub: pair keyboxes not written (%s)", errClass(err))
	}
	vouched := h.vouched()
	if rs, ok := h.tr.(readersSetter); ok && vouched && h.acct != nil {
		// set_hub_readers is closed to an unvouched hub; the account state
		// it is computed from comes through the one door.
		set := func(ctx context.Context, linked []string) error {
			st, err := h.readAccount(ctx)
			if err != nil {
				return fmt.Errorf("hub: readers: account state: %w", err)
			}
			return rs.SetReadersFrom(ctx, st, linked)
		}
		if err := h.center.SyncReaders(ctx, set); err != nil {
			h.noteNotVouched(err)
			log.Printf("hub: readers not synced (%s)", errClass(err))
		}
	}
	if zw, ok := h.tr.(zoneWatcher); ok {
		h.watchZones(ctx, zw)
	}
	if !vouched && h.acct != nil && h.phoneLinked() {
		// A linked phone and no slot: the hub expects one. SLOT_ADDED is
		// best effort, so this backstop polls (at most every unvouchedPoll).
		if _, err := h.readAccount(ctx); err != nil {
			log.Printf("hub: reading the account state failed (%s)", errClass(err))
		}
	}
	h.pass(ctx)
	h.sup.poke()
}

// soonWindow is the link check's short-retry window after a link change
// (worker only): its timer, its end, and the slotted set the last link
// check of the window saw.
type soonWindow struct {
	c       <-chan time.Time
	stop    func()
	until   time.Time
	checked bool   // a link check ran in this window
	slotted string // the slotted set at that check
}

// soonTick is one tick of the short-retry window. Per tick it costs one
// get_account_state; while the hub is unvouched, at most one per
// unvouchedPoll (the relay's limit: accountReader answers the ticks between
// from the last read). The full link check (keyboxes, readers,
// subscriptions, a pass) runs only on the window's first tick and when the slotted set
// changed since the last one, so a phone that is never promoted costs one
// read every linkSoonEvery for linkSoonFor, nothing more. The window ends
// once every linked phone holds the hub in a slot, or at its end; either
// way the PayingWatch re-reads then, so a headless hub paused for want of
// a paying phone resumes as soon as one is there.
func (h *hubRuntime) soonTick(ctx context.Context, w *soonWindow) {
	w.stop()
	w.c, w.stop = nil, func() {}
	settled, slotted, read := h.slotState(ctx)
	if read && (!w.checked || slotted != w.slotted) {
		h.linkUpkeep(ctx)
		w.checked, w.slotted = true, slotted
	}
	if read && settled {
		h.recheckPaying()
		return
	}
	if h.sup.o.Clock().Before(w.until) {
		w.c, w.stop = h.sup.o.soonTimer(linkSoonEvery)
		return
	}
	h.recheckPaying() // the window ran out unsettled: one more read
}

func (h *hubRuntime) recheckPaying() {
	if h.paying != nil {
		h.paying.Recheck()
	}
}

// slotState reads the account state once: settled when every linked phone
// with a relay id holds the hub in a slot, slotted the sorted set of the
// phones that do (a key), read false when it could not be read. A
// transport with no account state has nothing to wait for (settled).
func (h *hubRuntime) slotState(ctx context.Context) (settled bool, slotted string, read bool) {
	if h.acct == nil {
		return true, "", true
	}
	devices, err := h.st.Devices()
	if err != nil {
		return false, "", false
	}
	ctx, cancel := context.WithTimeout(ctx, opTimeout)
	st, err := h.readAccount(ctx) // throttled while unvouched
	cancel()
	if err != nil {
		return false, "", false
	}
	held := map[string]bool{}
	ids := make([]string, 0, len(st.GetPhones()))
	for _, p := range st.GetPhones() {
		held[p.GetPhoneDeviceId()] = true
		ids = append(ids, p.GetPhoneDeviceId())
	}
	sort.Strings(ids)
	settled = true
	for _, d := range devices {
		if d.RelayDeviceID != "" && !held[d.RelayDeviceID] {
			settled = false
		}
	}
	return settled, strings.Join(ids, ","), true
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
// until it succeeds; the hub becoming vouched (SLOT_ADDED, or a poll that
// sees a slot) clears the waits. A subscription that takes means
// the relay is reachable.
func (h *hubRuntime) watchZones(ctx context.Context, zw zoneWatcher) {
	if _, ok := h.tr.(relayAdmission); ok {
		v := h.vouched()
		if v && !h.wasVouched {
			clear(h.subRetry)
		}
		h.wasVouched = v
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
		if r != nil && h.paying != nil {
			// The relay takes a zone it refused: a phone holds the hub in
			// a slot now, and may pay.
			h.paying.Recheck()
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
	if h.mode == policy.MobileWorkbenchOnly && !h.isHeld() {
		// What the switch to workbench_only failed to delete: no source
		// publishes those kinds now, so whatever is left is retried here
		// (not while paused or unvouched: then the hub deletes nothing).
		if left, err := publishedRecords(h.st, workbenchOnly); err != nil {
			log.Printf("hub: reading what was published failed (%s)", errClass(err))
		} else {
			wipe(ctx, h.st, h.tr, h.data, left)
		}
	}
	pruneRecordingJobs(h.sup.o, h.st)
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
	if keep != nil && !h.vouched() {
		// The data zone is closed to an unvouched hub: the records stay in
		// slice_state, so the next start (or the stopped wipe) retries.
		log.Printf("hub: not vouched on the relay: published records not deleted yet")
	} else if keep != nil {
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
