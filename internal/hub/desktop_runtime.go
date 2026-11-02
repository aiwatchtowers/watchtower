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
	if len(o.Transports) > 0 {
		h.Transports = append([]string(nil), o.Transports...)
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
	c := cloudkit.Config{Dir: o.Dir, HubID: h.kr.HubID().String(), RelayID: h.relayID, Clock: o.Clock}
	switch d := o.Desktop; {
	case d.launch != nil:
		c.Launch = d.launch
	case d.Bridge != "":
		c.Launch = bridgeLauncher(d.Bridge, o.Dir)
	}
	if c.Launch != nil {
		h.bridge = cloudkit.NewSupervisor(c)
	} else {
		log.Printf("hub: this build has no CloudKit bridge: CloudKit is unavailable")
	}
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
	c := switcher.Config{
		Store: h.st, Keys: h.kr, CloudKit: h.ck, Relay: h.rel, Actions: ac, Keyboxes: h.center.Keyboxes,
		Clock: h.sup.o.Clock,
	}
	if h.acct != nil {
		c.Paying = h.payingByDevice
	}
	sw, err := switcher.New(c)
	if err != nil {
		return err
	}
	h.sw, h.tr = sw, sw.Front()
	return nil
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
	if h.sw != nil {
		return h.rel
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

// startDesktop starts a desktop host's own goroutines under the hub's
// context: the bridge's supervisor and the switcher.
func (h *hubRuntime) startDesktop(ctx context.Context) {
	if h.bridge != nil {
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			_ = h.bridge.Run(ctx)
		}()
	}
	if h.sw != nil {
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			_ = h.sw.Run(ctx)
		}()
	}
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
