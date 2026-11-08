package hubtest

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"maps"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The Kit's side of the weekly relay keys (relay client Phase 5, "The
// scheme"): the phone offers an ephemeral X25519 key on its epoch_ack, opens
// a keybox sealed to that offer, to its current key or to dev_kx, and keeps
// the wt/relay/v2/ pair of each epoch whose keybox names relay_kx, promoting
// the offer once a keybox names it. A keybox for an epoch without relay_kx
// drops that epoch's pair: the epoch is static.

// Offer is the phone's outstanding offer (made now if it has none), unpadded
// base64url of the public key, as epoch_ack's next_kx carries it.
func (p *Phone) Offer() (string, error) {
	if p.offered == nil {
		k, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			return "", err
		}
		p.offered = k
	}
	return base64.RawURLEncoding.EncodeToString(p.offered.PublicKey().Bytes()), nil
}

// AckEpoch writes an epoch_ack of epoch carrying the phone's offer (Offer).
func (p *Phone) AckEpoch(epoch uint32) (string, error) {
	offer, err := p.Offer()
	if err != nil {
		return "", err
	}
	return p.WriteControl(wire.Control{Kind: wire.ControlEpochAck, Epoch: &epoch, NextKX: &offer})
}

// ErasePair drops the phone's wt/relay/v2/ pair of epoch, as the Kit erases
// an old epoch's keys on schedule: a hub record sealed under it no longer
// opens.
func (p *Phone) ErasePair(epoch uint32) {
	delete(p.pairs, epoch)
	delete(p.pairPubs, epoch)
}

// HoldsPair reports whether the phone holds a wt/relay/v2/ pair for epoch.
func (p *Phone) HoldsPair(epoch uint32) bool { _, ok := p.pairs[epoch]; return ok }

// Offered is the outstanding offer's public key (nil when none).
func (p *Phone) Offered() []byte {
	if p.offered == nil {
		return nil
	}
	return p.offered.PublicKey().Bytes()
}

// Current is the promoted ephemeral key's public half (nil when none).
func (p *Phone) Current() []byte {
	if p.current == nil {
		return nil
	}
	return p.current.PublicKey().Bytes()
}

// Open opens a hub relayToPhone record addressed to this phone with the keys
// the phone holds (its pairs, else static).
func (p *Phone) Open(name string, env []byte) (secure.InnerFrame, error) { return p.open(name, env) }

// takeRelayKX merges a keybox's relay keys as the Kit's HubLinkKeys.merging
// does, for the keybox's epoch and the previous one (only when the keybox
// carries both previous keys):
//   - relay_kx and no pair held: the pair is derived from the offer or the
//     current key (an error when it names neither);
//   - relay_kx and a pair held: the same publics are skipped, others refused;
//   - no relay_kx: a held pair is dropped and, on a link with ephemeral
//     state, the epoch is marked cleared with the dropped publics; a cleared
//     epoch skips a relay_kx naming them and refuses any other.
//
// A refusal takes nothing (F17). When the newest relay_kx names the offer,
// the offer becomes the current key.
func (p *Phone) takeRelayKX(k wire.KeyboxKeys) error {
	type named struct {
		epoch uint32
		kx    *wire.KeyboxRelayKX
	}
	list := []named{{k.Epoch, k.RelayKX}}
	if k.PreviousEpoch != nil && k.PreviousDataKey != nil && k.PreviousAlertKey != nil {
		list = append(list, named{*k.PreviousEpoch, k.PreviousRelayKX})
	}
	ephemeral := p.current != nil || p.offered != nil || len(p.pairs) > 0
	pairs := maps.Clone(p.pairs)
	pubs := maps.Clone(p.pairPubs)
	cleared := maps.Clone(p.cleared)
	if pairs == nil {
		pairs = map[uint32]map[secure.Direction][]byte{}
	}
	if pubs == nil {
		pubs = map[uint32]relayPubs{}
	}
	if cleared == nil {
		cleared = map[uint32]relayPubs{}
	}
	for _, n := range list {
		if n.kx == nil {
			dropped, held := pubs[n.epoch]
			delete(pairs, n.epoch)
			delete(pubs, n.epoch)
			if _, marked := cleared[n.epoch]; ephemeral && !marked {
				if !held {
					dropped = relayPubs{}
				}
				cleared[n.epoch] = dropped
			}
			continue
		}
		hubPub, devPub, err := decodeRelayKX(n.kx)
		if err != nil {
			return err
		}
		if held, ok := pubs[n.epoch]; ok {
			if !held.equal(hubPub, devPub) {
				return errUnknownEphemeral
			}
			continue
		}
		if c, ok := cleared[n.epoch]; ok {
			if !c.equal(hubPub, devPub) {
				return errUnknownEphemeral
			}
			continue
		}
		pair, err := p.derivePair(n.epoch, hubPub, devPub)
		if err != nil {
			return err
		}
		pairs[n.epoch] = pair
		pubs[n.epoch] = relayPubs{hub: hubPub, device: devPub}
	}
	p.pairs, p.pairPubs, p.cleared = pairs, pubs, cleared
	if k.RelayKX != nil && p.offered != nil {
		if _, devPub, err := decodeRelayKX(k.RelayKX); err == nil && bytes.Equal(devPub, p.offered.PublicKey().Bytes()) {
			p.current, p.offered = p.offered, nil
		}
	}
	return nil
}

// errUnknownEphemeral is the Kit's KeyboxKeysError.unknownEphemeral: the
// keybox names a key the phone does not hold, or another pair than the one
// it holds for that epoch.
var errUnknownEphemeral = errors.New("hubtest: the keybox names a key the phone does not hold")

func (r relayPubs) equal(hub, device []byte) bool {
	return r.hub != nil && bytes.Equal(r.hub, hub) && bytes.Equal(r.device, device)
}

func decodeRelayKX(kx *wire.KeyboxRelayKX) (hubPub, devPub []byte, err error) {
	b64 := base64.RawURLEncoding
	if hubPub, err = b64.DecodeString(kx.HubPub); err != nil {
		return nil, nil, fmt.Errorf("hubtest: relay_kx hub_pub: %w", err)
	}
	if devPub, err = b64.DecodeString(kx.DevicePub); err != nil {
		return nil, nil, fmt.Errorf("hubtest: relay_kx device_pub: %w", err)
	}
	return hubPub, devPub, nil
}

// derivePair derives epoch's wt/relay/v2/ pair from the phone's offer or
// current key named devPub and the hub's hubPub.
func (p *Phone) derivePair(epoch uint32, hubPub, devPub []byte) (map[secure.Direction][]byte, error) {
	var own *ecdh.PrivateKey
	for _, c := range []*ecdh.PrivateKey{p.offered, p.current} {
		if c != nil && bytes.Equal(c.PublicKey().Bytes(), devPub) {
			own = c
			break
		}
	}
	if own == nil {
		return nil, errUnknownEphemeral
	}
	peer, err := ecdh.X25519().NewPublicKey(hubPub)
	if err != nil {
		return nil, fmt.Errorf("hubtest: relay_kx hub_pub: %w", err)
	}
	pair := map[secure.Direction][]byte{}
	for _, dir := range []secure.Direction{secure.PhoneToHub, secure.HubToPhone} {
		key, err := secure.EphemeralRelayKey(own, peer, p.kx, p.cfg.HubKX, hubPub, devPub, p.nonce, p.cfg.Hub, p.id, epoch, dir)
		if err != nil {
			return nil, err
		}
		pair[dir] = key
	}
	return pair, nil
}

// openKeybox opens a keybox record sealed to the offer, the current key or
// dev_kx, tried in that order.
func (p *Phone) openKeybox(rec transport.Stored) (secure.InnerFrame, error) {
	var last error
	for _, k := range []*ecdh.PrivateKey{p.offered, p.current, p.kx} {
		if k == nil {
			continue
		}
		_, f, err := secure.OpenHPKE(rec.Envelope, secure.ClassKeybox, k, secure.KeyboxInfo(p.cfg.Hub, p.id),
			secure.Context{Zone: secure.ZoneData, WireName: rec.Name}, p.cfg.HubSig)
		if err == nil {
			return f, nil
		}
		last = err
	}
	return secure.InnerFrame{}, last
}

// noteEchoEpoch records the epoch an ordered action's echo was sealed in.
func (p *Phone) noteEchoEpoch(f secure.InnerFrame, epoch uint32) {
	var a wire.ActionRequest
	if json.Unmarshal(f.Payload, &a) != nil || a.ActionSeq == nil {
		return
	}
	if p.EchoEpochs == nil {
		p.EchoEpochs = map[uint64]uint32{}
	}
	p.EchoEpochs[*a.ActionSeq] = epoch
}

// rolledBack is the guard's check of an opened hub record: true (and listed)
// when an older version than one already opened at its name; else the
// version is recorded.
func (p *Phone) rolledBack(rec transport.Stored) bool {
	h, err := secure.ParseHeader(rec.Envelope)
	if err != nil {
		return false
	}
	if p.seen == nil {
		p.seen = map[string][2]uint64{}
	}
	if last, ok := p.seen[rec.Name]; ok && secure.CompareVersion(uint32(last[0]), last[1], h.Epoch, h.Seq) == secure.Older {
		p.RolledBack = append(p.RolledBack, rec.Name)
		return true
	}
	p.seen[rec.Name] = [2]uint64{uint64(h.Epoch), h.Seq}
	return false
}
