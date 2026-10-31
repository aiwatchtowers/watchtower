// Package hubtest is the Go phone emulator the hub's tests drive (the relay
// sim's Phone, on real envelopes): it holds a linked phone's keys, derives
// the pairwise relay keys, seals relayToHub actions carrying action_seq into
// its mailbox on a memfake transport, keeps them in an outbox until a final
// echo, opens the hub's echoes and controls, answers resend_from (resending
// with the same bytes, or skip_to when it no longer has an action) and
// deletes what it read. Test-only: never imported by production code.
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

// Config is what a linked phone knows about its hub (the keybox and the link
// code): its id, agreement key, K_meta and current epoch, plus the hub's relay
// device id (the mailbox's first half), the shared fake and a clock.
type Config struct {
	Hub        secure.ID
	HubKX      *ecdh.PublicKey
	MetaKey    []byte
	Epoch      uint32
	HubRelayID string
	Transport  *memfake.Fake
	Clock      func() time.Time
}

type sent struct {
	plain, wire string
	env         []byte
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
	// Controls is every hub control read, in order.
	Controls []wire.Control
	// Undelivered lists the actions a skip_to gave up on.
	Undelivered []uint64
}

// New makes a phone with fresh keys.
func New(cfg Config) (*Phone, error) {
	if cfg.Clock == nil {
		cfg.Clock = time.Now
	}
	pub, sig, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
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
	return &Phone{
		cfg: cfg, sig: sig, kx: kx, id: secure.DeviceID(pub), nonce: nonce, relayID: relayID,
		zone:       transport.MailboxZone(cfg.HubRelayID, relayID),
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
	env, err := p.seal(name, secure.InnerFrame{Kind: "action", ID: plain, Payload: payload})
	if err != nil {
		return 0, err
	}
	p.nextAction++
	p.history[seq] = sent{plain: plain, wire: name, env: env}
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

// Send writes action seq's sealed bytes (sim rule 3 on a conflict: an echo
// at that name means delivered, the same bytes mean already there, anything
// else is overwritten).
func (p *Phone) Send(seq uint64) error {
	s, ok := p.history[seq]
	if !ok {
		return fmt.Errorf("hubtest: no action %d", seq)
	}
	out, err := p.cfg.Transport.Write(p.zone, s.wire, s.env, transport.Expect{Mode: transport.ExpectAbsent})
	if err != nil || out.Saved || out.Conflict == nil {
		return err
	}
	cur := out.Conflict
	if bytes.Equal(cur.Envelope, s.env) {
		return nil
	}
	if f, err := p.open(cur.Name, cur.Envelope); err == nil && f.Kind == "action" {
		return p.onEcho(*cur, f)
	}
	_, err = p.cfg.Transport.Write(p.zone, s.wire, s.env, transport.Expect{Mode: transport.ExpectSeq, Seq: cur.RecordSeq})
	return err
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
		for _, rec := range b.Changed {
			f, err := p.open(rec.Name, rec.Envelope)
			if err != nil {
				continue // the phone's own records
			}
			n++
			switch f.Kind {
			case "action":
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
		if !b.More {
			return n, nil
		}
	}
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
	if a.ActionSeq == nil {
		p.LegacyEchoes[a.ID] = a
	} else {
		p.Echoes[*a.ActionSeq] = a
	}
	switch a.Status {
	case wire.StatusApplied, wire.StatusFailed, wire.StatusExpired, wire.StatusCancelled:
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

func (p *Phone) onControl(rec transport.Stored, f secure.InnerFrame) error {
	var c wire.Control
	if err := json.Unmarshal(f.Payload, &c); err != nil {
		return fmt.Errorf("hubtest: unreadable control: %w", err)
	}
	p.Controls = append(p.Controls, c)
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
// the same bytes; actions the outbox no longer has become undelivered and a
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
	for _, s := range slices.Sorted(slices.Values(p.outbox)) {
		if s >= from {
			if err := p.Send(s); err != nil {
				return err
			}
		}
	}
	return nil
}

func (p *Phone) relayKey(dir secure.Direction, epoch uint32) ([]byte, error) {
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

// open opens a hub relayToPhone record addressed to this phone.
func (p *Phone) open(name string, env []byte) (secure.InnerFrame, error) {
	_, f, err := secure.OpenSymmetric(env, []secure.EnvelopeClass{secure.ClassRelayToPhone},
		secure.Context{Zone: secure.ZoneRelay, WireName: name}, nil,
		func(h secure.Header) ([]byte, error) {
			if h.Hub != p.cfg.Hub || h.Sender != p.cfg.Hub {
				return nil, errors.New("hubtest: not from the hub")
			}
			return p.relayKey(secure.HubToPhone, h.Epoch)
		})
	if err != nil {
		return secure.InnerFrame{}, err
	}
	kind, id, _ := strings.Cut(f.ID, "-")
	if secure.RecordName(p.cfg.MetaKey, secure.ZoneRelay, kind, id) != name {
		return secure.InnerFrame{}, secure.ErrNameMismatch
	}
	return f, nil
}

func newUUID() string {
	var id secure.ID
	_, _ = rand.Read(id[:])
	id[6] = id[6]&0x0f | 0x40
	id[8] = id[8]&0x3f | 0x80
	return id.String()
}
