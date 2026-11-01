package hubtest

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// RelayStore is a phone's Records on the hosted relay (the interop run
// against the relay's local stand): the phone's own relay client, a
// DEVICE_KIND_PHONE device signed in with Phone.RelayAuth. It writes the
// bytes the phone sealed as they are — a phone seals for itself, so nothing
// here goes through the hub's Sealer — and adds the phone's account ops
// (open_pairing, promote_pairing). Build it empty, hand it to FromLink, then
// set C from the phone's key. Not safe for concurrent use.
type RelayStore struct {
	C *client.Client
	// Clock stamps client_modified_at_ms (nil = time.Now).
	Clock func() time.Time
}

var _ Records = (*RelayStore)(nil)

// NewPhoneClient is the relay client of phone p at origin.
func NewPhoneClient(origin string, p *Phone, opts ...client.Option) *client.Client {
	return client.New(origin, p.RelayAuth(), relayv1.DeviceKind_DEVICE_KIND_PHONE, opts...)
}

func (s *RelayStore) now() time.Time {
	if s.Clock != nil {
		return s.Clock()
	}
	return time.Now()
}

func (s *RelayStore) do(ctx context.Context, req *relayv1.Request) (*relayv1.Response, error) {
	if s.C == nil {
		return nil, errors.New("hubtest: relay store has no client")
	}
	resp, err := s.C.Do(ctx, req)
	if err != nil {
		return nil, relay.MapError(err)
	}
	return resp, nil
}

// Register registers the phone (idempotent) and returns its account id.
func (s *RelayStore) Register(ctx context.Context) (string, error) {
	if s.C == nil {
		return "", errors.New("hubtest: relay store has no client")
	}
	if _, err := s.C.Register(ctx); err != nil {
		return "", relay.MapError(err)
	}
	return s.C.AccountID(), nil
}

// OpenPairing opens a pairing slot for the hub's relay device id; the hub
// is told by Control{PAIRING_OPENED}. It returns the slot id.
func (s *RelayStore) OpenPairing(ctx context.Context, hubRelayID string) (string, error) {
	resp, err := s.do(ctx, &relayv1.Request{Op: &relayv1.Request_OpenPairing{OpenPairing: &relayv1.OpenPairingSlot{
		MacDeviceId: hubRelayID,
	}}})
	if err != nil {
		return "", fmt.Errorf("hubtest: open_pairing: %w", err)
	}
	slot := resp.GetPairingSlot().GetSlotId()
	if slot == "" {
		return "", errors.New("hubtest: open_pairing: no slot in the answer")
	}
	return slot, nil
}

// VouchHub vouches, as this phone, for the hub with key hubPub (the link
// code's relay_auth_pub) through the relay client's VouchHub: a fresh VOUCH
// challenge, then vouch_hub with no attestation (dev or an exempt device).
// The relay keeps the vouch 10 minutes for the next promote_pairing or
// add_slot of that hub.
func (s *RelayStore) VouchHub(ctx context.Context, hubPub ed25519.PublicKey) error {
	if s.C == nil {
		return errors.New("hubtest: relay store has no client")
	}
	if err := s.C.VouchHub(ctx, hubPub); err != nil {
		return fmt.Errorf("hubtest: vouch_hub: %w", relay.MapError(err))
	}
	return nil
}

// PromotePairing turns the pairing slot into a slot of the phone's account
// holding the hub.
func (s *RelayStore) PromotePairing(ctx context.Context, slot string) error {
	if _, err := s.do(ctx, &relayv1.Request{Op: &relayv1.Request_PromotePairing{PromotePairing: &relayv1.PromotePairing{
		SlotId: slot,
	}}}); err != nil {
		return fmt.Errorf("hubtest: promote_pairing: %w", err)
	}
	return nil
}

func expectOf(item *relayv1.SaveItem, e transport.Expect) error {
	switch e.Mode {
	case transport.ExpectNone:
	case transport.ExpectAbsent:
		item.Expect = &relayv1.SaveItem_MustNotExist{MustNotExist: true}
	case transport.ExpectSeq:
		item.Expect = &relayv1.SaveItem_ExpectedSeq{ExpectedSeq: e.Seq}
	default:
		return fmt.Errorf("hubtest: unknown expect mode %d", e.Mode)
	}
	return nil
}

// Write saves one record the phone sealed.
func (s *RelayStore) Write(zone, name string, env []byte, expect transport.Expect) (transport.Outcome, error) {
	item := &relayv1.SaveItem{Record: &relayv1.Record{
		Zone: zone, Name: name, Envelope: env, ClientModifiedAtMs: s.now().UnixMilli(),
	}}
	if err := expectOf(item, expect); err != nil {
		return transport.Outcome{}, err
	}
	resp, err := s.do(context.Background(), &relayv1.Request{Op: &relayv1.Request_Save{Save: &relayv1.Save{
		Items: []*relayv1.SaveItem{item},
	}}})
	if err != nil {
		return transport.Outcome{}, fmt.Errorf("hubtest: save: %w", err)
	}
	res := resp.GetSave()
	if c := res.GetConflicts(); len(c) > 0 {
		return transport.Outcome{Conflict: storedOf(c[0].GetCurrent())}, nil
	}
	if len(res.GetSaved()) != 1 {
		return transport.Outcome{}, fmt.Errorf("hubtest: save: %d saved for one item", len(res.GetSaved()))
	}
	return transport.Outcome{Saved: true, RecordSeq: res.GetSaved()[0].GetRecordSeq()}, nil
}

// WriteWithAsset is not supported on the relay store (no phone uploads in
// the interop run).
func (s *RelayStore) WriteWithAsset(string, string, []byte, []byte, transport.Expect) (transport.Outcome, error) {
	return transport.Outcome{}, errors.New("hubtest: the relay store writes no attachments")
}

// Changes reads one page of zone after since.
func (s *RelayStore) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	resp, err := s.do(ctx, &relayv1.Request{Op: &relayv1.Request_Changes{Changes: &relayv1.Changes{
		Zone: zone, SinceSeq: since,
	}}})
	if err != nil {
		return transport.Batch{}, fmt.Errorf("hubtest: changes: %w", err)
	}
	page := resp.GetChanges()
	b := transport.Batch{NewSeq: page.GetNewSeq(), More: page.GetMore(), Deleted: page.GetDeleted(), Reset: since == 0}
	for _, r := range page.GetChanged() {
		if r.GetDeleted() {
			b.Deleted = append(b.Deleted, r.GetName())
			continue
		}
		b.Changed = append(b.Changed, *storedOf(r))
	}
	return b, nil
}

// Delete removes records of zone by wire name.
func (s *RelayStore) Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	wire := make([]*relayv1.DeleteItem, len(items))
	for i, it := range items {
		w := &relayv1.DeleteItem{Name: it.Name}
		switch it.Expect.Mode {
		case transport.ExpectNone:
		case transport.ExpectSeq:
			seq := it.Expect.Seq
			w.ExpectedSeq = &seq
		default:
			return nil, fmt.Errorf("hubtest: delete item %d: expect mode %d is not supported", i, it.Expect.Mode)
		}
		wire[i] = w
	}
	resp, err := s.do(ctx, &relayv1.Request{Op: &relayv1.Request_Delete{Delete: &relayv1.Delete{Zone: zone, Items: wire}}})
	if err != nil {
		return nil, fmt.Errorf("hubtest: delete: %w", err)
	}
	out := make([]transport.Outcome, len(items))
	for i := range out {
		out[i] = transport.Outcome{Saved: true}
	}
	for _, c := range resp.GetDelete().GetConflicts() {
		if i := int(c.GetIndex()); i < len(out) {
			out[i] = transport.Outcome{Conflict: storedOf(c.GetCurrent())}
		}
	}
	return out, nil
}

func storedOf(r *relayv1.Record) *transport.Stored {
	if r == nil {
		return nil
	}
	return &transport.Stored{
		Zone: r.GetZone(), Name: r.GetName(), Envelope: r.GetEnvelope(), RecordSeq: r.GetRecordSeq(),
		ServerAt: time.UnixMilli(r.GetClientModifiedAtMs()), AttachmentID: r.GetAttachmentId(),
	}
}
