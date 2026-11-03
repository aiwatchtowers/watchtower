package hub

// The relay indicators of `hub status` (Go hub plan 4 Task 7, RC §10): the
// relay connection's health, the hub's quota flag, the last data-zone save,
// the push-off line, the paying phones and the per-phone mailbox flags. Ids,
// classes and timestamps only.

import (
	"encoding/json"
	"errors"
	"log"
	"slices"
	"strings"
	"sync"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// AlertOutcomeWindow is how far back the alert outcomes count (the push-off
// line, `hub phones`' alerts): the ledger's 7-day prune.
const AlertOutcomeWindow = 7 * 24 * time.Hour

// relayUnavailableAfter is how long the relay may be without a connection
// before it shows as unavailable (RC §9's phone threshold, reused).
const relayUnavailableAfter = 60 * time.Second

// RelayHealth.State values.
const (
	RelayConnected   = "connected"
	RelayConnecting  = "connecting"
	RelayUnavailable = "unavailable"
)

// saveObserver is the hosted relay's save observer (*relay.Transport).
type saveObserver interface {
	ObserveSaves(f func(zone string, err error))
}

// connectedReporter is the hosted relay's live connection state
// (*relay.Transport); a transport without it (memfake) is connected unless
// the runtime saw it unreachable.
type connectedReporter interface {
	Connected() bool
}

// accountKnower is the hosted relay's last account state and whether one is
// known (*relay.Transport); a transport without it knows no paying phones.
type accountKnower interface {
	KnownAccountState() (*relayv1.AccountState, bool)
}

// relayHealth follows the relay's saves and connection for the status. Its
// mailbox flags (device ids) live in hub_meta too, so they survive a restart.
type relayHealth struct {
	st      *state.Store
	clock   func() time.Time
	data    string // the hub's data zone
	mailbox string // the prefix of the hub's mailbox zones (relay/<hub>/)

	mu          sync.Mutex
	state       string
	since       time.Time
	downSince   time.Time
	quotaHub    bool
	lastSaved   time.Time
	mailboxFull map[string]bool // device ids
	// pushOffErr is the class of the last failed push-off read ("" = it
	// read), so a failing read is logged once per class.
	pushOffErr string
}

// newRelayHealth is the health of the relay rt (nil: none, nil returned) of
// the hub with relay device id hubRelayID; it restores the mailbox flags and
// observes rt's saves.
func newRelayHealth(st *state.Store, clock func() time.Time, hubRelayID string, rt transport.Transport) *relayHealth {
	if rt == nil || rt.Kind() != transport.KindRelay {
		return nil
	}
	r := &relayHealth{
		st: st, clock: clock, data: transport.DataZone(hubRelayID), mailbox: transport.MailboxZone(hubRelayID, ""),
		mailboxFull: map[string]bool{},
	}
	raw, ok, err := st.Meta(state.MetaMailboxFullPhones)
	var ids []string
	if err == nil && ok {
		err = json.Unmarshal([]byte(raw), &ids)
	}
	if err != nil {
		log.Printf("hub: the mailbox quota flags are unreadable (%s): none restored", errClass(err))
	}
	for _, id := range ids {
		r.mailboxFull[id] = true
	}
	if o, ok := rt.(saveObserver); ok {
		o.ObserveSaves(r.saved)
	}
	return r
}

// saved follows one save's result in zone: a data-zone save sets the hub's
// quota flag when refused as over quota and clears it (and stamps the last
// save) when it succeeds; a phone's mailbox the same for that phone's flag.
// Other errors change nothing.
func (r *relayHealth) saved(zone string, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	switch {
	case zone == r.data && err == nil:
		r.quotaHub, r.lastSaved = false, r.clock()
	case zone == r.data:
		if errors.Is(err, transport.ErrHubQuota) {
			r.quotaHub = true
		}
	case strings.HasPrefix(zone, r.mailbox):
		full := errors.Is(err, transport.ErrMailboxQuota)
		if (err != nil && !full) || (err == nil && len(r.mailboxFull) == 0) {
			return
		}
		id, ok := r.deviceOf(strings.TrimPrefix(zone, r.mailbox))
		if !ok || r.mailboxFull[id] == full {
			return
		}
		if full {
			r.mailboxFull[id] = true
		} else {
			delete(r.mailboxFull, id)
		}
		r.persist()
	}
}

// deviceOf is the linked phone with relay device id phone.
func (r *relayHealth) deviceOf(phone string) (string, bool) {
	devices, err := r.st.Devices()
	if err != nil {
		log.Printf("hub: reading the linked phones failed (%s): mailbox flag unchanged", errClass(err))
		return "", false
	}
	for _, d := range devices {
		if d.RelayDeviceID == phone {
			return d.ID, true
		}
	}
	return "", false
}

// persist writes the mailbox flags to hub_meta (r.mu held).
func (r *relayHealth) persist() {
	b, err := json.Marshal(r.fullList())
	if err == nil {
		err = r.st.SetMeta(state.MetaMailboxFullPhones, string(b))
	}
	if err != nil {
		log.Printf("hub: saving the mailbox quota flags failed (%s)", errClass(err))
	}
}

// fullList is the flagged device ids, sorted (r.mu held).
func (r *relayHealth) fullList() []string {
	out := make([]string, 0, len(r.mailboxFull))
	for id := range r.mailboxFull {
		out = append(out, id)
	}
	slices.Sort(out)
	return out
}

// follow moves the connection state on: connected at once; without a
// connection connecting, and unavailable relayUnavailableAfter after the
// connection was last seen gone.
func (r *relayHealth) follow(connected bool, now time.Time) {
	switch {
	case connected:
		if r.state != RelayConnected {
			r.state, r.since = RelayConnected, now
		}
	case r.state == "" || r.state == RelayConnected:
		r.state, r.since, r.downSince = RelayConnecting, now, now
	case r.state == RelayConnecting && now.Sub(r.downSince) >= relayUnavailableAfter:
		r.state, r.since = RelayUnavailable, r.downSince.Add(relayUnavailableAfter)
	}
}

// facts is the health as the status shows it, after following connected,
// and the mailbox flags of the phones still linked (devices): an unlinked
// phone's flag goes, from hub_meta too.
func (r *relayHealth) facts(connected bool, devices []state.Device) (RelayHealth, []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.follow(connected, r.clock())
	linked := map[string]bool{}
	for _, d := range devices {
		linked[d.ID] = true
	}
	dropped := false
	for id := range r.mailboxFull {
		if !linked[id] {
			delete(r.mailboxFull, id)
			dropped = true
		}
	}
	if dropped {
		r.persist()
	}
	// The last save is shown to the minute ("delivered <age> ago"), so the
	// status changes at most once a minute from it, not on every save.
	return RelayHealth{
		State: r.state, Since: rfc3339(r.since), QuotaHub: r.quotaHub, LastSavedAt: rfc3339(r.lastSaved.Truncate(time.Minute)),
	}, r.fullList()
}

// pushOff reads the push-off line from the ledger; a failed read reads as
// not off and is logged once per error class.
func (r *relayHealth) pushOff() bool {
	off, err := r.st.PushOff(r.clock().Add(-AlertOutcomeWindow))
	class := ""
	if err != nil {
		class = errClass(err)
	}
	r.mu.Lock()
	changed := class != r.pushOffErr
	r.pushOffErr = class
	r.mu.Unlock()
	if changed && class != "" {
		log.Printf("hub: reading the push-off line failed (%s)", class)
	}
	return off
}

// rfc3339 is t in RFC 3339 UTC, "" for the zero time.
func rfc3339(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

// payingPhones is the linked phones (device ids, sorted) the account state
// lists as paying while the active transport is the relay, none elsewhere,
// and nil (unknown: the status shows null) on the relay while no account
// state is known — before the first read, after HUB_NOT_VOUCHED.
func payingPhones(active transport.Kind, acct *relayv1.AccountState, known bool, devices []state.Device) []string {
	out := []string{}
	if active != transport.KindRelay {
		return out
	}
	if !known {
		return nil
	}
	paying := map[string]bool{}
	for _, p := range acct.GetPhones() {
		if p.GetPaying() {
			paying[p.GetPhoneDeviceId()] = true
		}
	}
	for _, d := range devices {
		if d.RelayDeviceID != "" && paying[d.RelayDeviceID] {
			out = append(out, d.ID)
		}
	}
	slices.Sort(out)
	return out
}

// relayFacts is the running hub's relay indicators for the status: the
// relay's health (nil without a relay), the paying phones (nil: unknown) and
// the phones whose mailbox is full.
func (h *hubRuntime) relayFacts(devices []state.Device) (*RelayHealth, []string, []string) {
	rt := h.relayT()
	if h.health == nil || rt == nil {
		return nil, []string{}, []string{}
	}
	var connected bool
	if c, ok := rt.(connectedReporter); ok {
		connected = c.Connected()
	} else {
		h.mu.Lock()
		connected = !h.unreachable
		h.mu.Unlock()
	}
	health, full := h.health.facts(connected, devices)
	health.PushOff = h.health.pushOff()
	var (
		acct  *relayv1.AccountState
		known bool
	)
	if a, ok := rt.(accountKnower); ok {
		acct, known = a.KnownAccountState()
	}
	return &health, payingPhones(h.tr.Kind(), acct, known, devices), full
}
