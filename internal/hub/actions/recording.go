package actions

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"

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

// expiredUploadMessage answers an upload held HeldUploadMaxAge (protocol
// §7.7): the phone keeps its audio on every failed.
const expiredUploadMessage = "Your Mac's transcriber did not run for 7 days. Your recording stays on your phone."

// heldUpload is an upload answered held, kept in memory to be tried again
// every pass. Its hold is also a held_uploads row (ids and the first hold's
// time), so a restarted hub still expires it, or fails it when the switch
// goes off: it then reads the upload back from its own held echo
// (recoverHeld). A restart otherwise leaves it held until the phone sends it
// again.
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

// retryUploads tries b's held uploads again, then settles the held_uploads
// rows a restart left without a memory entry once they are due.
func (p *Processor) retryUploads(ctx context.Context, b mailbox, ps *pass) error {
	for _, h := range p.held {
		if h.b.id != b.id || h.b.link != b.link {
			continue
		}
		if err := p.settleUpload(ctx, h, ps, true); err != nil {
			return err
		}
	}
	return p.recoverHeld(ctx, b, ps)
}

// recoverHeld finds b's held uploads with no memory entry (the hub restarted
// since it held them) that are due: held HeldUploadMaxAge, or the recording
// switch is off. It reads each one's record back, the hub's own held echo
// (it carries the phone's payload), and settles it like a retry: the final
// failed echo. The echo has to be read back, not built from the row: the
// phone decodes started_at, ended_at, duration_sec and sample_format as
// required keys, and the sidecar keeps ids only. It counts against the
// pass's budget (errBudget past it; the rest is settled next pass). A due upload whose record is gone is settled without an
// echo; one the phone wrote again is left to the mailbox read.
func (p *Processor) recoverHeld(ctx context.Context, b mailbox, ps *pass) error {
	rows, err := p.cfg.Store.HeldUploads()
	if err != nil || len(rows) == 0 {
		return err
	}
	on, _, err := p.cfg.Store.Recordings()
	if err != nil {
		return err
	}
	inMemory := map[string]bool{}
	for _, h := range p.held {
		if h.b.id == b.id {
			inMemory[strField(h.payload, "id")] = true
		}
	}
	now := p.cfg.Clock()
	due := map[string]string{} // wire name -> upload id
	outcome := map[string]string{}
	for _, r := range rows {
		if !strings.EqualFold(r.DeviceID, b.id.String()) || inMemory[r.UploadID] {
			continue
		}
		switch {
		case now.Sub(r.HeldAt) >= state.HeldUploadMaxAge:
			outcome[r.UploadID] = state.HeldExpired
		case !on:
			outcome[r.UploadID] = state.HeldNotSupported
		default:
			continue
		}
		name, err := p.cfg.Sealer.WireName(secure.ZoneRelay, "recupload-"+r.UploadID)
		if err != nil {
			return err
		}
		due[name] = r.UploadID
	}
	if len(due) == 0 {
		return nil
	}
	if ps.budget <= 0 {
		ps.report.Remaining += len(due)
		return errBudget
	}
	found, rewritten, err := p.readHeldEchoes(ctx, b, due)
	if err != nil {
		return err
	}
	left := len(found)
	for _, h := range found {
		if ps.budget <= 0 {
			// The rest stay held rows: the next pass settles them.
			ps.report.Remaining += left
			return errBudget
		}
		if err := p.settleUpload(ctx, h, ps, true); err != nil {
			return err
		}
		left--
	}
	gone := 0
	err = p.cfg.Store.WithTx(ctx, func(tx *sql.Tx) error {
		for name, id := range due {
			if _, ok := found[name]; ok || rewritten[name] {
				continue
			}
			gone++
			if err := state.SettleHeldUpload(tx, id, outcome[id], now); err != nil {
				return err
			}
		}
		return nil
	})
	if gone > 0 {
		log.Printf("hub: %d held recording uploads of device %s settled without their record", gone, b.id)
	}
	return err
}

// readHeldEchoes reads b's mailbox from the start (the stored token stays)
// for the records named in due: found is each one still the hub's own held
// echo, rewritten each one the phone wrote again.
func (p *Processor) readHeldEchoes(ctx context.Context, b mailbox, due map[string]string) (map[string]*heldUpload, map[string]bool, error) {
	found, rewritten := map[string]*heldUpload{}, map[string]bool{}
	var since uint64
	for {
		batch, err := p.cfg.Transport.Changes(ctx, b.zone, since)
		if err != nil {
			return nil, nil, fmt.Errorf("actions: reading held uploads back: %w", err)
		}
		for _, rec := range batch.Changed {
			id, ok := due[rec.Name]
			if !ok {
				continue
			}
			delete(found, rec.Name) // a later change of the same record wins
			delete(rewritten, rec.Name)
			o, err := p.cfg.Opener.OwnEcho(b.zone, rec.Name, rec.Envelope)
			if errors.Is(err, secure.ErrWrongClass) || errors.Is(err, secure.ErrWrongSender) {
				rewritten[rec.Name] = true // the phone's own record: the mailbox read answers it
				continue
			}
			if err != nil {
				if droppable(err) {
					continue
				}
				return nil, nil, err
			}
			var payload map[string]json.RawMessage
			if o.Frame.Kind != kindRecordingUpload || o.Frame.ID != "recupload-"+id || !decodes(o.Frame.Payload, &payload) ||
				strField(payload, "status") != wire.StatusHeld {
				continue
			}
			found[rec.Name] = &heldUpload{b: b, r: record{name: rec.Name, env: rec.Envelope, expect: expectAbsent}, o: o, payload: payload}
		}
		for _, name := range batch.Deleted {
			delete(found, name)
			delete(rewritten, name)
		}
		since = batch.NewSeq
		if !batch.More {
			return found, rewritten, nil
		}
	}
}

// heldOutcome is held_uploads.outcome for a final answer.
func heldOutcome(o Outcome) string {
	switch {
	case o.Status == wire.StatusReceived:
		return state.HeldReceived
	case o.Reason == ReasonNotSupported:
		return state.HeldNotSupported
	case o.Reason == reasonExpired:
		return state.HeldExpired
	}
	return state.HeldFailed
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
	heldAt, held, err := p.cfg.Store.HeldAt(id)
	if err != nil {
		return err
	}
	switch {
	case hasPrev && prev.Status == wire.StatusReceived:
		out = prev
	case !sameDevice(h.payload, b.id):
		out = failed(reasonDeviceNotLinked, notLinkedMessage)
	case target != nil && *target != hub:
		out = failed(reasonWrongHub, wrongHubMessage)
	case held && p.cfg.Clock().Sub(heldAt) >= state.HeldUploadMaxAge:
		out = failed(reasonExpired, expiredUploadMessage)
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
	// The class of a failure (protocol §9): received and held carry none.
	delete(payload, "reason")
	if out.Status == wire.StatusFailed && out.Reason != "" {
		r, _ := json.Marshal(out.Reason)
		payload["reason"] = r
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
	uploadID, now := strField(h.payload, "id"), p.cfg.Clock()
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if final {
			if err := state.MarkDone(tx, plain, ledgerOutcome(out), echo, nil, now); err != nil {
				return err
			}
			if err := state.SettleHeldUpload(tx, uploadID, heldOutcome(out), now); err != nil {
				return err
			}
		} else if err := state.HoldUpload(tx, uploadID, b.id.String(), now); err != nil {
			return err
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
