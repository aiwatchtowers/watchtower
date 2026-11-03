package hubtest

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The phone's side of the transport switch (relay sim rules 11–13, phone
// contract points 3–7): it moves between record stores, keeps the data keys
// of every epoch it was given, follows a transport_switched by opening the
// keybox inside it, reads the transport marker of a data zone with the keys
// it holds, and resends its outbox with the same bytes.

// storeZone is one mailbox in one record store.
type storeZone struct {
	store Records
	zone  string
}

// Use moves the phone to another record store (the other transport) with
// its mailbox zone there ("" = relay/<hub>/<its relay id>). The cursor of
// the mailbox it leaves is kept for a later Use back; what it knew of record
// versions at its actions' names is forgotten (they are another store's).
func (p *Phone) Use(store Records, mailbox string) {
	if p.cursors == nil {
		p.cursors = map[storeZone]uint64{}
	}
	p.cursors[storeZone{p.cfg.Transport, p.zone}] = p.cursor
	if mailbox == "" {
		mailbox = transport.MailboxZone(p.cfg.HubRelayID, p.relayID)
	}
	p.cfg.Transport, p.zone = store, mailbox
	p.cursor = p.cursors[storeZone{store, mailbox}]
	for seq, s := range p.history {
		s.recordSeq = 0
		p.history[seq] = s
	}
}

// Epoch is the hub epoch the phone seals in.
func (p *Phone) Epoch() uint32 { return p.cfg.Epoch }

// Keep gives the phone a keybox's keys: K_meta, the epoch it seals in and
// K_data of every epoch named (kept alongside those it already holds).
func (p *Phone) Keep(k wire.KeyboxKeys) error {
	b64 := base64.RawURLEncoding
	meta, err := b64.DecodeString(k.MetaKey)
	if err != nil {
		return fmt.Errorf("hubtest: keybox meta key: %w", err)
	}
	data, err := b64.DecodeString(k.DataKey)
	if err != nil {
		return fmt.Errorf("hubtest: keybox data key: %w", err)
	}
	if p.dataKeys == nil {
		p.dataKeys = map[uint32][]byte{}
	}
	p.dataKeys[k.Epoch] = data
	if k.PreviousEpoch != nil && k.PreviousDataKey != nil {
		prev, err := b64.DecodeString(*k.PreviousDataKey)
		if err != nil {
			return fmt.Errorf("hubtest: keybox previous data key: %w", err)
		}
		p.dataKeys[*k.PreviousEpoch] = prev
	}
	p.cfg.MetaKey, p.cfg.Epoch = meta, k.Epoch
	return nil
}

// HoldsEpoch reports whether the phone holds K_data of epoch.
func (p *Phone) HoldsEpoch(epoch uint32) bool { _, ok := p.dataKeys[epoch]; return ok }

// OpenSwitchKeybox opens the keybox a transport_switched carries (phone
// contract point 3: base64url of the sealed keybox-<DEVICE_ID> envelope,
// signed by hub_sig, sealed to this phone's dev_kx).
func (p *Phone) OpenSwitchKeybox(c wire.Control) (wire.Keybox, error) {
	if c.Kind != wire.ControlSwitched || c.Keybox == nil {
		return wire.Keybox{}, errors.New("hubtest: not a transport_switched with a keybox")
	}
	env, err := base64.RawURLEncoding.DecodeString(*c.Keybox)
	if err != nil {
		return wire.Keybox{}, fmt.Errorf("hubtest: switch keybox: %w", err)
	}
	name := "keybox-" + p.id.String()
	_, f, err := secure.OpenHPKE(env, secure.ClassKeybox, p.kx, secure.KeyboxInfo(p.cfg.Hub, p.id),
		secure.Context{Zone: secure.ZoneData, WireName: name}, p.cfg.HubSig)
	if err != nil {
		return wire.Keybox{}, fmt.Errorf("hubtest: opening the switch keybox: %w", err)
	}
	var kb wire.Keybox
	if err := json.Unmarshal(f.Payload, &kb); err != nil {
		return wire.Keybox{}, fmt.Errorf("hubtest: unreadable switch keybox: %w", err)
	}
	return kb, nil
}

// Follow is sim rule 12: the phone takes the keys of a transport_switched
// it read and answers epoch_ack on the store it is on (the caller moves it
// first with Use).
func (p *Phone) Follow(c wire.Control) error {
	kb, err := p.OpenSwitchKeybox(c)
	if err != nil {
		return err
	}
	if kb.Keys == nil {
		return errors.New("hubtest: the switch keybox carries no keys")
	}
	if err := p.Keep(*kb.Keys); err != nil {
		return err
	}
	epoch := kb.Keys.Epoch
	_, err = p.WriteControl(wire.Control{Kind: wire.ControlEpochAck, Epoch: &epoch})
	return err
}

// LastSwitch is the newest transport_switched the phone read, if any.
func (p *Phone) LastSwitch() (wire.Control, bool) {
	for i := len(p.Controls) - 1; i >= 0; i-- {
		if p.Controls[i].Kind == wire.ControlSwitched {
			return p.Controls[i], true
		}
	}
	return wire.Control{}, false
}

// ResendOutbox writes every action still in the outbox again, in order and
// with the same bytes, on the store the phone is on (sim rule 13).
func (p *Phone) ResendOutbox() error {
	for _, s := range p.Outbox() {
		if err := p.Send(s); err != nil {
			return err
		}
	}
	return nil
}

// ReadMarker reads the transport marker (plain transport-marker) of data
// zone on the phone's store, opened only with the data keys the phone
// holds: a marker sealed in an epoch it was never given is an error. ok is
// false when the zone has none.
func (p *Phone) ReadMarker(zone string) (c wire.Control, ok bool, err error) {
	name := secure.RecordName(p.cfg.MetaKey, secure.ZoneData, wire.MarkerKind, "marker")
	var since uint64
	for {
		b, err := p.cfg.Transport.Changes(context.Background(), zone, since)
		if err != nil {
			return wire.Control{}, false, err
		}
		for _, rec := range b.Changed {
			if rec.Name != name {
				continue
			}
			_, f, err := secure.OpenSymmetric(rec.Envelope, []secure.EnvelopeClass{secure.ClassData},
				secure.Context{Zone: secure.ZoneData, WireName: rec.Name}, p.cfg.HubSig,
				func(h secure.Header) ([]byte, error) {
					k, ok := p.dataKeys[h.Epoch]
					if !ok {
						return nil, fmt.Errorf("hubtest: the phone holds no keys of epoch %d", h.Epoch)
					}
					return append([]byte(nil), k...), nil
				})
			if err != nil {
				return wire.Control{}, false, fmt.Errorf("hubtest: opening the transport marker: %w", err)
			}
			if f.ID != wire.MarkerPlain {
				return wire.Control{}, false, secure.ErrNameMismatch
			}
			if err := json.Unmarshal(f.Payload, &c); err != nil {
				return wire.Control{}, false, fmt.Errorf("hubtest: unreadable transport marker: %w", err)
			}
			return c, true, nil
		}
		if !b.More {
			return wire.Control{}, false, nil
		}
		since = b.NewSeq
	}
}
