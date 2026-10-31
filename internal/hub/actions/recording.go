package actions

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// Phone recordings (Go hub spec §8 p. 4a, the Swift RelayProcessor's
// recording_upload path). The upload record is no action: it has a plain name
// recupload-<id>, no order and no handler; the Dispatcher's recording intake
// opens its audio, and the processor rewrites the same record with the
// outcome (status received / failed, error_message), without the asset.

const kindRecordingUpload = "recording_upload"

// RecordingIntake is one recording_upload the processor decoded and
// authenticated: the phone's device, its upload id, the hub it addressed (nil
// = unchecked), the asset's descriptor (from the sealed frame; nil = the
// record carried no asset) and Download, which writes the sealed attachment
// to the given path.
type RecordingIntake struct {
	Device     secure.ID
	UploadID   string
	TargetHub  *secure.ID
	ThisHub    secure.ID
	Descriptor *secure.AssetDescriptor
	Download   func(ctx context.Context, dst string) error
}

// RecordingOutcome is the upload's echo: Status received, held (non-final:
// retried each pass while this process runs) or failed.
type RecordingOutcome struct {
	Status, Reason, Message string
}

// RecordingIntaker opens one upload (handlers.Handlers.IntakeRecording).
type RecordingIntaker func(ctx context.Context, in RecordingIntake) RecordingOutcome

// heldUpload is an upload answered held, kept in memory to be tried again
// every pass. A restart forgets it: the phone's record then reads as held
// (pending to the phone) and the owner sends it again.
type heldUpload struct {
	b          mailbox
	r          record
	o          secure.Opened
	payload    map[string]json.RawMessage
	attachment string
}

func (h *heldUpload) key() string { return h.b.zone + "|" + h.r.name }

func strField(m map[string]json.RawMessage, k string) string {
	var s string
	if raw, ok := m[k]; ok {
		_ = json.Unmarshal(raw, &s)
	}
	return s
}

// recordingUpload handles one phone upload record read from b's mailbox.
func (p *Processor) recordingUpload(ctx context.Context, b mailbox, r record, o secure.Opened, attachment string, ps *pass) error {
	var payload map[string]json.RawMessage
	if !decodes(o.Frame.Payload, &payload) {
		log.Printf("hub: undecodable recording upload of device %s dropped", b.id)
		return nil
	}
	id := strField(payload, "id")
	if id == "" || o.Sender != b.id || o.Frame.ID != "recupload-"+id {
		log.Printf("hub: recording upload of device %s names another record: dropped", b.id)
		return nil
	}
	if strField(payload, "status") != wire.StatusPending {
		return nil
	}
	h := &heldUpload{b: b, r: r, o: o, payload: payload, attachment: attachment}
	delete(p.held, h.key()) // the phone saved it again: a fresh attempt
	return p.settleUpload(ctx, h, ps, false)
}

// retryUploads tries b's held uploads again.
func (p *Processor) retryUploads(ctx context.Context, b mailbox, ps *pass) error {
	for _, h := range p.held {
		if h.b.id != b.id || h.b.link != b.link {
			continue
		}
		if err := p.settleUpload(ctx, h, ps, true); err != nil {
			return err
		}
	}
	return nil
}

// settleUpload decides one upload: the device gate, a stored received
// outcome (the same upload again is answered received, never ingested twice),
// else the intake. A held answer is echoed once and kept for the next pass; a
// final one is ledgered and echoed.
func (p *Processor) settleUpload(ctx context.Context, h *heldUpload, ps *pass, retry bool) error {
	intake, nudges := p.cfg.Dispatcher.recordingIntake()
	if intake == nil {
		return nil // a hub that cannot ingest: the upload stays pending
	}
	b := h.b
	id := strField(h.payload, "id")
	plain := "recupload-" + id
	dev, linked, err := p.cfg.Store.Device(b.id.String())
	if err != nil || !linked {
		return err
	}
	if dev.LinkNonce != b.link {
		return errRelinked
	}
	_, _, stored, err := p.cfg.Store.Phase(plain)
	if err != nil {
		return err
	}
	var out Outcome
	prev, hasPrev := decodeStored(stored)
	hub := p.cfg.Keys.HubID()
	var target *secure.ID
	if raw := strField(h.payload, "hub_id"); raw != "" {
		if t, perr := secure.ParseID(raw); perr == nil {
			target = &t
		} else {
			target = &secure.ID{}
		}
	}
	switch {
	case hasPrev && prev.Status == wire.StatusReceived:
		out = prev
	case !sameDevice(h.payload, b.id):
		out = failed(reasonDeviceNotLinked, notLinkedMessage)
	case target != nil && *target != hub:
		out = failed(reasonWrongHub, wrongHubMessage)
	default:
		var desc *secure.AssetDescriptor
		if d := h.o.Frame.Asset; d != nil {
			c := *d
			desc = &c
			defer clear(c.Key[:])
		}
		in := RecordingIntake{Device: b.id, UploadID: id, TargetHub: target, ThisHub: hub, Descriptor: desc}
		if h.attachment != "" {
			zone, att := b.zone, h.attachment
			in.Download = func(ctx context.Context, dst string) error {
				return p.cfg.Transport.Download(ctx, zone, att, dst)
			}
		}
		ro := intake(ctx, in)
		out = Outcome{Status: ro.Status, Reason: ro.Reason, Message: ro.Message}
	}
	out = normalize(out)
	if retry {
		h.r.expect = expectAbsent
	}
	if out.Status == wire.StatusHeld {
		if retry {
			return nil
		}
		return p.echoUpload(ctx, h, plain, out, false, ps, nil)
	}
	delete(p.held, h.key())
	var nudge []string
	if out.Status == wire.StatusReceived {
		nudge = nudges
	}
	return p.echoUpload(ctx, h, plain, out, true, ps, nudge)
}

// echoUpload rewrites the upload record with out (no asset) and, for a final
// outcome, ledgers it. After a held echo the record is the hub's own, so a
// retry writes under ExpectAbsent (writeQueued then replaces the hub's own
// older echo).
func (p *Processor) echoUpload(ctx context.Context, h *heldUpload, plain string, out Outcome, final bool, ps *pass, nudge []string) error {
	b, r := h.b, h.r
	payload := make(map[string]json.RawMessage, len(h.payload)+1)
	for k, v := range h.payload {
		payload[k] = v
	}
	st, _ := json.Marshal(out.Status)
	payload["status"] = st
	delete(payload, "error_message")
	if out.Message != "" {
		m, _ := json.Marshal(out.Message)
		payload["error_message"] = m
	}
	body, err := wire.Marshal(payload)
	if err != nil {
		return err
	}
	expect := r.expect // after a held echo the record is the hub's own: ExpectAbsent
	rec, err := p.cfg.Sealer.ToPhone(b.zone, b.id, r.name, kindRecordingUpload, plain, body)
	if err != nil {
		return err
	}
	q := queued{rec: rec, kind: queueEcho, expect: expect}
	var echo []byte
	if final {
		if echo, err = encodeStored(out); err != nil {
			return err
		}
	}
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if final {
			if err := state.MarkDone(tx, plain, ledgerOutcome(out), echo, nil, p.cfg.Clock()); err != nil {
				return err
			}
		}
		if err := mark(tx, b, r.name, h.o); err != nil {
			return err
		}
		return state.Enqueue(tx, q.control(b.zone))
	}); err != nil {
		return err
	}
	if !final {
		if p.held == nil {
			p.held = map[string]*heldUpload{}
		}
		p.held[h.key()] = h
	}
	ps.budget--
	ps.report.Applied++
	ps.report.Echoed++
	ps.nudges = append(ps.nudges, nudge...)
	return nil
}

func sameDevice(payload map[string]json.RawMessage, id secure.ID) bool {
	s := strField(payload, "device_id")
	return s != "" && sameID(s, id)
}
