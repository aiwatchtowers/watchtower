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

// Chat attachments, phone to hub (iPhone chat spec §4.5): the upload record
// is no action, like recording_upload. Its plain name is
// chatupload-<upload_id>; its payload the descriptor {upload_id,
// conversation_id, name, mime, size, device_id, hub_id?, status "pending"}
// with the file as the record's sealed asset. The Dispatcher's chat
// attachment intake opens and stores the file, and the processor rewrites
// the same record with the outcome: status applied with attachment_id, or
// failed with reason and error_message (no asset). An outcome is ledgered
// under the plain name, so the same upload read again after it was stored
// gets the same echo and is never stored twice (a failed one, written again
// by the phone's Retry, is tried again). Nothing is held: a hub that cannot take the
// file answers failed, and the phone keeps the file and offers Retry.

// KindChatAttachment is the upload record's kind.
const KindChatAttachment = "chat_attachment"

// ChatUploadPrefix starts the upload record's plain name.
const ChatUploadPrefix = "chatupload-"

// ChatAttachmentIntake is one decoded, authenticated chat_attachment upload:
// the phone, its upload id, the conversation, the file's name, the mime and
// size the phone declared, the hub it addressed (nil = unchecked), the
// asset's descriptor (nil = the record carried none) and Download, which
// writes the sealed asset to a path (nil = no asset attached).
type ChatAttachmentIntake struct {
	Device         secure.ID
	UploadID       string
	ConversationID int64
	Name, Mime     string
	Size           int64
	TargetHub      *secure.ID
	ThisHub        secure.ID
	Descriptor     *secure.AssetDescriptor
	Download       func(ctx context.Context, dst string) error
}

// ChatAttachmentIntaker stores one upload (handlers.Handlers.
// IntakeChatAttachment): applied with result attachment_id, or failed.
type ChatAttachmentIntaker func(ctx context.Context, in ChatAttachmentIntake) Outcome

// SetChatAttachments installs the chat attachment intake and the slice kinds
// a stored upload refreshes. Without one an upload stays pending.
func (d *Dispatcher) SetChatAttachments(fn ChatAttachmentIntaker, nudges []string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.chatFiles, d.chatNudges = fn, append([]string(nil), nudges...)
}

func (d *Dispatcher) chatAttachmentIntake() (ChatAttachmentIntaker, []string) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.chatFiles, d.chatNudges
}

// chatAttachment handles one phone chat_attachment record read from b's
// mailbox.
func (p *Processor) chatAttachment(ctx context.Context, b mailbox, r record, o secure.Opened, attachment string, ps *pass) error {
	intake, nudges := p.cfg.Dispatcher.chatAttachmentIntake()
	if intake == nil {
		return nil // a hub that cannot take files: the upload stays pending
	}
	var payload map[string]json.RawMessage
	if !decodes(o.Frame.Payload, &payload) {
		log.Printf("hub: undecodable chat attachment of device %s dropped", b.id)
		return nil
	}
	id := strField(payload, "upload_id")
	if !uploadIDOK(id) || o.Sender != b.id || o.Frame.ID != ChatUploadPrefix+id {
		log.Printf("hub: chat attachment of device %s names another record: dropped", b.id)
		return nil
	}
	if strField(payload, "status") != wire.StatusPending {
		return nil
	}
	plain := ChatUploadPrefix + id
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
	hub := p.cfg.Keys.HubID()
	var target *secure.ID
	if raw := strField(payload, "hub_id"); raw != "" {
		if t, perr := secure.ParseID(raw); perr == nil {
			target = &t
		} else {
			target = &secure.ID{}
		}
	}
	var out Outcome
	if prev, ok := decodeStored(stored); ok && prev.Status == wire.StatusApplied {
		out = prev // the same upload again: the same answer, nothing stored twice
	} else {
		switch {
		case !sameDevice(payload, b.id):
			out = failed(reasonDeviceNotLinked, notLinkedMessage)
		case target != nil && *target != hub:
			out = failed(reasonWrongHub, wrongHubMessage)
		case p.uploadNotDelivered(b, r.at):
			out = failed(reasonNotDelivered, notDeliveredUploadMessage)
		default:
			in := ChatAttachmentIntake{Device: b.id, UploadID: id, TargetHub: target, ThisHub: hub,
				Name: strField(payload, "name"), Mime: strField(payload, "mime")}
			in.ConversationID, _ = intField(payload, "conversation_id")
			in.Size, _ = intField(payload, "size")
			if d := o.Frame.Asset; d != nil {
				c := *d
				in.Descriptor = &c
				defer clear(c.Key[:])
			}
			if attachment != "" {
				zone := b.zone
				in.Download = func(ctx context.Context, dst string) error {
					return p.cfg.Transport.Download(ctx, zone, attachment, dst)
				}
			}
			out = intake(ctx, in)
		}
	}
	out = normalize(out)
	return p.echoChatAttachment(ctx, b, r, o, payload, plain, out, ps, nudges)
}

// echoChatAttachment rewrites the upload record with out (no asset) and
// ledgers it, in one transaction with the record's mark.
func (p *Processor) echoChatAttachment(ctx context.Context, b mailbox, r record, o secure.Opened,
	in map[string]json.RawMessage, plain string, out Outcome, ps *pass, nudges []string,
) error {
	payload := make(map[string]json.RawMessage, len(in)+3)
	for k, v := range in {
		if k != "error_message" && k != "reason" && k != "attachment_id" {
			payload[k] = v
		}
	}
	payload["status"], _ = json.Marshal(out.Status)
	if out.Status == wire.StatusFailed {
		if out.Reason != "" {
			payload["reason"], _ = json.Marshal(out.Reason)
		}
		if out.Message != "" {
			payload["error_message"], _ = json.Marshal(out.Message)
		}
	}
	if v, ok := out.Result["attachment_id"]; ok && out.Status == wire.StatusApplied {
		raw, err := json.Marshal(v)
		if err != nil {
			return err
		}
		payload["attachment_id"] = raw
	}
	body, err := wire.Marshal(payload)
	if err != nil {
		return err
	}
	rec, err := p.cfg.Sealer.ToPhone(b.zone, b.id, r.name, KindChatAttachment, plain, body)
	if err != nil {
		return err
	}
	q := queued{rec: rec, kind: queueEcho, expect: r.expect}
	echo, err := encodeStored(out)
	if err != nil {
		return err
	}
	now := p.cfg.Clock()
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := state.MarkDone(tx, plain, ledgerOutcome(out), echo, nil, now); err != nil {
			return err
		}
		if err := mark(tx, b, r.name, o); err != nil {
			return err
		}
		return state.Enqueue(tx, q.control(b.queue))
	}); err != nil {
		return err
	}
	ps.budget--
	ps.report.Applied++
	ps.report.Echoed++
	if out.Status == wire.StatusApplied {
		ps.nudges = append(ps.nudges, nudges...)
	}
	return nil
}

func intField(m map[string]json.RawMessage, k string) (int64, bool) {
	var v int64
	raw, ok := m[k]
	if !ok || json.Unmarshal(raw, &v) != nil {
		return 0, false
	}
	return v, true
}

// uploadIDOK keeps an upload id usable in a record name: the phone's UUID.
func uploadIDOK(id string) bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}
