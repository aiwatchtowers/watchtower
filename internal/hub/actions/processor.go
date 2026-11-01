package actions

import (
	"context"
	"errors"
	"fmt"
	"log"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
)

// Config wires a Processor: the sidecar, the transport, the sealing choke
// point and the Opener (the rollback guard it checks is the sidecar's
// relay_seen, which this package writes), the hub's keys, the handlers, the
// hub's relay device id (the mailboxes are relay/<HubRelayID>/<phone>), the
// clock (nil = time.Now) and an optional nudge called after a pass with the
// Nudges of the kinds it applied.
type Config struct {
	Store      *state.Store
	Transport  transport.Transport
	Sealer     *secure.Sealer
	Opener     *secure.Opener
	Keys       secure.KeySource
	Dispatcher *Dispatcher
	HubRelayID string
	Clock      func() time.Time
	Nudge      func(kinds []string)
	// Links applies the phones' device records (device_record.go); nil
	// leaves them alone.
	Links Links
}

// Processor reads the phones' mailboxes and applies their actions. Pass and
// FlushControls are single-flight: one runs at a time.
type Processor struct {
	cfg Config
	mu  sync.Mutex
	// fault, when set (tests), is called at named points; an error stops
	// the pass there as a crash would: "opened" after a record opened and
	// before any decision commits, "done" inside the done transaction just
	// before its commit (the transaction then rolls back).
	fault func(point string) error
	// held is the uploads answered held, tried again each pass (recording.go).
	held map[string]*heldUpload
	// batch, when set (tests), replaces BatchLimit as a pass's budget.
	batch int
	// paused (SetPaused) is read under mu by every transport-facing entry.
	paused atomic.Bool
}

// SetPaused pauses the processor (spec §7.3, a headless hub with no paying
// phone) or ends the pause. A paused Pass, FlushControls and Hygiene read
// and write nothing and return at once; a LateEcho records its outcome and
// queues the echo, which the first pass after the pause writes. The ledger,
// the held actions and the control queue stay as they are. SetPaused(true)
// returns once a pass already running has ended.
func (p *Processor) SetPaused(on bool) {
	p.paused.Store(on)
	if on {
		p.mu.Lock()
		p.mu.Unlock() //nolint:staticcheck // SA2001: only waits for the running pass
	}
}

// PassReport counts one pass: phone records read (opened), actions applied
// (a final outcome committed, handler or not), repeats echoed again, actions
// held, echoes queued, queued rows written, and phone records left for the
// next pass by BatchLimit (> 0 means "run again now").
type PassReport struct {
	Read, Applied, Repeats, Held, Echoed, ControlsWritten int
	Remaining                                             int
}

// NewProcessor returns a processor over c.
func NewProcessor(c Config) *Processor {
	if c.Clock == nil {
		c.Clock = time.Now
	}
	return &Processor{cfg: c}
}

// mailbox is one linked phone's mailbox, read under one link: zone is where
// its records live (its own relay/<hub>/<phone>, or the one shared mailbox on
// CloudKit), queue its control_queue key (the zone, or zone@<device> in a
// shared mailbox, so one phone's flush never meets another's rows), link the
// link's nonce (a re-link changes it) and linkedAt keys the ledger.
type mailbox struct {
	id       secure.ID
	zone     string
	queue    string
	link     string
	linkedAt time.Time
}

// ledger is an action's relay_processed key: its plain name scoped to this
// link. A re-link restarts the phone's action_seq at 1, so a-<device>-1 of the
// new link must never meet the old link's ledger row (which would answer it
// with the old outcome, or outcome_unknown, without applying it).
func (b mailbox) ledger(plain string) string {
	return plain + "@" + strconv.FormatInt(b.linkedAt.UnixMilli(), 10)
}

// ledgerKey is the relay_processed key of action plain: an ordered action's
// (seq > 0) is scoped to the link; a legacy action's (seq 0) is its plain
// action-<uuid> name, unique across links and the key the Swift hub's ledger
// used, so an adopted ledger still answers its records.
func (b mailbox) ledgerKey(plain string, seq uint64) string {
	if seq == 0 {
		return plain
	}
	return b.ledger(plain)
}

// mailboxes lists the linked phones that have a mailbox, oldest link first:
// on CloudKit every linked phone (the shared RelayZone needs no relay device
// id), elsewhere the phones with a relay device id.
func (p *Processor) mailboxes() ([]mailbox, error) {
	devices, err := p.cfg.Store.Devices()
	if err != nil {
		return nil, err
	}
	shared := transport.SharedMailboxZone(p.cfg.HubRelayID)
	var out []mailbox
	for _, d := range devices {
		zone, ok := p.mailboxZone(d)
		if !ok {
			continue
		}
		id, err := secure.ParseID(d.ID)
		if err != nil {
			log.Printf("hub: a linked device id is not a UUID")
			continue
		}
		queue := zone
		if zone == shared {
			queue = zone + "@" + id.String()
		}
		out = append(out, mailbox{id: id, zone: zone, queue: queue, link: d.LinkNonce, linkedAt: d.LinkedAt})
	}
	return out, nil
}

// mailboxZone is d's mailbox zone: the transport's (transport.SharedMailbox)
// or relay/<hub>/<relay device id>; ok is false for a phone without a relay
// device id on a transport other than CloudKit.
func (p *Processor) mailboxZone(d state.Device) (string, bool) {
	sm, named := p.cfg.Transport.(transport.SharedMailbox)
	switch {
	case named && p.cfg.Transport.Kind() == transport.KindCloudKit:
		return sm.MailboxFor(p.cfg.HubRelayID, d.RelayDeviceID), true
	case d.RelayDeviceID == "":
		return "", false
	case named:
		return sm.MailboxFor(p.cfg.HubRelayID, d.RelayDeviceID), true
	}
	return transport.MailboxZone(p.cfg.HubRelayID, d.RelayDeviceID), true
}

// zoneGroup is one mailbox zone and the phones whose mailbox it is: one on
// the hosted relay, every phone of the hub on CloudKit's shared RelayZone.
type zoneGroup struct {
	zone  string
	boxes []mailbox
}

// byZone groups boxes by zone, in the order the zones first appear.
func byZone(boxes []mailbox) []zoneGroup {
	var out []zoneGroup
	at := map[string]int{}
	for _, b := range boxes {
		i, ok := at[b.zone]
		if !ok {
			i = len(out)
			at[b.zone] = i
			out = append(out, zoneGroup{zone: b.zone})
		}
		out[i].boxes = append(out[i].boxes, b)
	}
	return out
}

// box is the phone of g whose device id is id.
func (g zoneGroup) box(id secure.ID) (mailbox, bool) {
	for _, b := range g.boxes {
		if b.id == id {
			return b, true
		}
	}
	return mailbox{}, false
}

// pass carries one pass's counters and budget.
type pass struct {
	report PassReport
	budget int
	nudges []string
}

// Pass reads every linked phone's mailbox from its stored change token,
// handles each record, then writes the control queue. It is called on each
// transport event and by the runtime's backstop timer. A zone's token is
// stored only once every record of the page was handled, so a pass that
// stops (an error, a crash, the batch limit) re-reads from the old token
// and the ledger makes the re-read safe.
func (p *Processor) Pass(ctx context.Context) (PassReport, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	ps := &pass{budget: BatchLimit}
	if p.batch > 0 {
		ps.budget = p.batch
	}
	if p.paused.Load() {
		return ps.report, nil
	}
	boxes, err := p.mailboxes()
	if err != nil {
		return ps.report, err
	}
	var errs []error
	// Held actions that are next in line first: a drain an earlier pass
	// left at the batch limit (or a crash) resumes here. A zone with a
	// phone whose drain stopped is read next pass.
	stopped := map[string]bool{}
	for _, b := range boxes {
		err := p.drainHeld(ctx, b, ps)
		if err == nil {
			err = p.retryUploads(ctx, b, ps)
		}
		if err != nil {
			stopped[b.zone] = true
			errs = passError(b, err, errs)
		}
	}
	// Each zone once: on CloudKit the one RelayZone for every phone.
	for _, g := range byZone(boxes) {
		if stopped[g.zone] {
			continue
		}
		if b, err := p.readZone(ctx, g, ps); err != nil {
			errs = passError(b, err, errs)
		}
	}
	written, _, err := p.flushAll(ctx)
	ps.report.ControlsWritten = written
	p.nudge(ps)
	return ps.report, errors.Join(append(errs, err)...)
}

// passError logs the error that stopped b's phone (or a zone read at one of
// b's records) and adds it to errs. The batch limit and a re-link are no
// errors: the rest is read next pass (Remaining counts the first).
func passError(b mailbox, err error, errs []error) []error {
	switch {
	case errors.Is(err, errBudget):
		return errs
	case errors.Is(err, errRelinked):
		log.Printf("hub: device %s was re-linked or unlinked during a pass: its mailbox is read again next pass", b.id)
		return errs
	}
	// One phone's failure never holds back the other phones' own work.
	log.Printf("hub: reading device %s's mailbox: %s", b.id, errClass(err))
	return append(errs, err)
}

func (p *Processor) nudge(ps *pass) {
	if p.cfg.Nudge == nil || len(ps.nudges) == 0 {
		return
	}
	slices.Sort(ps.nudges)
	p.cfg.Nudge(slices.Compact(ps.nudges))
}

// Puller is a transport that keeps its zone tokens itself (the hosted
// relay's Pull): apply sees each page and the token moves only after apply
// returned nil; TOKEN_EXPIRED pulls the zone again from 0, once. The
// processor uses it whenever the transport has it, so a zone has one cursor
// owner; otherwise pull does the same over Changes and the sidecar's
// zone_tokens.
type Puller interface {
	Pull(ctx context.Context, zone string, apply func(transport.Batch) error) error
}

// errBudget stops a pull at BatchLimit: the page's token is not stored, so
// the rest comes back next pass.
var errBudget = errors.New("actions: batch limit reached")

// pull reads zone's changes from its stored token through apply.
func (p *Processor) pull(ctx context.Context, zone string, apply func(transport.Batch) error) error {
	if pl, ok := p.cfg.Transport.(Puller); ok {
		return pl.Pull(ctx, zone, apply)
	}
	since, err := p.cfg.Store.ZoneToken(zone)
	if err != nil {
		return err
	}
	resynced := false
	for {
		b, err := p.cfg.Transport.Changes(ctx, zone, since)
		if errors.Is(err, transport.ErrTokenExpired) && !resynced && since != 0 {
			since, resynced = 0, true
			if err := p.cfg.Store.SetZoneToken(zone, 0); err != nil {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		if err := apply(b); err != nil {
			return err
		}
		if err := p.cfg.Store.SetZoneToken(zone, b.NewSeq); err != nil {
			return err
		}
		since = b.NewSeq
		if !b.More {
			return nil
		}
	}
}

// readZone pulls g's zone page by page, each record routed to the phone it
// belongs to. After TOKEN_EXPIRED the whole zone comes again from 0
// (Batch.Reset): every surviving action is then a repeat. The processor
// mirrors nothing per zone (held actions are the hub's own state, not a copy
// of the mailbox), so a Reset drops nothing. A pull stopped by the batch
// limit or by a re-link stores no token for the page: the rest of it (a
// re-linked phone's new records included) is read again next pass. at is the
// phone whose record stopped the read (the zone's first phone otherwise).
func (p *Processor) readZone(ctx context.Context, g zoneGroup, ps *pass) (at mailbox, err error) {
	at = g.boxes[0]
	err = p.pull(ctx, g.zone, func(batch transport.Batch) error {
		for i, rec := range batch.Changed {
			if ps.budget <= 0 {
				ps.report.Remaining += len(batch.Changed) - i
				return errBudget
			}
			b, err := p.route(ctx, g, rec, ps)
			if err != nil {
				at = b
				return err
			}
		}
		return nil
	})
	if errors.Is(err, errBudget) {
		return at, nil
	}
	if err != nil {
		return at, fmt.Errorf("actions: reading a mailbox: %w", err)
	}
	return at, nil
}

// route hands one record of g's zone to the phone it belongs to (spec §12a
// point 1): a phone's record (relayToHub) to the phone its envelope's
// sender names, which FromPhone then authenticates with that phone's key
// alone — so a record is never attributed to another phone than the one
// that sealed it; the hub's own record read back (relayToPhone: an echo, a
// control) to the one phone whose key opens it. A sender with no mailbox in
// the zone, a hello (the link lane's) and bytes that are no envelope are
// left alone with no answer (D9). b is the phone the record went to.
func (p *Processor) route(ctx context.Context, g zoneGroup, rec transport.Stored, ps *pass) (b mailbox, err error) {
	h, err := secure.ParseHeader(rec.Envelope)
	if err != nil {
		log.Printf("hub: dropped a mailbox record: %s", errClass(err))
		return g.boxes[0], nil
	}
	switch h.Class {
	case secure.ClassRelayToHub:
		b, ok := g.box(h.Sender)
		if !ok {
			log.Printf("hub: dropped a record of device %s, which has no mailbox here", h.Sender)
			return g.boxes[0], nil
		}
		return b, p.handle(ctx, b, rec, ps)
	case secure.ClassRelayToPhone:
		for _, b := range g.boxes {
			o, err := p.cfg.Opener.OwnEchoFor(b.id, rec.Name, rec.Envelope)
			if errors.Is(err, secure.ErrNoRelayKey) {
				continue // another phone's record
			}
			if err != nil {
				if droppable(err) {
					return b, nil
				}
				return b, err
			}
			return b, p.ownReceived(ctx, b, rec, o, ps)
		}
	case secure.ClassHello, secure.ClassData, secure.ClassAlert, secure.ClassKeybox:
		// A hello is the link lane's; the rest never belongs in a mailbox.
	}
	return g.boxes[0], nil
}

// phoneSender is the sender of a phone's record (a relayToHub envelope) as
// its header names it, unauthenticated until FromPhone opens it; ok is false
// for any other class and for bytes that are no envelope.
func phoneSender(env []byte) (secure.ID, bool) {
	h, err := secure.ParseHeader(env)
	if err != nil || h.Class != secure.ClassRelayToHub {
		return secure.ID{}, false
	}
	return h.Sender, true
}

// namedDevice is the device a phone record's plain name names —
// a-<device>-<seq>, device-<device>, hello-<device> — or names=false for one
// that names none (action-<uuid>, c-<uuid>, recupload-<id>). ok is false for
// a name of those kinds whose device part does not parse.
func namedDevice(plain string) (id secure.ID, names, ok bool) {
	var dev string
	switch {
	case strings.HasPrefix(plain, "a-"):
		rest := plain[len("a-"):]
		if len(rest) < 38 || rest[36] != '-' {
			return id, true, false
		}
		dev = rest[:36]
	case strings.HasPrefix(plain, devicePrefix):
		dev = plain[len(devicePrefix):]
	case strings.HasPrefix(plain, "hello-"):
		dev = plain[len("hello-"):]
	default:
		return id, false, true
	}
	id, err := secure.ParseID(dev)
	return id, true, err == nil
}

// handle opens one record of b's phone and routes it. A record that does not
// open as this phone's (no linked key, rolled back) is dropped with no answer
// (D9), and so is one whose name names another device than its sender
// (class sender_mismatch: protocol §7.5 point 1).
func (p *Processor) handle(ctx context.Context, b mailbox, rec transport.Stored, ps *pass) error {
	opened, err := p.cfg.Opener.FromPhone(b.zone, rec.Name, rec.Envelope)
	if err != nil {
		if !droppable(err) {
			return err
		}
		log.Printf("hub: dropped a mailbox record of device %s: %s", b.id, errClass(err))
		return nil
	}
	if opened.Sender != b.id {
		log.Printf("hub: dropped a record of device %s found in device %s's mailbox", opened.Sender, b.id)
		return nil
	}
	if named, names, ok := namedDevice(opened.Frame.ID); names && (!ok || named != opened.Sender) {
		log.Printf("hub: dropped a record of device %s: sender_mismatch", b.id)
		return nil
	}
	if p.fault != nil {
		if err := p.fault("opened"); err != nil {
			return err
		}
	}
	switch opened.Frame.Kind {
	case kindAction:
		ps.report.Read++
		err = p.action(ctx, b, record{name: rec.Name, env: rec.Envelope, expect: expectSeq(rec.RecordSeq)}, opened, ps)
	case kindControl:
		ps.report.Read++
		err = p.phoneControl(ctx, b, rec, opened, ps)
	case kindRecordingUpload:
		ps.report.Read++
		err = p.recordingUpload(ctx, b, record{name: rec.Name, env: rec.Envelope, expect: expectSeq(rec.RecordSeq)}, opened, rec.AttachmentID, ps)
	case kindDevice:
		ps.report.Read++
		err = p.handleDeviceRecord(ctx, b, rec, opened)
	default:
		// An unknown kind has no work (the Kit's RelayRecordKind decoding).
		return nil
	}
	return err
}
