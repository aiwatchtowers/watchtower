package hub

// The running hub on a desktop host (Go hub phase 3 Task 21): both
// transports, the switcher between them (Task 18/20), the CloudKit bridge's
// supervisor (Task 4), and the seams the rest of the runtime reads through
// (relayT, processor, processors, events). Every other hub has one transport
// and one processor, and these answer for it.

import (
	"context"
	"crypto/ed25519"
	"log"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
)

// relayConnector is the hosted relay's Connect (*relay.Transport): a
// desktop host builds the relay unconnected and connects it in the link
// upkeep, retried there while it fails.
type relayConnector interface {
	Connect(ctx context.Context, zones []string) error
}

// hubIdentity is the hub's identity: a desktop host's from its recorded
// store, every other hub's from the hub dir's file.
func (o Options) hubIdentity(st *state.Store) (identity.Identity, error) {
	if o.Desktop != nil {
		return o.desktopIdentity(st)
	}
	return loadIdentity(o.Dir)
}

// hostInfo is what the hub tells phones: a desktop host announces its
// transports (Options.Transports), a headless host the relay alone.
func hostInfo(o Options, name string, authPub ed25519.PublicKey) link.HostInfo {
	h := link.HeadlessHost(name, authPub)
	if o.Desktop != nil {
		h.Transports = desktopTransportList(o)
	}
	return h
}

// desktopTransports builds a desktop host's transports: the relay (when an
// origin is set) unconnected — the link upkeep connects it, so a relay that
// is down never keeps the CloudKit side from starting — and the CloudKit
// bridge client, with the bridge's supervisor when this build has a bridge.
func (h *hubRuntime) desktopTransports(ctx context.Context, o Options) error {
	if o.RelayOrigin != "" {
		rel, err := o.newTransport(ctx, h.id, h.st, nil)
		if err != nil {
			return err
		}
		h.rel = rel
		_, h.relDown = rel.(relayConnector)
	}
	c := cloudkit.Config{Dir: o.Dir, HubID: h.kr.HubID().String(), RelayID: h.relayID, Clock: o.Clock,
		Launch: o.Desktop.launcher(o.Dir)}
	if c.Launch == nil {
		// No bridge: CloudKit is neither run nor offered (relay only).
		log.Printf("hub: this build has no CloudKit bridge: CloudKit is unavailable")
		return nil
	}
	h.bridge = cloudkit.NewSupervisor(c)
	if o.Desktop.newCloudKit != nil {
		h.ck = o.Desktop.newCloudKit(c)
	} else {
		h.ck = cloudkit.New(c)
	}
	return nil
}

// newSwitcher builds the switcher over both transports from the processors'
// template ac; the runtime's transport becomes its Front.
func (h *hubRuntime) newSwitcher(ac actions.Config) error {
	sw, err := switcher.New(h.switcherConfig(ac))
	if err != nil {
		return err
	}
	h.sw, h.tr = sw, sw.Front()
	return nil
}

// switcherConfig is the switcher's config over both transports, with the
// alert pushes' switch hook.
func (h *hubRuntime) switcherConfig(ac actions.Config) switcher.Config {
	c := switcher.Config{
		Store: h.st, Keys: h.kr, CloudKit: h.ck, Relay: h.rel, Actions: ac, KeyboxesAll: h.center.KeyboxesAll,
		Clock: h.sup.o.Clock, OnSwitched: h.switchedTo,
	}
	if h.acct != nil {
		c.Paying = h.payingByDevice
		c.AccountPhones = func(ctx context.Context) ([]switcher.AccountPhone, error) {
			acct, err := h.followed(h.acct.Fresh(ctx))
			if err != nil {
				return nil, err
			}
			out := make([]switcher.AccountPhone, 0, len(acct.GetPhones()))
			for _, p := range acct.GetPhones() {
				out = append(out, switcher.AccountPhone{RelayDeviceID: p.GetPhoneDeviceId(), Paying: p.GetPaying()})
			}
			return out, nil
		}
		c.AnyPaying = func(ctx context.Context) (bool, error) {
			acct, err := h.followed(h.acct.Fresh(ctx))
			if err != nil {
				return false, err
			}
			return paying(acct), nil
		}
	}
	return c
}

// payingByDevice is the switcher's Paying: which linked phones the relay's
// account state lists as paying, by device id.
func (h *hubRuntime) payingByDevice(ctx context.Context) (map[string]bool, error) {
	acct, err := h.readAccount(ctx)
	if err != nil {
		return nil, err
	}
	devices, err := h.st.Devices()
	if err != nil {
		return nil, err
	}
	byRelay := map[string]string{}
	for _, d := range devices {
		if d.RelayDeviceID != "" {
			byRelay[d.RelayDeviceID] = d.ID
		}
	}
	out := map[string]bool{}
	for _, p := range acct.GetPhones() {
		if id, ok := byRelay[p.GetPhoneDeviceId()]; ok {
			out[id] = p.GetPaying()
		}
	}
	return out, nil
}

// relayT is the hosted relay's transport: the one transport elsewhere, the
// relay of a desktop host (nil without a relay origin).
func (h *hubRuntime) relayT() transport.Transport {
	if h.sup.o.Desktop != nil {
		return h.rel // also before the switcher exists
	}
	return h.tr
}

// relayVouched is the relay's vouch state (true on a transport without the
// notion, or with no relay).
func (h *hubRuntime) relayVouched() bool {
	if a, ok := h.relayT().(relayAdmission); ok {
		return a.Vouched()
	}
	return true
}

// processor is the processor the runtime's passes and late echoes go to:
// the active transport's on a desktop host.
func (h *hubRuntime) processor() *actions.Processor {
	if h.sw != nil {
		return h.sw.ActiveProcessor()
	}
	return h.proc
}

// processors is every processor (both transports' on a desktop host).
func (h *hubRuntime) processors() []*actions.Processor {
	if h.sw == nil {
		return []*actions.Processor{h.proc}
	}
	var out []*actions.Processor
	for _, k := range []transport.Kind{transport.KindCloudKit, transport.KindRelay} {
		if p := h.sw.Processor(k); p != nil {
			out = append(out, p)
		}
	}
	return out
}

// events are the transports' event channels (the second nil on a hub with
// one transport; a nil channel never delivers).
func (h *hubRuntime) events() (a, b <-chan transport.Event) {
	if h.sw == nil {
		return h.tr.Events(), nil
	}
	if h.ck != nil {
		a = h.ck.Events()
	}
	if h.rel != nil {
		b = h.rel.Events()
	}
	return a, b
}

// closeTransports closes every transport the hub built.
func (h *hubRuntime) closeTransports() {
	if h.sw == nil && h.rel == nil && h.ck == nil {
		if h.tr != nil {
			closeTransport(h.tr)
		}
		return
	}
	for _, t := range []transport.Transport{h.rel, h.ck} {
		if t != nil {
			closeTransport(t)
		}
	}
}

// connectRelay connects a desktop host's relay while it is not connected
// yet (worker only); a failure is logged once and retried by the next link
// upkeep, and CloudKit runs meanwhile.
func (h *hubRuntime) connectRelay(ctx context.Context) {
	if !h.relDown {
		return
	}
	c, ok := h.rel.(relayConnector)
	if !ok {
		h.relDown = false
		return
	}
	cctx, cancel := context.WithTimeout(ctx, switcher.OldSideTimeout)
	defer cancel()
	if err := c.Connect(cctx, nil); err != nil {
		log.Printf("hub: the relay is not connected (%s): retried", errClass(err))
		return
	}
	h.relDown = false
	if a, ok := h.rel.(relayAdmission); ok && h.acct != nil {
		st := a.LastAccountState()
		h.acct.seed(st)
		h.followAccount(st)
	}
}

// startDesktop starts a desktop host's own goroutines: the bridge's
// supervisor under a context of its own (stop ends it after the policy
// wipe, which may still need the bridge) and the switcher under the hub's.
func (h *hubRuntime) startDesktop(ctx context.Context) {
	if h.bridge != nil {
		h.bridgeStop = runBridge(h.bridge)
	}
	if h.sw != nil {
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			_ = h.sw.Run(ctx)
		}()
	}
}

// runBridge runs sup until the returned stop, which ends it (the bridge
// process goes with it) and waits.
func runBridge(sup *cloudkit.Supervisor) (stop func()) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = sup.Run(ctx)
	}()
	return func() {
		cancel()
		<-done
	}
}

// stopBridge stops the bridge (a no-op without one).
func (h *hubRuntime) stopBridge() {
	if h.bridgeStop != nil {
		h.bridgeStop()
		h.bridgeStop = nil
	}
}

// usedOthers are the transports besides the active one the hub may have
// published on: a desktop host's other transport once a switch ever moved
// it (hub_meta.switched_at). Their deletes are best effort.
func (h *hubRuntime) usedOthers() []transport.Transport {
	if h.sw == nil {
		return nil
	}
	if _, ok, err := h.st.Meta(switcher.MetaSwitchedAt); err != nil || !ok {
		return nil
	}
	other := h.rel
	if h.tr.Kind() == transport.KindRelay {
		other = h.ck
	}
	if other == nil {
		return nil
	}
	return []transport.Transport{other}
}

// wipeOthers deletes recs from zone on each of trs, best effort: the
// sidecar forgets a record only by the active transport's answer (wipe).
func wipeOthers(ctx context.Context, trs []transport.Transport, zone string, recs []published) {
	if len(recs) == 0 {
		return
	}
	items := make([]transport.DeleteItem, len(recs))
	for i, r := range recs {
		items[i] = transport.DeleteItem{Name: r.wire}
	}
	for _, t := range trs {
		if _, err := t.Delete(ctx, zone, items); err != nil {
			log.Printf("hub: deleting %d published records on the %s failed (%s)", len(recs), t.Kind(), errClass(err))
		}
	}
}

// bridgeUpWait bounds the wait for a bridge started only for the policy
// wipe of a stopped hub.
const bridgeUpWait = 10 * time.Second

// wipeStoppedDesktop is a stopped desktop host's policy wipe: the identity
// from its recorded store (never created), the active transport by
// hub_meta.transport — CloudKit through a bridge started for the wipe and
// stopped after it — and the other one best effort once a switch moved the
// hub. false: nothing could be tried (retried later).
func (s *supervisor) wipeStoppedDesktop(ctx context.Context, published []published) bool {
	o, d := s.o, s.o.Desktop
	store, err := d.store(s.st, o.Dir)
	if err != nil {
		log.Printf("hub: policy off: wipe skipped (%s)", errClass(err))
		return false
	}
	id, err := store.Load()
	if err != nil {
		log.Printf("hub: policy off: wipe skipped (%s)", errClass(err))
		return false
	}
	defer id.Zero()
	hubID, _, err := s.st.Meta(state.MetaHubID)
	if err != nil {
		log.Printf("hub: policy off: wipe skipped (%s)", errClass(err))
		return false
	}
	relayID := identity.RelayDeviceID(id.RelayAuth.Public().(ed25519.PublicKey))
	var ck, rel transport.Transport
	if launch := d.launcher(o.Dir); launch != nil {
		c := cloudkit.Config{Dir: o.Dir, HubID: hubID, RelayID: relayID, Clock: o.Clock, Launch: launch}
		sup := cloudkit.NewSupervisor(c)
		stop := runBridge(sup)
		defer stop()
		deadline := time.Now().Add(bridgeUpWait)
		for !sup.Running() && time.Now().Before(deadline) && ctx.Err() == nil {
			time.Sleep(50 * time.Millisecond)
		}
		if d.newCloudKit != nil {
			ck = d.newCloudKit(c)
		} else {
			ck = cloudkit.New(c)
		}
		defer closeTransport(ck)
	}
	if o.RelayOrigin != "" {
		if rel, err = o.newTransport(ctx, id, s.st, nil); err != nil {
			log.Printf("hub: policy off: no relay for the wipe (%s)", startFailure(err))
			rel = nil
		} else {
			defer closeTransport(rel)
		}
	}
	active, other := ck, rel
	if v, _, _ := s.st.Meta(switcher.MetaTransport); v == string(transport.KindRelay) || ck == nil {
		active, other = rel, ck
	}
	if active == nil {
		log.Printf("hub: policy off: wipe deferred (no transport)")
		return false
	}
	zone := transport.DataZone(relayID)
	if _, ok, _ := s.st.Meta(switcher.MetaSwitchedAt); ok && other != nil {
		wipeOthers(ctx, []transport.Transport{other}, zone, published)
	}
	wipe(ctx, s.st, active, zone, published)
	return true
}

// bridgeState is the status' bridge: "" off a desktop host.
func (h *hubRuntime) bridgeState() string {
	switch {
	case h.sup.o.Desktop == nil:
		return ""
	case h.bridge == nil:
		return BridgeUnavailable
	case h.bridge.Running():
		return BridgeRunning
	}
	return BridgeRestarting
}
