package link

// Linking over the hosted relay (RC §8 hub half, Go hub spec §7, §10, §12a):
// the phone opens a pairing slot, the hub is told by Control{PairingOpened},
// the phone writes today's sealed hello into pair/<slot> and the hub answers
// there with today's keybox (awaiting, refused, then linked with the keys
// after the owner's confirmation). Caps, refusals and code checks are
// HandleHello's and Confirm's: only the record route changes.
//
// Vouching is the phone's call (vouch_hub, then promote_pairing); the hub
// only follows the server's state (the runtime's gate, internal/hub
// admission.go): everything here touches only pair/<slot> zones, which the
// relay opens to an unvouched hub.
//
// For the runtime (Task 14): call OnPairingOpened on Control{PairingOpened}
// (Detail = the slot) and again on every zone event of a pair/<slot> zone;
// call PublishPairKeyboxes whenever the device_grant slice is published (a
// Confirm, a refusal, an expiry), so the phone learns the outcome in its
// slot; call SyncReaders with relay.Transport.SetLinkedReaders after a link
// change, after the relay's account state changes and on the backstop timer
// — a phone becomes a reader only once promote_pairing put the hub in its
// slots (the relay's SLOT_ADDED is best effort) — and only while the hub is
// vouched: set_hub_readers is closed to an unvouched hub.

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"slices"
	"strings"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

const (
	// pairSlotLifetime: how long the hub answers in a slot it was told
	// about (the relay's pairing slots live 600 s, as the link code).
	pairSlotLifetime = wire.LinkLifetime
	// maxPairSlots: slots remembered at once; the oldest is forgotten first.
	maxPairSlots = 16
)

// pairSlot is one pairing slot the hub reads: when it was opened, how far
// its zone was read, and the phones whose hellos came through it.
type pairSlot struct {
	opened  time.Time
	cursor  uint64
	devices []string
	watched bool
}

// pairWatcher is the hosted relay's subscription to a pair zone
// (relay.Transport.WatchPairZone); a transport without it sends every zone's
// events anyway (memfake).
type pairWatcher interface {
	WatchPairZone(ctx context.Context, slot string) error
}

// HeadlessHost is the HostInfo of a headless host: relay only (never
// cloudkit, spec §7.3) and the relay identity of its relay_auth key — the
// relay_device_id and the base64url public key a phone vouches for.
func HeadlessHost(name string, relayAuth ed25519.PublicKey) HostInfo {
	return HostInfo{
		Name: name, Transports: []string{wire.TransportRelay},
		RelayDeviceID: identity.RelayDeviceID(relayAuth),
		RelayAuthPub:  base64.RawURLEncoding.EncodeToString(relayAuth),
	}
}

// OnPairingOpened reads the hellos written into pair/<slot> since the last
// read and answers each in the zone with the phone's keybox. A hello that
// HandleHello drops gets no answer; a zone with no hello yet is no error
// (the phone writes it after opening the slot: call again on the zone's
// event). The hub's own keybox records are skipped, so its writes never make
// it answer again. On the hosted relay it subscribes the zone, retrying on
// each call until the subscription succeeds.
func (c *Center) OnPairingOpened(ctx context.Context, t transport.Transport, slot string) error {
	if slot == "" || strings.Contains(slot, "/") {
		return errors.New("link: not a pairing slot id")
	}
	zone := transport.PairZone(slot)
	c.pairMu.Lock()
	c.prunePairSlots()
	s := c.pairs[slot]
	if s == nil {
		s = &pairSlot{opened: c.clock()}
		c.pairs[slot] = s
		c.prunePairSlots()
	}
	since, watched := s.cursor, s.watched
	c.pairMu.Unlock()
	if w, ok := t.(pairWatcher); ok && !watched {
		if err := w.WatchPairZone(ctx, slot); err != nil {
			log.Printf("hub link: pair zone not subscribed (%s): retried on the next call", transportClass(err))
		} else {
			c.pairMu.Lock()
			if cur := c.pairs[slot]; cur != nil {
				cur.watched = true
			}
			c.pairMu.Unlock()
		}
	}
	var hellos []transport.Stored
	newSeq, err := readZone(ctx, t, zone, since, func(b transport.Batch) {
		for _, r := range b.Changed {
			if strings.HasPrefix(r.Name, "hello-") {
				hellos = append(hellos, r)
			}
		}
	})
	if err != nil {
		return fmt.Errorf("link: reading the pair zone: %w", err)
	}
	var (
		answered []string
		failed   error
	)
	for _, h := range hellos {
		p, err := c.HandleHello(zone, h.Name, h.Envelope)
		if errors.Is(err, ErrHelloDropped) {
			continue
		}
		if err != nil {
			// The hellos decided so far are still answered below; the
			// cursor stays, so the batch is read again (a decided hello
			// re-read changes nothing).
			failed = err
			break
		}
		if !p.Unanswered {
			answered = append(answered, strings.ToUpper(p.DeviceID))
		}
	}
	c.pairMu.Lock()
	if cur := c.pairs[slot]; cur != nil {
		if failed == nil {
			// Replaced, never max'ed: after a TOKEN_EXPIRED resync of a
			// rebuilt zone the new cursor can be lower than the old one.
			cur.cursor = newSeq
		}
		for _, d := range answered {
			if !slices.Contains(cur.devices, d) {
				cur.devices = append(cur.devices, d)
			}
		}
	}
	c.pairMu.Unlock()
	if len(hellos) > 0 {
		log.Printf("hub link: pair zone: %d hellos read, %d answered", len(hellos), len(answered))
	}
	return errors.Join(failed, c.writePairKeyboxes(ctx, t, zone, answered))
}

// PublishPairKeyboxes writes, in every pairing slot still open, the current
// keybox of each phone whose hello came through it: after Confirm it carries
// the keys, after a refusal or an expiry the reason. Every open slot's boxes
// are rewritten on each publish: bounded by maxPairSlots slots of at most
// MaxGrantRecords phones each, and only within pairSlotLifetime.
func (c *Center) PublishPairKeyboxes(ctx context.Context, t transport.Transport) error {
	c.pairMu.Lock()
	c.prunePairSlots()
	todo := map[string][]string{}
	for slot, s := range c.pairs {
		if len(s.devices) > 0 {
			todo[slot] = slices.Clone(s.devices)
		}
	}
	c.pairMu.Unlock()
	var errs []error
	for slot, devices := range todo {
		errs = append(errs, c.writePairKeyboxes(ctx, t, transport.PairZone(slot), devices))
	}
	return errors.Join(errs...)
}

// writePairKeyboxes seals the device_grant keybox of each of devices that the
// slice holds and saves them into zone (overwriting), in one call.
func (c *Center) writePairKeyboxes(ctx context.Context, t transport.Transport, zone string, devices []string) error {
	if len(devices) == 0 {
		return nil
	}
	boxes, err := c.Keyboxes()
	if err != nil {
		return err
	}
	var items []transport.SaveItem
	for _, kb := range boxes {
		if !slices.Contains(devices, strings.ToUpper(kb.Grant.DeviceID)) {
			continue
		}
		id, err := secure.ParseID(kb.Grant.DeviceID)
		if err != nil {
			return fmt.Errorf("link: keybox device id: %w", err)
		}
		payload, err := wire.Marshal(kb)
		if err != nil {
			return fmt.Errorf("link: encoding a keybox: %w", err)
		}
		rec, err := c.sealer.Keybox(zone, id, payload)
		clear(payload)
		if err != nil {
			return fmt.Errorf("link: sealing a keybox: %w", err)
		}
		items = append(items, transport.SaveItem{Record: rec})
	}
	if len(items) == 0 {
		return nil
	}
	out, err := t.Save(ctx, items)
	if err != nil {
		return fmt.Errorf("link: writing keyboxes to the pair zone: %w", err)
	}
	for _, o := range out {
		if o.Refused != nil {
			return fmt.Errorf("link: a pair-zone keybox was refused: %w", o.Refused)
		}
		if !o.Saved {
			return errors.New("link: a pair-zone keybox was not saved")
		}
	}
	return nil
}

// prunePairSlots forgets slots past pairSlotLifetime and, beyond
// maxPairSlots, the oldest. Call with c.pairMu held.
func (c *Center) prunePairSlots() {
	now := c.clock()
	for slot, s := range c.pairs {
		if now.Sub(s.opened) > pairSlotLifetime {
			delete(c.pairs, slot)
		}
	}
	for len(c.pairs) > maxPairSlots {
		oldest := ""
		for slot, s := range c.pairs {
			if oldest == "" || s.opened.Before(c.pairs[oldest].opened) {
				oldest = slot
			}
		}
		delete(c.pairs, oldest)
	}
}

// readZone reads zone's changes after since page by page into apply and
// returns the cursor after the last page; an expired cursor reads the zone
// again from 0, once.
func readZone(ctx context.Context, t transport.Transport, zone string, since uint64, apply func(transport.Batch)) (uint64, error) {
	resynced := false
	for {
		b, err := t.Changes(ctx, zone, since)
		if errors.Is(err, transport.ErrTokenExpired) && !resynced && since != 0 {
			since, resynced = 0, true
			continue
		}
		if err != nil {
			return 0, err
		}
		apply(b)
		since = b.NewSeq
		if !b.More {
			return since, nil
		}
	}
}

// SyncReaders hands the relay device ids of the linked phones, sorted, to
// set (relay.Transport.SetLinkedReaders, i.e. set_hub_readers): a phone
// becomes a reader of the data zone once linked and stops being one when
// unlinked. A phone linked without a relay id (the CloudKit route) is left
// out. Syncs run one at a time, so an older set never lands after a newer
// one; set's error is returned and the caller syncs again on its next pass.
func (c *Center) SyncReaders(ctx context.Context, set func(context.Context, []string) error) error {
	c.readersMu.Lock()
	defer c.readersMu.Unlock()
	devices, err := c.st.Devices()
	if err != nil {
		return fmt.Errorf("link: reading the linked phones: %w", err)
	}
	ids := make([]string, 0, len(devices))
	for _, d := range devices {
		if d.RelayDeviceID != "" {
			ids = append(ids, d.RelayDeviceID)
		}
	}
	slices.Sort(ids)
	ids = slices.Compact(ids)
	if err := set(ctx, ids); err != nil {
		return fmt.Errorf("link: setting the hub's readers: %w", err)
	}
	return nil
}

// transportClass is a transport error's class for the log, never its text.
func transportClass(err error) string {
	for _, s := range []error{transport.ErrUnavailable, transport.ErrForbidden, transport.ErrEntitlementInactive,
		transport.ErrRateLimited, transport.ErrUnsupportedVersion, transport.ErrNotVouched, context.Canceled, context.DeadlineExceeded} {
		if errors.Is(err, s) {
			return s.Error()
		}
	}
	return "other"
}
