package relay

import (
	"context"
	"errors"
	"fmt"
	"os"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// The relay's size limits (relay design §8, relay v1 plan Tasks 6 and 9).
const (
	// maxRecordBytes is the relay's cap on one record's sealed envelope
	// (MaxRecordBytes = 1 MiB); a bigger record is refused
	// RECORD_TOO_LARGE, so Save refuses it alone without sending it. The
	// Sealer makes none (secure.MaxEnvelopeBytes is smaller): this guards
	// the relay's contract, not a case the hub produces today.
	maxRecordBytes = 1 << 20
	// saveRequestBudget caps the estimated encoded size of one save
	// request. The relay reads at most MaxRecordBytes + 64 KiB of an op body
	// (POST /v1/op) and refuses a bigger one RECORD_TOO_LARGE as a whole
	// (#1760: one save per slice kind, several MiB, failed every publish
	// cycle). 960 KiB keeps 128 KiB under that cap for the estimate's slack;
	// a lone record over the budget (up to maxRecordBytes) still goes alone
	// and stays under the cap.
	saveRequestBudget = 960 << 10
	// saveItemOverhead over-counts an item's field tag and length prefix in
	// the request plus its share of the Request/Save wrappers.
	saveItemOverhead = 16
	// attachmentIDSlack is the room kept for an attachment id the upload
	// fills in after the request was sized.
	attachmentIDSlack = 256
)

// saveCost is w's estimated share of a save request's encoded size, over
// counted by saveItemOverhead (an attachment id is added on top).
func saveCost(w *relayv1.SaveItem) int { return proto.Size(w) + saveItemOverhead }

// saveWire is one item on its way to the relay: its index in Save's items
// and its wire form.
type saveWire struct {
	item int
	w    *relayv1.SaveItem
}

// Save implements transport.Transport. Before any I/O it refuses the whole
// call with secure.ErrUnsealed when a record did not come from the Sealer or
// carries an asset file outside Options.AssetDir. Per item, before any I/O,
// it refuses an envelope over the relay's 1 MiB with
// transport.ErrRecordTooLarge and an asset in a pairing zone with
// transport.ErrForbidden (the relay allows none there).
//
// The rest goes in consecutive save requests of at most saveRequestBudget
// (#1760), in the items' order. Per request, each asset is uploaded first
// (create_upload, then a PUT of the sealed file to the opaque URL; an
// attachment over the relay's limit refuses that item alone), then the
// records are saved with their attachment ids. A request the relay still
// refuses RECORD_TOO_LARGE as a whole is halved and each half sent in its
// place; a record refused so alone gets that refusal. Any other failure — the
// relay's answer (a quota), a dropped connection or an unreachable relay, ctx
// ending because the host stops — fails the whole call, as the CloudKit
// client does: earlier requests may already have saved their items, and the
// caller saves the whole batch again (a save is an idempotent re-write; a
// conditional row that already landed comes back as a conflict on the hub's
// own envelope). A
// restart mid-way leaves the same state. A refused save request also emits a
// zone event per zone in it and re-reads those zones: the relay may have
// written part of it.
func (t *Transport) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	assets := make([]*os.File, len(items))
	defer func() {
		for _, f := range assets {
			if f != nil {
				_ = f.Close()
			}
		}
	}()
	out := make([]transport.Outcome, len(items))
	var (
		chunks [][]saveWire
		cur    []saveWire
		size   int
	)
	for i, it := range items {
		r := it.Record
		if !r.Sealed() {
			return nil, fmt.Errorf("relay: save item %d: %w", i, secure.ErrUnsealed)
		}
		w := &relayv1.SaveItem{Record: &relayv1.Record{
			Zone: r.Zone(), Name: r.WireName(), Envelope: r.Envelope(), ClientModifiedAtMs: t.o.Clock().UnixMilli(),
		}}
		if err := wireExpect(w, it.Expect); err != nil {
			return nil, fmt.Errorf("relay: save item %d: %w", i, err)
		}
		if n := len(r.Envelope()); n > t.recordCap {
			out[i] = transport.Outcome{Refused: fmt.Errorf("relay: record of %d bytes over the relay's %d: %w", n, t.recordCap, transport.ErrRecordTooLarge)}
			continue
		}
		n := saveCost(w)
		if p := r.AssetPath(); p != "" {
			if isPairZone(r.Zone()) {
				out[i] = transport.Outcome{Refused: fmt.Errorf("relay: attachment in a pairing zone: %w", transport.ErrForbidden)}
				continue
			}
			f, err := t.openAsset(p)
			if err != nil {
				return nil, fmt.Errorf("relay: save item %d: %w", i, err)
			}
			assets[i] = f
			n += attachmentIDSlack
		}
		if len(cur) > 0 && size+n > t.requestBudget {
			chunks, cur, size = append(chunks, cur), nil, 0
		}
		cur, size = append(cur, saveWire{item: i, w: w}), size+n
	}
	if len(cur) > 0 {
		chunks = append(chunks, cur)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	err := t.saveChunks(ctx, chunks, assets, out)
	// Items saved before a failure are noted as the hub's own all the same,
	// so their change events are not taken for another device's.
	for i, it := range items {
		if out[i].Saved {
			t.noteOwn(it.Record.Zone(), out[i].RecordSeq)
		}
	}
	if err != nil {
		return nil, err
	}
	if f := t.observed(); f != nil {
		for i, it := range items {
			switch o := out[i]; {
			case o.Saved:
				f(it.Record.Zone(), nil)
			case o.Refused != nil:
				f(it.Record.Zone(), o.Refused)
			}
		}
	}
	return out, nil
}

// saveChunks sends chunks in order and fills out, with Save's halving rule.
// Any failure other than RECORD_TOO_LARGE fails the whole call; requests sent
// before it may have saved their items (out shows which).
func (t *Transport) saveChunks(ctx context.Context, chunks [][]saveWire, assets []*os.File, out []transport.Outcome) error {
	for len(chunks) > 0 {
		c := chunks[0]
		chunks = chunks[1:]
		zones, err := []string(nil), ctx.Err()
		if err == nil {
			zones, err = t.saveChunk(ctx, c, assets, out)
		}
		switch {
		case err == nil:
		case errors.Is(err, transport.ErrRecordTooLarge) && len(c) > 1:
			h := len(c) / 2
			chunks = append([][]saveWire{c[:h], c[h:]}, chunks...)
		case errors.Is(err, transport.ErrRecordTooLarge):
			out[c[0].item] = transport.Outcome{Refused: fmt.Errorf("relay: save: %w", err)}
		default:
			if f := t.observed(); f != nil {
				// A whole-call refusal names every zone of the refused
				// request; the hub's mailbox writes save one mailbox's
				// queue per call (actions/control.go), so a mailbox quota
				// is never put on another phone's mailbox.
				for _, z := range zones {
					f(z, err)
				}
			}
			return fmt.Errorf("relay: save: %w", err)
		}
	}
	return nil
}

// saveChunk uploads c's assets and saves its records in one request, filling
// out. An item whose attachment the relay refuses as too large is refused
// alone and left out. On an error zones names the zones of a save request
// the relay refused (nil when none was sent); those zones are re-read.
func (t *Transport) saveChunk(ctx context.Context, c []saveWire, assets []*os.File, out []transport.Outcome) (zones []string, err error) {
	wire := make([]*relayv1.SaveItem, 0, len(c))
	index := make([]int, 0, len(c)) // wire position → item index
	for _, s := range c {
		if out[s.item].Refused != nil {
			continue
		}
		if f := assets[s.item]; f != nil && s.w.GetRecord().GetAttachmentId() == "" {
			id, err := t.upload(ctx, s.w.GetRecord().GetZone(), f)
			if err != nil {
				err = fmt.Errorf("item %d: upload: %w", s.item, err)
				if errors.Is(err, transport.ErrRecordTooLarge) {
					out[s.item] = transport.Outcome{Refused: fmt.Errorf("relay: save: %w", err)}
					continue
				}
				return nil, err
			}
			s.w.Record.AttachmentId = id
		}
		wire = append(wire, s.w)
		index = append(index, s.item)
	}
	if len(wire) == 0 {
		return nil, nil
	}
	resp, err := t.do(ctx, &relayv1.Request{Op: &relayv1.Request_Save{Save: &relayv1.Save{Items: wire}}})
	if err != nil {
		zones = make([]string, len(wire))
		for k, w := range wire {
			zones[k] = w.GetRecord().GetZone()
		}
		t.rereadZones(zones)
		return zones, err
	}
	return nil, saveOutcomes(resp.GetSave(), index, out)
}
