package secure

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"

	"golang.org/x/crypto/chacha20poly1305"
)

// The names SecureTransport keeps key-free.
const (
	heartbeatName = "heartbeat"
	grantKind     = "device_grant"
	alertKind     = "ask_alert"
	helloKind     = "hello"
	grantPrefix   = grantKind + "-"
	keyboxPrefix  = "keybox-"
	helloPrefix   = helloKind + "-"
)

// Record is the only value a transport accepts (spec §13 point 2: nothing
// leaves the hub unless it passed the Sealer). Its fields are unexported, so a
// Record built outside this package is the zero value, which Sealed() reports
// false; every transport refuses such a record with ErrUnsealed before any I/O.
type Record struct {
	zone, wireName string
	envelope       []byte
	assetPath      string
	sealed         bool
}

// Zone is the transport zone the record goes to.
func (r Record) Zone() string { return r.zone }

// WireName is the record's name on the wire (key-free or an HMAC name).
func (r Record) WireName() string { return r.wireName }

// Envelope is a copy of the sealed envelope bytes.
func (r Record) Envelope() []byte { return bytes.Clone(r.envelope) }

// AssetPath is the sealed asset file the record's frame describes, or "".
func (r Record) AssetPath() string { return r.assetPath }

// Sealed is true only for a Record the Sealer produced.
func (r Record) Sealed() bool { return r.sealed }

// KeySource is the hub's keys (identity.Keyring in production). Ownership:
// every []byte key a method returns is a fresh copy that the caller owns and
// zeroes after use — the Sealer and the Opener clear each one — so an
// implementation must never hand out its own cached slice. Signer and
// Agreement stay the source's and are never modified here.
type KeySource interface {
	HubID() ID
	CurrentEpoch() (uint32, error)
	NextSeq() (uint64, error)
	DataKey(epoch uint32) ([]byte, error)
	AlertKey(epoch uint32) ([]byte, error)
	MetaKey() ([]byte, error)
	RelayKey(dir Direction, device ID, epoch uint32) ([]byte, error)
	AcceptsRelayEpoch(epoch uint32, device ID) (bool, error)
	// RelayDevices is every linked device that holds relay keys (the Kit's
	// relayDeviceIDs): the senders FromPhone accepts and the keys OwnEcho tries.
	RelayDevices() ([]ID, error)
	Signer() ed25519.PrivateKey
	Agreement() *ecdh.PrivateKey
	KeyboxRecipient(device ID) (*ecdh.PublicKey, error)
}

// wireName is SecureTransport.wireName(plain:zone:): in DataZone "heartbeat"
// stays and device_grant-<id> is keybox-<id> (a UUID id in uppercase); in
// RelayZone hello-<id> stays; everything else is RecordName(K_meta, zone,
// kind, id) with the plain name split at its first '-', so a plain name alone
// (a delete) maps to the record's wire name.
func wireName(k KeySource, z Zone, plain string) (string, error) {
	if plain == "" {
		return "", fmt.Errorf("%w: empty record name", ErrNameMismatch)
	}
	switch z {
	case ZoneData:
		if plain == heartbeatName {
			return plain, nil
		}
		if rest, ok := strings.CutPrefix(plain, grantPrefix); ok {
			return keyboxPrefix + canonicalID(rest), nil
		}
	case ZoneRelay:
		if strings.HasPrefix(plain, helloPrefix) {
			return plain, nil
		}
	default:
		return "", fmt.Errorf("secure: unknown zone %d", z)
	}
	meta, err := k.MetaKey()
	if err != nil {
		return "", fmt.Errorf("secure: meta key: %w", err)
	}
	defer clear(meta)
	kind, id := namingParts(plain)
	return RecordName(meta, z, kind, id), nil
}

func namingParts(plain string) (kind, id string) {
	kind, id, _ = strings.Cut(plain, "-")
	return kind, id
}

// canonicalID is the Kit's F30: a UUID id prints as uuidString, anything else
// is left as it is.
func canonicalID(raw string) string {
	if id, err := ParseID(raw); err == nil {
		return id.String()
	}
	return raw
}

// The kinds the Sealer seals, as the Kit's SecureTransport accepts them.
// dataKinds is SliceKind without device_grant (Keybox) and ask_alert (Alert);
// relayKinds is SecureTransport.relayKinds. A new Kit kind is added here in the
// same change; the RC control kind joins relayKinds with the control queue
// (Task 10).
var (
	dataKinds = []string{
		"briefing", "inbox_item", "target", "track", "digest", "digest_topic", "calendar_event", "person_card",
		"situation", "meeting_transcript", "day_plan", "day_plan_item", "feature_state", "stream_digest",
		"slack_account", "google_account", "jira_account", heartbeatName, "recording_job", "workbench",
		"workbench_target", "workbench_comment", "terminal_session", "owner_ask", "session_report",
		"session_timeline", "permission_request", "session_chat",
	}
	relayKinds = []string{"action", "recording_upload", "device"}
)

// Sealer is the single sealing choke point: every Record comes from here.
type Sealer struct{ k KeySource }

// NewSealer seals with k.
func NewSealer(k KeySource) *Sealer { return &Sealer{k: k} }

// WireName maps a plain record name to its wire name in z.
func (s *Sealer) WireName(z Zone, plain string) (string, error) { return wireName(s.k, z, plain) }

// Data seals a DataZone slice record (class data, signed by hub_sig): frame
// kind = the plain name before its first '-', frame id = the plain name. A
// device_grant goes through Keybox and an ask_alert through Alert. asset and
// assetPath go together, and the file must be the asset sealed under asset.
func (s *Sealer) Data(zone, plain, notify string, payload []byte, asset *AssetDescriptor, assetPath string) (Record, error) {
	kind, _ := namingParts(plain)
	if kind == grantKind || kind == alertKind {
		return Record{}, fmt.Errorf("%w: %s is not sealed as data", ErrWrongClass, kind)
	}
	if !slices.Contains(dataKinds, kind) {
		return Record{}, fmt.Errorf("%w: %q", ErrUnknownKind, kind)
	}
	if err := checkSealedAsset(asset, assetPath); err != nil {
		return Record{}, err
	}
	f := InnerFrame{Kind: kind, ID: plain, NotifyLevel: notify, Asset: asset, Payload: payload}
	return s.signedSymmetric(zone, plain, f, ClassData, assetPath)
}

// Alert seals an ask_alert-<id> record (class alert, K_alert, signed).
func (s *Sealer) Alert(zone, plain string, payload []byte) (Record, error) {
	if kind, _ := namingParts(plain); kind != alertKind {
		return Record{}, fmt.Errorf("%w: %s is not an alert", ErrWrongClass, kind)
	}
	return s.signedSymmetric(zone, plain, InnerFrame{Kind: alertKind, ID: plain, Payload: payload}, ClassAlert, "")
}

func (s *Sealer) signedSymmetric(zone, plain string, f InnerFrame, c EnvelopeClass, assetPath string) (Record, error) {
	if zone == "" {
		return Record{}, errors.New("secure: record without a zone")
	}
	signer := s.k.Signer()
	if len(signer) != ed25519.PrivateKeySize {
		return Record{}, ErrSignatureRequired
	}
	wire, err := s.WireName(ZoneData, plain)
	if err != nil {
		return Record{}, err
	}
	epoch, err := s.k.CurrentEpoch()
	if err != nil {
		return Record{}, fmt.Errorf("secure: current epoch: %w", err)
	}
	var key []byte
	if c == ClassAlert {
		key, err = s.k.AlertKey(epoch)
	} else {
		key, err = s.k.DataKey(epoch)
	}
	defer clear(key)
	if err != nil {
		return Record{}, fmt.Errorf("secure: epoch key: %w", err)
	}
	seq, err := s.k.NextSeq()
	if err != nil {
		return Record{}, fmt.Errorf("secure: next seq: %w", err)
	}
	hub := s.k.HubID()
	env, err := SealSymmetric(f, c, key, hub, hub, epoch, seq, Context{Zone: ZoneData, WireName: wire}, signer, nil)
	if err != nil {
		return Record{}, err
	}
	return Record{zone: zone, wireName: wire, envelope: env, assetPath: assetPath, sealed: true}, nil
}

// ToPhone seals a RelayZone record for device (class relayToPhone, its h2p
// key, unsigned). wireName must be id's wire name: the phone refuses a frame
// whose plain name maps elsewhere.
func (s *Sealer) ToPhone(zone string, device ID, wireName, kind, id string, payload []byte) (Record, error) {
	if zone == "" {
		return Record{}, errors.New("secure: record without a zone")
	}
	if !slices.Contains(relayKinds, kind) {
		return Record{}, fmt.Errorf("%w: %q", ErrUnknownKind, kind)
	}
	want, err := s.WireName(ZoneRelay, id)
	if err != nil {
		return Record{}, err
	}
	if want != wireName {
		return Record{}, ErrNameMismatch
	}
	epoch, err := s.k.CurrentEpoch()
	if err != nil {
		return Record{}, fmt.Errorf("secure: current epoch: %w", err)
	}
	key, err := s.k.RelayKey(HubToPhone, device, epoch)
	defer clear(key)
	if err != nil {
		return Record{}, fmt.Errorf("secure: relay key: %w", err)
	}
	seq, err := s.k.NextSeq()
	if err != nil {
		return Record{}, fmt.Errorf("secure: next seq: %w", err)
	}
	hub := s.k.HubID()
	f := InnerFrame{Kind: kind, ID: id, Payload: payload}
	env, err := SealSymmetric(f, ClassRelayToPhone, key, hub, hub, epoch, seq, Context{Zone: ZoneRelay, WireName: wireName}, nil, nil)
	if err != nil {
		return Record{}, err
	}
	return Record{zone: zone, wireName: wireName, envelope: env, sealed: true}, nil
}

// Keybox seals device's device_grant-<id> record as keybox-<id> (HPKE to
// KeyboxRecipient(device), KeyboxInfo, signed by hub_sig).
func (s *Sealer) Keybox(zone string, device ID, payload []byte) (Record, error) {
	if zone == "" {
		return Record{}, errors.New("secure: record without a zone")
	}
	to, err := s.k.KeyboxRecipient(device)
	if err != nil {
		return Record{}, fmt.Errorf("secure: keybox recipient: %w", err)
	}
	if to == nil {
		return Record{}, errors.New("secure: no keybox recipient")
	}
	epoch, err := s.k.CurrentEpoch()
	if err != nil {
		return Record{}, fmt.Errorf("secure: current epoch: %w", err)
	}
	seq, err := s.k.NextSeq()
	if err != nil {
		return Record{}, fmt.Errorf("secure: next seq: %w", err)
	}
	hub := s.k.HubID()
	wire := keyboxPrefix + device.String()
	f := InnerFrame{Kind: grantKind, ID: grantPrefix + device.String(), Payload: payload}
	env, err := SealHPKE(f, ClassKeybox, to, KeyboxInfo(hub, device), hub, hub, epoch, seq,
		Context{Zone: ZoneData, WireName: wire}, s.k.Signer())
	if err != nil {
		return Record{}, err
	}
	return Record{zone: zone, wireName: wire, envelope: env, sealed: true}, nil
}

// checkSealedAsset refuses an asset file that is not the asset sealed under d:
// its length must match d's header and its first chunk must open with d's key
// (a plaintext file of the right size does not). It runs at seal time only and
// checks the length and chunk 0, not every chunk: the file can still change
// afterwards, so a transport must re-check it before upload or accept uploads
// only from the sealer's own asset directory.
func checkSealedAsset(d *AssetDescriptor, path string) error {
	if d == nil && path == "" {
		return nil
	}
	if d == nil || path == "" {
		return fmt.Errorf("%w: an asset needs both its descriptor and its sealed file", ErrUnsealed)
	}
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("secure: open sealed asset: %w", err)
	}
	defer func() { _ = f.Close() }()
	info, err := f.Stat()
	if err != nil {
		return fmt.Errorf("secure: stat sealed asset: %w", err)
	}
	h := d.Header
	chunkLen := uint64(h.ChunkSize) + tagLen
	if info.Size() < 0 || uint64(info.Size()) != uint64(h.ChunkCount)*chunkLen {
		return fmt.Errorf("%w: asset file length disagrees with its descriptor", ErrUnsealed)
	}
	chunk := make([]byte, chunkLen)
	if _, err := io.ReadFull(f, chunk); err != nil {
		return fmt.Errorf("secure: read sealed asset: %w", err)
	}
	aead, err := chacha20poly1305.New(d.Key[:])
	if err != nil {
		return fmt.Errorf("%w: asset key", ErrUnsealed)
	}
	plain, err := aead.Open(nil, chunkNonce(0), chunk, chunkAAD(h.encode(), h, 0))
	clear(plain)
	if err != nil {
		return fmt.Errorf("%w: asset file does not open under its descriptor", ErrUnsealed)
	}
	return nil
}

// Opened is a relay record opened by the Opener.
type Opened struct {
	Sender  ID
	Epoch   uint32
	Seq     uint64
	Frame   InnerFrame
	Verdict Verdict
}

// Opener opens what the hub receives in RelayZone. It only reads the rollback
// guard: the caller records the mark inside the transaction that commits its
// decision about the record (a crash before that commit leaves the record new).
type Opener struct {
	k KeySource
	g RollbackGuard
}

// NewOpener opens with k and checks versions against g.
func NewOpener(k KeySource, g RollbackGuard) *Opener { return &Opener{k: k, g: g} }

// header parses env strictly and refuses another hub's envelope (wrongHub).
func (o *Opener) header(env []byte) (Header, error) {
	e, err := parseEnvelope(env)
	if err != nil {
		return Header{}, err
	}
	if e.header.Hub != o.k.HubID() {
		return Header{}, ErrWrongHub
	}
	return e.header, nil
}

// FromPhone opens a phone's relayToHub record: the sender must be a linked
// device (wrongSender) with an accepted epoch, the frame's plain name must map
// to wireName, and the rollback guard is checked, never written: Older is
// ErrRolledBack, Newer and Same come back as the Verdict. The first
// parameter (the transport zone) is unused: the AAD zone is always RelayZone;
// it stays in the signature for the callers' symmetry with the Sealer.
func (o *Opener) FromPhone(_, wireName string, envelope []byte) (Opened, error) {
	h, err := o.header(envelope)
	if err != nil {
		return Opened{}, err
	}
	if h.Class != ClassRelayToHub {
		return Opened{}, fmt.Errorf("%w: %d", ErrWrongClass, h.Class)
	}
	devices, err := o.k.RelayDevices()
	if err != nil {
		return Opened{}, fmt.Errorf("secure: linked devices: %w", err)
	}
	if !slices.Contains(devices, h.Sender) {
		return Opened{}, ErrWrongSender
	}
	opened, f, err := o.openRelay(envelope, wireName, ClassRelayToHub, PhoneToHub, h.Sender, h.Epoch)
	if err != nil {
		return Opened{}, err
	}
	return o.accept(wireName, opened, f)
}

// OwnEcho opens the hub's own relayToPhone record read back: the sender must
// be the hub (wrongSender); the header names no recipient, so each linked
// device's h2p key is tried (ErrNoRelayKey when none opens it). The guard is
// checked, and the zone parameter unused, as in FromPhone.
func (o *Opener) OwnEcho(_, wireName string, envelope []byte) (Opened, error) {
	h, err := o.header(envelope)
	if err != nil {
		return Opened{}, err
	}
	if h.Class != ClassRelayToPhone {
		return Opened{}, fmt.Errorf("%w: %d", ErrWrongClass, h.Class)
	}
	if h.Sender != h.Hub {
		return Opened{}, ErrWrongSender
	}
	devices, err := o.k.RelayDevices()
	if err != nil {
		return Opened{}, fmt.Errorf("secure: linked devices: %w", err)
	}
	for _, device := range devices {
		opened, f, err := o.openRelay(envelope, wireName, ClassRelayToPhone, HubToPhone, device, h.Epoch)
		switch {
		case errors.Is(err, ErrAuthenticationFailed), errors.Is(err, ErrEpochNotAccepted):
			continue // another phone's key: the expected miss
		case err != nil:
			return Opened{}, err
		}
		return o.accept(wireName, opened, f)
	}
	return Opened{}, ErrNoRelayKey
}

// openRelay opens env under device's relay key for dir at epoch.
func (o *Opener) openRelay(env []byte, wire string, c EnvelopeClass, dir Direction, device ID, epoch uint32) (Header, InnerFrame, error) {
	ok, err := o.k.AcceptsRelayEpoch(epoch, device)
	if err != nil {
		return Header{}, InnerFrame{}, fmt.Errorf("secure: relay epoch: %w", err)
	}
	if !ok {
		return Header{}, InnerFrame{}, ErrEpochNotAccepted
	}
	key, err := o.k.RelayKey(dir, device, epoch)
	defer clear(key)
	if err != nil {
		return Header{}, InnerFrame{}, fmt.Errorf("secure: relay key: %w", err)
	}
	return OpenSymmetric(env, []EnvelopeClass{c}, Context{Zone: ZoneRelay, WireName: wire}, nil,
		func(Header) ([]byte, error) { return key, nil })
}

// accept binds the frame's plain name to wireName and checks the guard.
func (o *Opener) accept(wire string, h Header, f InnerFrame) (Opened, error) {
	want, err := wireName(o.k, ZoneRelay, f.ID)
	if err != nil {
		// A locked or failing keyring surfaces as itself (the Kit lets it through).
		return Opened{}, fmt.Errorf("secure: frame wire name: %w", err)
	}
	if want != wire {
		return Opened{}, ErrNameMismatch
	}
	v, err := o.g.Check(wire, h.Sender, h.Epoch, h.Seq)
	if err != nil {
		return Opened{}, fmt.Errorf("secure: rollback check: %w", err)
	}
	if v == Older {
		return Opened{}, ErrRolledBack
	}
	return Opened{Sender: h.Sender, Epoch: h.Epoch, Seq: h.Seq, Frame: f, Verdict: v}, nil
}

// Hello opens a phone's hello-<device> record with hub_kx and the info of one
// kept link code's nonce (the caller tries each). The name must be
// hello-<header sender> and the frame kind hello with id = the name. The
// device's signature is verified by the link step, with the key the payload
// carries. The zone parameter is unused, as in FromPhone.
func (o *Opener) Hello(_, wireName string, envelope []byte, linkNonce []byte) (Header, InnerFrame, error) {
	h, err := o.header(envelope)
	if err != nil {
		return Header{}, InnerFrame{}, err
	}
	if h.Class != ClassHello {
		return Header{}, InnerFrame{}, fmt.Errorf("%w: %d", ErrWrongClass, h.Class)
	}
	rest, ok := strings.CutPrefix(wireName, helloPrefix)
	if !ok {
		return Header{}, InnerFrame{}, ErrNameMismatch
	}
	if named, err := ParseID(rest); err != nil || named != h.Sender {
		return Header{}, InnerFrame{}, ErrWrongSender
	}
	opened, f, err := OpenHPKE(envelope, ClassHello, o.k.Agreement(), HelloInfo(h.Hub, linkNonce),
		Context{Zone: ZoneRelay, WireName: wireName}, nil)
	if err != nil {
		return Header{}, InnerFrame{}, err
	}
	if f.Kind != helloKind || f.ID != wireName {
		return Header{}, InnerFrame{}, ErrNameMismatch
	}
	return opened, f, nil
}
