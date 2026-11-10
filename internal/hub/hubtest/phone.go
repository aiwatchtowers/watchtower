// Package hubtest is the Go phone emulator the hub's tests drive (the relay
// sim's Phone, on real envelopes): it holds a linked phone's keys, derives
// the pairwise relay keys, seals relayToHub actions carrying action_seq into
// its mailbox (on a memfake transport, or on the hosted relay through
// RelayStore), keeps them in an outbox until a final echo, opens the hub's
// echoes and controls, answers resend_from (rewriting each requeued action's
// same bytes as a new version under the last record_seq it knows at that
// name, as the Swift phone does, or skip_to when it no longer has an action) and deletes
// what it read.
// Test-only: never imported by production code.
package hubtest

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
)

// Records is the record store a phone writes its own sealed bytes into and
// reads the hub's from: the memfake, or the hosted relay (RelayStore).
type Records interface {
	Write(zone, name string, env []byte, expect transport.Expect) (transport.Outcome, error)
	WriteWithAsset(zone, name string, env, asset []byte, expect transport.Expect) (transport.Outcome, error)
	Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error)
	Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error)
}

var _ Records = (*memfake.Fake)(nil)

// Config is what a linked phone knows about its hub (the keybox and the link
// code): its id, agreement key, K_meta and current epoch, plus the hub's relay
// device id (the mailbox's first half), the shared record store and a clock.
type Config struct {
	Hub        secure.ID
	HubKX      *ecdh.PublicKey
	HubSig     ed25519.PublicKey // checks the hub's keyboxes (ReadKeybox needs it)
	MetaKey    []byte
	Epoch      uint32
	HubRelayID string
	Transport  Records
	Clock      func() time.Time
	// Mailbox, when set, is the phone's mailbox zone instead of
	// relay/<HubRelayID>/<its relay id>: transport.SharedMailboxZone for a
	// phone on CloudKit's one RelayZone, which every phone of the hub shares
	// (the phone skips the records it cannot open, so it never deletes or
	// answers another phone's).
	Mailbox string
	// Key, when set, is the phone's Ed25519 device key instead of a fresh
	// one: a stable device id and relay_device_id across runs (the staging
	// measurement, whose phone must stay on the relay's attestation-exempt
	// list).
	Key ed25519.PrivateKey
}

type sent struct {
	plain, wire string
	env         []byte
	frame       secure.InnerFrame // what env seals, resealed in a newer epoch on a resend_from (sim rule 14)
	epoch       uint32            // the epoch env is sealed in
	recordSeq   uint64            // last RecordSeq the phone knows at this action's name (its write or the hub's echo); 0 = never written
}

// Phone is one emulated phone. Not safe for concurrent use.
type Phone struct {
	cfg     Config
	sig     ed25519.PrivateKey
	kx      *ecdh.PrivateKey
	id      secure.ID
	nonce   []byte
	relayID string
	zone    string

	envSeq     uint64
	nextAction uint64
	history    map[uint64]sent // every action ever sealed, by action_seq
	outbox     []uint64        // sealed, not yet answered with a final echo
	cursor     uint64

	legacy map[string]sent // legacy (unordered) actions by id

	// Echoes is the last echo status seen per action_seq.
	Echoes map[uint64]wire.ActionRequest
	// LegacyEchoes is the last echo seen per legacy action id.
	LegacyEchoes map[string]wire.ActionRequest
	// UploadEchoes is the last recording_upload echo read per upload id.
	UploadEchoes map[string]map[string]any
	// Controls is every hub control read, in order; ControlEpochs the
	// epoch each one's envelope was sealed in.
	Controls      []wire.Control
	ControlEpochs []uint32
	// RefusedForGood names the actions the transport refuses for good on their
	// next write: a resend lists each and skips past them after the rows, the
	// order the Swift phone's flush writes them in.
	RefusedForGood map[uint64]bool
	// Undelivered lists the actions a skip_to gave up on.
	Undelivered []uint64
	// Resealed lists the outbox actions sealed again in a newer epoch on a
	// resend_from (sim rule 14), in order.
	Resealed []uint64
	// Read is every hub record Sync handled, in order: "echo:<seq>:<status>"
	// or "control:<kind>".
	Read []string
	// Creator, when set, is the iCloud user WriteDeviceRecord writes as
	// (Stored.Creator, on a transport with WriteAs such as the memfake).
	Creator string

	// EchoEpochs is the epoch each action's last echo read was sealed in.
	EchoEpochs map[uint64]uint32
	// Dropped names every hub record Sync read and could not open in an
	// epoch at or below the one the phone seals in (the Kit's
	// epochKeysGone: those keys never come, so the record is dropped).
	// With RequeueOnDrop each batch that dropped one writes the whole
	// outbox again once, in order (the Kit's requeueUnechoedAfterDrop).
	Dropped       []string
	RequeueOnDrop bool
	// Guard, when set, is the Kit's rollback guard on hub records
	// (RollbackGuard.swift): per wire name the newest (epoch, seq) opened,
	// epoch first; an older version is dropped unhandled and listed in
	// RolledBack.
	Guard      bool
	RolledBack []string
	seen       map[string][2]uint64

	// dataKeys is K_data per epoch the phone was given (Keep, Follow:
	// switch.go), alertKeys K_alert the same way (the alert material a
	// locked phone's notification extension holds); cursors is the mailbox
	// cursor per record store left (Use).
	dataKeys  map[uint32][]byte
	alertKeys map[uint32][]byte
	cursors   map[storeZone]uint64

	// The Kit's ephemeral relay state (relay client Phase 5, ephemeral.go):
	// current and offered are the two dev_eph private keys, pairs the
	// wt/relay/v2/ keys of each epoch a keybox named relay_kx for.
	current, offered *ecdh.PrivateKey
	pairs            map[uint32]map[secure.Direction][]byte
	// pairPubs is each held pair's publics (hub_pub, device_pub); cleared
	// the epochs a static keybox dropped a pair of (or marked static on a
	// link with ephemeral state), with the dropped publics (nil when none
	// was held): the Kit's relayKeysCleared.
	pairPubs map[uint32]relayPubs
	cleared  map[uint32]relayPubs
}

// relayPubs is one epoch's ephemeral publics, hub's and device's.
type relayPubs struct{ hub, device []byte }

// New makes a phone with fresh keys.
func New(cfg Config) (*Phone, error) {
	if cfg.Clock == nil {
		cfg.Clock = time.Now
	}
	pub, sig, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	if cfg.Key != nil {
		sig = cfg.Key
		pub = sig.Public().(ed25519.PublicKey)
	}
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	relayID := identity.RelayDeviceID(pub)
	zone := cfg.Mailbox
	if zone == "" {
		zone = transport.MailboxZone(cfg.HubRelayID, relayID)
	}
	return &Phone{
		cfg: cfg, sig: sig, kx: kx, id: secure.DeviceID(pub), nonce: nonce, relayID: relayID,
		zone:       zone,
		nextAction: 1, history: map[uint64]sent{}, Echoes: map[uint64]wire.ActionRequest{},
		legacy: map[string]sent{}, LegacyEchoes: map[string]wire.ActionRequest{},
	}, nil
}

// Relink is the phone linked again (same device keys, a new link nonce): its
// action_seq restarts at 1 and its outbox and history are gone. The caller
// writes the new Device() row as the hub's link step would.
func (p *Phone) Relink() error {
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	p.nonce, p.nextAction, p.outbox, p.history = nonce, 1, nil, map[uint64]sent{}
	p.Echoes = map[uint64]wire.ActionRequest{}
	return nil
}

// ID is the phone's device id.
func (p *Phone) ID() secure.ID { return p.id }

// RelayAuth is the key the phone signs in to the hosted relay with: its
// signing key, whose relay_device_id the hello names.
func (p *Phone) RelayAuth() ed25519.PrivateKey { return p.sig }

// RelayDeviceID is the phone's relay_device_id.
func (p *Phone) RelayDeviceID() string { return p.relayID }

// Zone is the phone's mailbox zone.
func (p *Phone) Zone() string { return p.zone }

// Device is the phone's linked devices row.
func (p *Phone) Device() state.Device {
	return state.Device{
		ID: p.id.String(), Name: "Test Phone", Scope: "private", LinkedAt: p.cfg.Clock(),
		SigningKey: p.sig.Public().(ed25519.PublicKey), AgreementKey: p.kx.PublicKey().Bytes(),
		LinkNonce: base64.RawURLEncoding.EncodeToString(p.nonce), StartSessionsAllowed: true,
		RelayDeviceID: p.relayID, // ordered stays false until the hub reads an action_seq
	}
}

// NewAction is a pending action of kind from this phone to its hub, dated
// now; Queue draws its action_seq.
func (p *Phone) NewAction(kind string) wire.ActionRequest {
	device, hub := p.id.String(), p.cfg.Hub.String()
	return wire.ActionRequest{
		ID: newUUID(), Kind: kind, Params: map[string]json.RawMessage{}, CreatedAt: wire.Time{Time: p.cfg.Clock()},
		Status: wire.StatusPending, DeviceID: &device, HubID: &hub,
	}
}

// Queue seals a into the outbox with the next action_seq, without writing it.
func (p *Phone) Queue(a wire.ActionRequest) (uint64, error) {
	seq := p.nextAction
	a.ActionSeq = &seq
	payload, err := wire.Marshal(a)
	if err != nil {
		return 0, err
	}
	plain := "a-" + p.id.String() + "-" + strconv.FormatUint(seq, 10)
	name := secure.RecordName(p.cfg.MetaKey, secure.ZoneRelay, "a", p.id.String()+"-"+strconv.FormatUint(seq, 10))
	frame := secure.InnerFrame{Kind: "action", ID: plain, Payload: payload}
	env, err := p.seal(name, frame)
	if err != nil {
		return 0, err
	}
	p.nextAction++
	p.history[seq] = sent{plain: plain, wire: name, env: env, frame: frame, epoch: p.cfg.Epoch}
	p.outbox = append(p.outbox, seq)
	return seq, nil
}

// Act queues an action of kind and writes it.
func (p *Phone) Act(kind string) (uint64, error) {
	seq, err := p.Queue(p.NewAction(kind))
	if err != nil {
		return 0, err
	}
	return seq, p.Send(seq)
}

// Send writes action seq's sealed bytes: the first write expects the name
// absent, a later one (a resend_from answer) writes the same bytes as a new
// version under the last record_seq the phone knows at that name — its own
// write, or the held/received echo it read over it — the Swift phone's rule. Sim rule 3 on a conflict: an echo at that name means delivered, the
// same bytes mean already there, anything else is overwritten.
func (p *Phone) Send(seq uint64) error {
	s, ok := p.history[seq]
	if !ok {
		return fmt.Errorf("hubtest: no action %d", seq)
	}
	exp := transport.Expect{Mode: transport.ExpectAbsent}
	if s.recordSeq != 0 {
		exp = transport.Expect{Mode: transport.ExpectSeq, Seq: s.recordSeq}
	}
	out, err := p.cfg.Transport.Write(p.zone, s.wire, s.env, exp)
	if err != nil {
		return err
	}
	if out.Saved {
		p.wrote(seq, out.RecordSeq)
		return nil
	}
	if out.Conflict == nil {
		return nil
	}
	cur := out.Conflict
	if bytes.Equal(cur.Envelope, s.env) {
		p.wrote(seq, cur.RecordSeq)
		return nil
	}
	if f, err := p.open(cur.Name, cur.Envelope); err == nil && f.Kind == "action" {
		return p.onEcho(*cur, f)
	}
	out, err = p.cfg.Transport.Write(p.zone, s.wire, s.env, transport.Expect{Mode: transport.ExpectSeq, Seq: cur.RecordSeq})
	if err == nil && out.Saved {
		p.wrote(seq, out.RecordSeq)
	}
	return err
}

// wrote remembers the last record_seq the phone knows at action seq's name.
func (p *Phone) wrote(seq, recordSeq uint64) {
	if s, ok := p.history[seq]; ok {
		s.recordSeq = recordSeq
		p.history[seq] = s
	}
}

// Forget drops action seq from the outbox and its history (a reinstall).
func (p *Phone) Forget(seq uint64) {
	p.outbox = slices.DeleteFunc(p.outbox, func(s uint64) bool { return s == seq })
	delete(p.history, seq)
}

// Outbox is the actions waiting for a final echo, in order.
func (p *Phone) Outbox() []uint64 { return slices.Clone(p.outbox) }

// WriteCopy writes a copy of action seq's original bytes over whatever
// holds its name (a stale copy coming back, or a plain redelivery).
func (p *Phone) WriteCopy(seq uint64) error {
	s, ok := p.history[seq]
	if !ok {
		return fmt.Errorf("hubtest: no action %d", seq)
	}
	_, err := p.cfg.Transport.Write(p.zone, s.wire, s.env, transport.Expect{Mode: transport.ExpectNone})
	return err
}

// Sealed is action seq's wire name and sealed bytes.
func (p *Phone) Sealed(seq uint64) (wireName string, env []byte) {
	s := p.history[seq]
	return s.wire, bytes.Clone(s.env)
}

// SkipTo writes a skip_to(m) control.
func (p *Phone) SkipTo(m uint64) error {
	_, err := p.WriteControl(wire.Control{Kind: wire.ControlSkipTo, Seq: &m})
	return err
}

// WriteControl writes c as a phone control record c-<id>: an empty ID gets a
// new one, nil DeviceID and HubID name this phone and its hub. It returns the
// id (writing the same id again is a second copy of that control).
func (p *Phone) WriteControl(c wire.Control) (string, error) {
	if c.ID == "" {
		c.ID = newUUID()
	}
	device, hub := p.id.String(), p.cfg.Hub.String()
	if c.DeviceID == nil {
		c.DeviceID = &device
	}
	if c.HubID == nil {
		c.HubID = &hub
	}
	payload, err := wire.Marshal(c)
	if err != nil {
		return "", err
	}
	_, err = p.WriteFrame("control", "c-"+c.ID, payload)
	return c.ID, err
}

// ControlWireName is the wire name of control c-<id>.
func (p *Phone) ControlWireName(id string) string {
	return secure.RecordName(p.cfg.MetaKey, secure.ZoneRelay, "c", id)
}

// WriteFrame seals any frame (kind, plain id <prefix>-<rest>, payload) into
// the mailbox under the id's wire name, if nothing holds that name.
func (p *Phone) WriteFrame(kind, id string, payload []byte) (string, error) {
	prefix, rest, _ := strings.Cut(id, "-")
	name := secure.RecordName(p.cfg.MetaKey, secure.ZoneRelay, prefix, rest)
	env, err := p.seal(name, secure.InnerFrame{Kind: kind, ID: id, Payload: payload})
	if err != nil {
		return "", err
	}
	_, err = p.cfg.Transport.Write(p.zone, name, env, transport.Expect{Mode: transport.ExpectAbsent})
	return name, err
}

// WriteDeviceRecord seals d as a device record (the Kit's
// RelayRecordKind.device) with plain id — "" is this phone's own
// device-<id> — over whatever holds its name, as the phone rewrites it.
func (p *Phone) WriteDeviceRecord(d wire.DevicePayload, id string) (string, error) {
	if id == "" {
		id = "device-" + p.id.String()
	}
	payload, err := wire.Marshal(d)
	if err != nil {
		return "", err
	}
	prefix, rest, _ := strings.Cut(id, "-")
	name := secure.RecordName(p.cfg.MetaKey, secure.ZoneRelay, prefix, rest)
	env, err := p.seal(name, secure.InnerFrame{Kind: "device", ID: id, Payload: payload})
	if err != nil {
		return "", err
	}
	if as, ok := p.cfg.Transport.(interface {
		WriteAs(creator, zone, name string, env []byte, expect transport.Expect) (transport.Outcome, error)
	}); ok && p.Creator != "" {
		_, err = as.WriteAs(p.Creator, p.zone, name, env, transport.Expect{Mode: transport.ExpectNone})
		return name, err
	}
	_, err = p.cfg.Transport.Write(p.zone, name, env, transport.Expect{Mode: transport.ExpectNone})
	return name, err
}

// WriteForgedDeviceRecord writes d as a device record naming sender in its
// envelope header, sealed with this phone's own key material: what a device
// holding someone else's id but not its keys could write.
func (p *Phone) WriteForgedDeviceRecord(d wire.DevicePayload, sender secure.ID) (string, error) {
	payload, err := wire.Marshal(d)
	if err != nil {
		return "", err
	}
	id := "device-" + sender.String()
	prefix, rest, _ := strings.Cut(id, "-")
	name := secure.RecordName(p.cfg.MetaKey, secure.ZoneRelay, prefix, rest)
	key, err := secure.RelayKey(p.kx, p.cfg.HubKX, p.nonce, p.cfg.Hub, sender, p.cfg.Epoch, secure.PhoneToHub)
	if err != nil {
		return "", err
	}
	defer clear(key)
	p.envSeq++
	env, err := secure.SealSymmetric(secure.InnerFrame{Kind: "device", ID: id, Payload: payload}, secure.ClassRelayToHub, key,
		p.cfg.Hub, sender, p.cfg.Epoch, p.envSeq, secure.Context{Zone: secure.ZoneRelay, WireName: name}, nil, nil)
	if err != nil {
		return "", err
	}
	_, err = p.cfg.Transport.Write(p.zone, name, env, transport.Expect{Mode: transport.ExpectNone})
	return name, err
}

// WriteUpload writes a recording_upload record recupload-<id> (payload is the
// upload's JSON) with its sealed asset attached, if nothing holds the name.
func (p *Phone) WriteUpload(id string, payload []byte, asset *secure.AssetDescriptor, sealed []byte) (string, error) {
	name := secure.RecordName(p.cfg.MetaKey, secure.ZoneRelay, "recupload", id)
	env, err := p.seal(name, secure.InnerFrame{Kind: "recording_upload", ID: "recupload-" + id, Asset: asset, Payload: payload})
	if err != nil {
		return "", err
	}
	_, err = p.cfg.Transport.WriteWithAsset(p.zone, name, env, sealed, transport.Expect{Mode: transport.ExpectAbsent})
	return name, err
}

// SendLegacy writes a as today's phones do: no action_seq, record
// action-<id>. It returns the wire name.
func (p *Phone) SendLegacy(a wire.ActionRequest) (string, error) {
	a.ActionSeq = nil
	payload, err := wire.Marshal(a)
	if err != nil {
		return "", err
	}
	plain := "action-" + a.ID
	name := secure.RecordName(p.cfg.MetaKey, secure.ZoneRelay, "action", a.ID)
	env, err := p.seal(name, secure.InnerFrame{Kind: "action", ID: plain, Payload: payload})
	if err != nil {
		return "", err
	}
	p.legacy[a.ID] = sent{plain: plain, wire: name, env: env}
	_, err = p.cfg.Transport.Write(p.zone, name, env, transport.Expect{Mode: transport.ExpectAbsent})
	return name, err
}

// WriteLegacyCopy writes legacy action id's original bytes over whatever
// holds its name.
func (p *Phone) WriteLegacyCopy(id string) error {
	s, ok := p.legacy[id]
	if !ok {
		return fmt.Errorf("hubtest: no legacy action %s", id)
	}
	_, err := p.cfg.Transport.Write(p.zone, s.wire, s.env, transport.Expect{Mode: transport.ExpectNone})
	return err
}

// Sync reads the mailbox since the last sync: echoes are recorded (a final
// one settles the outbox and is deleted), hub controls are recorded, deleted
// and acted on (resend_from). It returns how many hub records it handled.
func (p *Phone) Sync() (int, error) {
	n := 0
	for {
		b, err := p.cfg.Transport.Changes(context.Background(), p.zone, p.cursor)
		if err != nil {
			return n, err
		}
		dropped := false
		for _, rec := range b.Changed {
			f, err := p.open(rec.Name, rec.Envelope)
			if err != nil {
				// The phone's own records, or a hub record it cannot open.
				if p.goneEpoch(rec) {
					p.Dropped = append(p.Dropped, rec.Name)
					dropped = true
				}
				continue
			}
			if p.Guard && p.rolledBack(rec) {
				continue
			}
			n++
			switch f.Kind {
			case "action":
				if h, err := secure.ParseHeader(rec.Envelope); err == nil {
					p.noteEchoEpoch(f, h.Epoch)
				}
				if err := p.onEcho(rec, f); err != nil {
					return n, err
				}
			case "recording_upload":
				var m map[string]any
				if err := json.Unmarshal(f.Payload, &m); err != nil {
					return n, fmt.Errorf("hubtest: unreadable upload echo: %w", err)
				}
				if p.UploadEchoes == nil {
					p.UploadEchoes = map[string]map[string]any{}
				}
				id, _ := m["id"].(string)
				p.UploadEchoes[id] = m
			case "control":
				if err := p.onControl(rec, f); err != nil {
					return n, err
				}
			}
		}
		p.cursor = b.NewSeq
		if dropped && p.RequeueOnDrop {
			if err := p.ResendOutbox(); err != nil {
				return n, err
			}
		}
		if !b.More {
			return n, nil
		}
	}
}

// goneEpoch reports a hub record to this phone, sealed in an epoch at or
// below the one the phone seals in, which it cannot open: its keys are gone.
func (p *Phone) goneEpoch(rec transport.Stored) bool {
	h, err := secure.ParseHeader(rec.Envelope)
	return err == nil && h.Class == secure.ClassRelayToPhone && h.Hub == p.cfg.Hub &&
		h.Sender == p.cfg.Hub && h.Epoch <= p.cfg.Epoch
}

// Records is every live record name in the mailbox.
func (p *Phone) Records() ([]string, error) {
	var names []string
	var since uint64
	for {
		b, err := p.cfg.Transport.Changes(context.Background(), p.zone, since)
		if err != nil {
			return nil, err
		}
		for _, r := range b.Changed {
			names = append(names, r.Name)
		}
		if !b.More {
			return names, nil
		}
		since = b.NewSeq
	}
}

func (p *Phone) onEcho(rec transport.Stored, f secure.InnerFrame) error {
	var a wire.ActionRequest
	if err := json.Unmarshal(f.Payload, &a); err != nil {
		return fmt.Errorf("hubtest: unreadable echo: %w", err)
	}
	if a.ActionSeq != nil && !finalStatus(a.Status) && finalStatus(p.Echoes[*a.ActionSeq].Status) &&
		!slices.Contains(p.outbox, *a.ActionSeq) {
		// An older echo of an action the phone already settled: a page read
		// before the phone took the final echo from a write conflict
		// (Send) still carries the held or received echo the final one
		// replaced. The hub never goes back from a final outcome.
		return nil
	}
	if a.ActionSeq == nil {
		p.LegacyEchoes[a.ID] = a
	} else {
		p.Echoes[*a.ActionSeq] = a
		p.wrote(*a.ActionSeq, rec.RecordSeq)
		p.Read = append(p.Read, "echo:"+strconv.FormatUint(*a.ActionSeq, 10)+":"+a.Status)
	}
	if finalStatus(a.Status) {
		if a.ActionSeq != nil {
			seq := *a.ActionSeq
			p.outbox = slices.DeleteFunc(p.outbox, func(s uint64) bool { return s == seq })
		}
		_, err := p.cfg.Transport.Delete(context.Background(), p.zone, []transport.DeleteItem{{
			Name: rec.Name, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: rec.RecordSeq},
		}})
		return err
	}
	return nil
}

// finalStatus reports an echo status that settles the action.
func finalStatus(s string) bool {
	switch s {
	case wire.StatusApplied, wire.StatusFailed, wire.StatusExpired, wire.StatusCancelled:
		return true
	}
	return false
}

func (p *Phone) onControl(rec transport.Stored, f secure.InnerFrame) error {
	var c wire.Control
	if err := json.Unmarshal(f.Payload, &c); err != nil {
		return fmt.Errorf("hubtest: unreadable control: %w", err)
	}
	p.Controls = append(p.Controls, c)
	p.Read = append(p.Read, "control:"+c.Kind)
	var epoch uint32
	if h, err := secure.ParseHeader(rec.Envelope); err == nil {
		epoch = h.Epoch
	}
	p.ControlEpochs = append(p.ControlEpochs, epoch)
	if _, err := p.cfg.Transport.Delete(context.Background(), p.zone, []transport.DeleteItem{{
		Name: rec.Name, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: rec.RecordSeq},
	}}); err != nil {
		return err
	}
	if c.Kind != wire.ControlResendFrom || c.Seq == nil {
		return nil
	}
	return p.resendFrom(*c.Seq)
}

// resendFrom is sim rules 5–6: everything from `from` again, in order and with
// the same bytes, each a new version over the last record the phone knows at
// its name (Send);
// actions the outbox no longer has become undelivered and a
// skip_to names the first one it still has (or its next seq).
func (p *Phone) resendFrom(from uint64) error {
	first := p.nextAction
	for _, s := range p.outbox {
		if s >= from {
			first = min(first, s)
		}
	}
	if first > from {
		for s := from; s < first; s++ {
			p.Undelivered = append(p.Undelivered, s)
		}
		if err := p.SkipTo(first); err != nil {
			return err
		}
	}
	listed := false
	for _, s := range slices.Sorted(slices.Values(p.outbox)) {
		if s < from {
			continue
		}
		if p.RefusedForGood[s] {
			p.Undelivered = append(p.Undelivered, s)
			p.Forget(s)
			listed = true
			continue
		}
		if err := p.reseal(s); err != nil {
			return err
		}
		if err := p.Send(s); err != nil {
			return err
		}
	}
	if !listed {
		return nil
	}
	first = p.nextAction
	for _, s := range p.outbox {
		if s >= from {
			first = min(first, s)
		}
	}
	if first > from {
		return p.SkipTo(first)
	}
	return nil
}

// reseal is sim rule 14: an outbox action sealed in an epoch older than the
// phone's current one is sealed again in the current epoch with the same
// action_seq and name (its next Send overwrites the record); Resealed counts
// them.
func (p *Phone) reseal(seq uint64) error {
	s, ok := p.history[seq]
	if !ok || s.epoch >= p.cfg.Epoch {
		return nil
	}
	env, err := p.seal(s.wire, s.frame)
	if err != nil {
		return err
	}
	s.env, s.epoch = env, p.cfg.Epoch
	p.history[seq] = s
	p.Resealed = append(p.Resealed, seq)
	return nil
}

// Empty is sim rule 15 for a mailbox the phone left: it first handles the
// hub records it has not seen (Sync), then deletes everything else it can
// tell is its own or the hub's to it — its leftover actions and controls
// included. In a shared mailbox another phone's records are left alone.
func (p *Phone) Empty() error {
	if _, err := p.Sync(); err != nil {
		return err
	}
	var since uint64
	for {
		b, err := p.cfg.Transport.Changes(context.Background(), p.zone, since)
		if err != nil {
			return err
		}
		var items []transport.DeleteItem
		for _, rec := range b.Changed {
			if !p.ownRecord(rec) {
				continue
			}
			items = append(items, transport.DeleteItem{Name: rec.Name, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: rec.RecordSeq}})
		}
		if len(items) > 0 {
			if _, err := p.cfg.Transport.Delete(context.Background(), p.zone, items); err != nil {
				return err
			}
		}
		if !b.More {
			return nil
		}
		since = b.NewSeq
	}
}

// ownRecord: rec was sealed by this phone, or by the hub to it.
func (p *Phone) ownRecord(rec transport.Stored) bool {
	if h, err := secure.ParseHeader(rec.Envelope); err == nil && h.Sender == p.id {
		return true
	}
	_, err := p.open(rec.Name, rec.Envelope)
	return err == nil
}

// relayKey is the stored pair's key of epoch when the phone holds one, else
// the static wt/relay/v1/ key (the phone's rule for a relay key).
func (p *Phone) relayKey(dir secure.Direction, epoch uint32) ([]byte, error) {
	if pair, ok := p.pairs[epoch]; ok {
		return bytes.Clone(pair[dir]), nil
	}
	return secure.RelayKey(p.kx, p.cfg.HubKX, p.nonce, p.cfg.Hub, p.id, epoch, dir)
}

func (p *Phone) seal(name string, f secure.InnerFrame) ([]byte, error) {
	key, err := p.relayKey(secure.PhoneToHub, p.cfg.Epoch)
	if err != nil {
		return nil, err
	}
	defer clear(key)
	p.envSeq++
	return secure.SealSymmetric(f, secure.ClassRelayToHub, key, p.cfg.Hub, p.id, p.cfg.Epoch, p.envSeq,
		secure.Context{Zone: secure.ZoneRelay, WireName: name}, nil, nil)
}

// open opens a hub relayToPhone record addressed to this phone. The Kit's
// one exception to the key rule (relay client Phase 5): when its key does not
// open the record, the static key is tried, and what it opens is taken only if
// it is a hub_on_relay control (the hub clears a leaving phone's relay keys
// first, so it seals that notice static).
func (p *Phone) open(name string, env []byte) (secure.InnerFrame, error) {
	f, err := p.openWith(name, env, p.relayKey)
	if err != nil {
		static := func(dir secure.Direction, epoch uint32) ([]byte, error) {
			return secure.RelayKey(p.kx, p.cfg.HubKX, p.nonce, p.cfg.Hub, p.id, epoch, dir)
		}
		sf, serr := p.openWith(name, env, static)
		if serr != nil || !isHubOnRelay(sf) {
			return secure.InnerFrame{}, err
		}
		f = sf
	}
	kind, id, _ := strings.Cut(f.ID, "-")
	if secure.RecordName(p.cfg.MetaKey, secure.ZoneRelay, kind, id) != name {
		return secure.InnerFrame{}, secure.ErrNameMismatch
	}
	return f, nil
}

func (p *Phone) openWith(name string, env []byte, key func(secure.Direction, uint32) ([]byte, error)) (secure.InnerFrame, error) {
	_, f, err := secure.OpenSymmetric(env, []secure.EnvelopeClass{secure.ClassRelayToPhone},
		secure.Context{Zone: secure.ZoneRelay, WireName: name}, nil,
		func(h secure.Header) ([]byte, error) {
			if h.Hub != p.cfg.Hub || h.Sender != p.cfg.Hub {
				return nil, errors.New("hubtest: not from the hub")
			}
			return key(secure.HubToPhone, h.Epoch)
		})
	return f, err
}

// isHubOnRelay: f is a hub_on_relay control.
func isHubOnRelay(f secure.InnerFrame) bool {
	if f.Kind != "control" {
		return false
	}
	var c wire.Control
	return json.Unmarshal(f.Payload, &c) == nil && c.Kind == wire.ControlHubOnRelay
}

func newUUID() string {
	var id secure.ID
	_, _ = rand.Read(id[:])
	id[6] = id[6]&0x0f | 0x40
	id[8] = id[8]&0x3f | 0x80
	return id.String()
}

// FromLink is a phone that scanned link code l: it knows the hub's id, keys
// and relay device id from the code, and gets K_meta and the epoch from its
// keybox once the owner confirmed (ReadKeybox). Its link nonce is the code's.
func FromLink(l wire.LinkPayload, f Records, clock func() time.Time) (*Phone, error) {
	return FromLinkWithKey(l, f, clock, nil)
}

// FromLinkWithKey is FromLink for a phone with device key key (nil = fresh).
func FromLinkWithKey(l wire.LinkPayload, f Records, clock func() time.Time, key ed25519.PrivateKey) (*Phone, error) {
	hub, err := secure.ParseID(l.HubID)
	if err != nil {
		return nil, fmt.Errorf("hubtest: link hub id: %w", err)
	}
	b64 := base64.RawURLEncoding
	kxRaw, err := b64.DecodeString(l.HubKX)
	if err != nil {
		return nil, fmt.Errorf("hubtest: link hub_kx: %w", err)
	}
	kx, err := ecdh.X25519().NewPublicKey(kxRaw)
	if err != nil {
		return nil, fmt.Errorf("hubtest: link hub_kx: %w", err)
	}
	sig, err := b64.DecodeString(l.HubSig)
	if err != nil || len(sig) != ed25519.PublicKeySize {
		return nil, errors.New("hubtest: link hub_sig is not an Ed25519 key")
	}
	nonce, err := b64.DecodeString(l.Nonce)
	if err != nil {
		return nil, fmt.Errorf("hubtest: link nonce: %w", err)
	}
	p, err := New(Config{Hub: hub, HubKX: kx, HubSig: ed25519.PublicKey(sig), HubRelayID: l.RelayDeviceID, Transport: f, Clock: clock, Key: key})
	if err != nil {
		return nil, err
	}
	p.nonce = nonce
	return p, nil
}

// voucher is a phone record store that can vouch for a hub on the relay
// (RelayStore).
type voucher interface {
	VouchHub(ctx context.Context, hubPub ed25519.PublicKey) error
}

// VouchLink vouches for the hub of link code l on the hosted relay (phone
// contract point 3): sent after the owner confirmed the code and the keybox
// opened, before promote_pairing (or add_slot), for the code's
// relay_auth_pub (the relay derives relay_device_id from it). A refusal
// leaves the hub unvouched.
func (p *Phone) VouchLink(ctx context.Context, l wire.LinkPayload) error {
	v, ok := p.cfg.Transport.(voucher)
	if !ok {
		return errors.New("hubtest: this phone's record store cannot vouch (not on the hosted relay)")
	}
	pub, err := base64.RawURLEncoding.DecodeString(l.RelayAuthPub)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return errors.New("hubtest: link relay_auth_pub is not an Ed25519 key")
	}
	return v.VouchHub(ctx, pub)
}

// HelloName is the wire name of the phone's hello (and, with "keybox-",
// of the hub's answer).
func (p *Phone) HelloName() string { return "hello-" + p.id.String() }

// Hello writes the phone's hello into zone (a pairing slot's pair/<slot>):
// its device payload and keys sealed to hub_kx under the link nonce, signed,
// naming its own relay device id.
func (p *Phone) Hello(zone string) error {
	b64 := base64.RawURLEncoding
	h := wire.DeviceHello{
		Device: wire.DevicePayload{
			DeviceID: p.id.String(), Name: "Test Phone", Model: "iPhone18,1", AppVersion: "0.0.0-test",
			Scope: wire.ScopePrivate, StartSessions: true, UpdatedAt: wire.Time{Time: p.cfg.Clock()},
		},
		SigningKey:    b64.EncodeToString(p.sig.Public().(ed25519.PublicKey)),
		AgreementKey:  b64.EncodeToString(p.kx.PublicKey().Bytes()),
		RelayDeviceID: p.relayID,
	}
	payload, err := wire.Marshal(h)
	if err != nil {
		return err
	}
	name := p.HelloName()
	env, err := secure.SealHPKE(secure.InnerFrame{Kind: "hello", ID: name, Payload: payload}, secure.ClassHello,
		p.cfg.HubKX, secure.HelloInfo(p.cfg.Hub, p.nonce), p.cfg.Hub, p.id, 1, 1,
		secure.Context{Zone: secure.ZoneRelay, WireName: name}, p.sig)
	if err != nil {
		return err
	}
	_, err = p.cfg.Transport.Write(zone, name, env, transport.Expect{})
	return err
}

// ReadKeybox reads the hub's keybox for this phone from zone (a pair zone
// or the data zone), checking the hub's signature. A keybox with keys gives
// the phone K_meta and the current epoch. ok is false when there is none.
func (p *Phone) ReadKeybox(zone string) (wire.Keybox, bool, error) {
	if len(p.cfg.HubSig) != ed25519.PublicKeySize {
		return wire.Keybox{}, false, errors.New("hubtest: no hub signing key to check a keybox")
	}
	want := "keybox-" + p.id.String()
	var since uint64
	for {
		b, err := p.cfg.Transport.Changes(context.Background(), zone, since)
		if err != nil {
			return wire.Keybox{}, false, err
		}
		for _, rec := range b.Changed {
			if rec.Name != want {
				continue
			}
			f, err := p.openKeybox(rec)
			if err != nil {
				return wire.Keybox{}, false, fmt.Errorf("hubtest: opening the keybox: %w", err)
			}
			var kb wire.Keybox
			if err := json.Unmarshal(f.Payload, &kb); err != nil {
				return wire.Keybox{}, false, fmt.Errorf("hubtest: unreadable keybox: %w", err)
			}
			if kb.Keys != nil {
				meta, err := base64.RawURLEncoding.DecodeString(kb.Keys.MetaKey)
				if err != nil {
					return wire.Keybox{}, false, fmt.Errorf("hubtest: keybox meta key: %w", err)
				}
				if err := p.takeRelayKX(*kb.Keys); err != nil {
					return wire.Keybox{}, false, err
				}
				p.cfg.MetaKey, p.cfg.Epoch = meta, kb.Keys.Epoch
			}
			return kb, true, nil
		}
		if !b.More {
			return wire.Keybox{}, false, nil
		}
		since = b.NewSeq
	}
}

// SAS is the four-digit code the phone shows for an awaiting keybox's
// confirm nonce: the hub's code must equal it.
func (p *Phone) SAS(confirmNonce string) (string, error) {
	confirm, err := base64.RawURLEncoding.DecodeString(confirmNonce)
	if err != nil {
		return "", fmt.Errorf("hubtest: confirm nonce: %w", err)
	}
	return secure.SAS(p.cfg.Hub, p.nonce, p.cfg.HubSig, p.cfg.HubKX, p.sig.Public().(ed25519.PublicKey),
		p.kx.PublicKey(), confirm), nil
}

// DataRecord is one hub record of the data zone the phone opened: its wire
// name, frame and attachment id ("" for none).
type DataRecord struct {
	Name, AttachmentID string
	Frame              secure.InnerFrame
}

// OpenAlertPush opens a send_alert envelope as the notification extension
// does (AlertOpener, wire name alert-push): class alert only, K_alert of its
// epoch from the data zone's keybox, the hub's signature. No zone read but
// the keybox.
func (p *Phone) OpenAlertPush(zone string, env []byte) (secure.InnerFrame, error) {
	kb, ok, err := p.ReadKeybox(zone)
	if err != nil {
		return secure.InnerFrame{}, err
	}
	if !ok || kb.Keys == nil {
		return secure.InnerFrame{}, errors.New("hubtest: no keys in the data zone's keybox")
	}
	keys := map[uint32]string{kb.Keys.Epoch: kb.Keys.AlertKey}
	if kb.Keys.PreviousEpoch != nil && kb.Keys.PreviousAlertKey != nil {
		keys[*kb.Keys.PreviousEpoch] = *kb.Keys.PreviousAlertKey
	}
	_, f, err := secure.OpenSymmetric(env, []secure.EnvelopeClass{secure.ClassAlert},
		secure.Context{Zone: secure.ZoneData, WireName: secure.AlertPushWireName}, p.cfg.HubSig,
		func(h secure.Header) ([]byte, error) {
			k, ok := keys[h.Epoch]
			if !ok {
				return nil, fmt.Errorf("hubtest: no alert key for epoch %d", h.Epoch)
			}
			return base64.RawURLEncoding.DecodeString(k)
		})
	return f, err
}

// OpenHeldAlertPush opens a send_alert envelope as a locked phone's
// notification extension does: with only the K_alert of the epochs the phone
// was given by its last Keep (its alert material), never the zone's keybox.
func (p *Phone) OpenHeldAlertPush(env []byte) (secure.Header, secure.InnerFrame, error) {
	return secure.OpenSymmetric(env, []secure.EnvelopeClass{secure.ClassAlert},
		secure.Context{Zone: secure.ZoneData, WireName: secure.AlertPushWireName}, p.cfg.HubSig,
		func(h secure.Header) ([]byte, error) {
			k, ok := p.alertKeys[h.Epoch]
			if !ok {
				return nil, fmt.Errorf("hubtest: the phone holds no alert key for epoch %d", h.Epoch)
			}
			return bytes.Clone(k), nil
		})
}

// OpenData opens every live hub record of the data zone (slices and alerts)
// as a phone does: with the keybox's K_data / K_alert of the record's epoch,
// checking the hub's signature and the wire name (the heartbeat keeps its
// plain name). The keybox itself and the
// payload-free alert signals are left out; a record that does not open is an
// error.
func (p *Phone) OpenData(zone string) ([]DataRecord, error) {
	kb, ok, err := p.ReadKeybox(zone)
	if err != nil {
		return nil, err
	}
	if !ok || kb.Keys == nil {
		return nil, errors.New("hubtest: no keys in the data zone's keybox")
	}
	b64 := base64.RawURLEncoding
	keys := map[uint32][2]string{kb.Keys.Epoch: {kb.Keys.DataKey, kb.Keys.AlertKey}}
	if kb.Keys.PreviousEpoch != nil && kb.Keys.PreviousDataKey != nil && kb.Keys.PreviousAlertKey != nil {
		keys[*kb.Keys.PreviousEpoch] = [2]string{*kb.Keys.PreviousDataKey, *kb.Keys.PreviousAlertKey}
	}
	var out []DataRecord
	var since uint64
	for {
		b, err := p.cfg.Transport.Changes(context.Background(), zone, since)
		if err != nil {
			return nil, err
		}
		for _, rec := range b.Changed {
			if strings.HasPrefix(rec.Name, "keybox-") || strings.HasPrefix(rec.Name, secure.SignalPrefix) {
				continue
			}
			_, f, err := secure.OpenSymmetric(rec.Envelope, []secure.EnvelopeClass{secure.ClassData, secure.ClassAlert},
				secure.Context{Zone: secure.ZoneData, WireName: rec.Name}, p.cfg.HubSig,
				func(h secure.Header) ([]byte, error) {
					k, ok := keys[h.Epoch]
					if !ok {
						return nil, fmt.Errorf("hubtest: no keys for epoch %d", h.Epoch)
					}
					raw := k[0]
					if h.Class == secure.ClassAlert {
						raw = k[1]
					}
					return b64.DecodeString(raw)
				})
			if err != nil {
				return nil, fmt.Errorf("hubtest: opening %s: %w", rec.Name, err)
			}
			kind, id, _ := strings.Cut(f.ID, "-")
			if f.ID != "heartbeat" && secure.RecordName(p.cfg.MetaKey, secure.ZoneData, kind, id) != rec.Name {
				return nil, fmt.Errorf("hubtest: %s: %w", rec.Name, secure.ErrNameMismatch)
			}
			out = append(out, DataRecord{Name: rec.Name, AttachmentID: rec.AttachmentID, Frame: f})
		}
		if !b.More {
			return out, nil
		}
		since = b.NewSeq
	}
}
