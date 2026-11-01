package actions

import (
	"context"
	"errors"
	"fmt"
	"log"
	"slices"
	"strconv"
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
	// Hello takes the hellos of CloudKit's shared RelayZone (the link
	// lane's, link.Center.HandleCloudKitHello). An error leaves the page
	// to be read again next pass (a hello re-read decides nothing new).
	// Set, the zone is read on every pass even with no phone linked yet,
	// so a first phone's hello is seen. nil leaves hellos alone.
	Hello func(ctx context.Context, rec transport.Stored) error
}

// Processor reads the phones' mailboxes and applies their actions. Pass and
// FlushControls are single-flight: one runs at a time.
type Processor struct {
	cfg Config
	mu  sync.Mutex
	// fault, when set (tests), is called at named points; an error stops
	// the pass there as a crash would: "opened" (then "opened <device> <wire name>")
	// after a record opened and before any decision commits, "done" inside
	// the done transaction just before its commit (the transaction then
	// rolls back), "drain <device>" as a phone's held actions are drained.
	fault func(point string) error
	// held is the uploads answered held, tried again each pass (recording.go).
	held map[string]*heldUpload
	// batch, when set (tests), replaces BatchLimit as a pass's budget.
	batch int
	// paused (SetPaused) is read under mu by every transport-facing entry.
	paused atomic.Bool
	// strikes holds, per record version of a shared zone, the failures of
	// its content (shared.go); guarded by mu.
	strikes map[string]*strikeEntry
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
// link's nonce (a re-link changes it) and linkedAt keys the ledger. shared
// marks the shared mailbox (CloudKit's RelayZone, shared.go); there oldQueues is
// the key its queue had as a phone's own zone, moved to queue before a flush
// (a phone's own zone keeps its key: none).
type mailbox struct {
	id        secure.ID
	zone      string
	queue     string
	shared    bool
	oldQueues []string
	link      string
	linkedAt  time.Time
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
		b := mailbox{id: id, zone: zone, queue: zone, link: d.LinkNonce, linkedAt: d.LinkedAt}
		if zone == shared {
			b.queue, b.shared = shared+"@"+id.String(), true
			if d.RelayDeviceID != "" {
				b.oldQueues = []string{transport.MailboxZone(p.cfg.HubRelayID, d.RelayDeviceID)}
			}
		}
		out = append(out, b)
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
	zone   string
	shared bool
	boxes  []mailbox
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
			out = append(out, zoneGroup{zone: b.zone, shared: b.shared})
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
	for _, g := range p.withHelloZone(byZone(boxes)) {
		if g.shared { // CloudKit's one RelayZone: read once for every phone (shared.go)
			errs = append(errs, p.passShared(ctx, g, ps)...)
			continue
		}
		for _, b := range g.boxes {
			// Held actions that are next in line first: a drain an earlier
			// pass left at the batch limit (or a crash) resumes here.
			err := p.drainHeld(ctx, b, ps)
			if err == nil {
				err = p.retryUploads(ctx, b, ps)
			}
			if err == nil {
				err = p.readMailbox(ctx, b, ps)
			}
			errs = passError(b, err, errs)
		}
	}
	written, _, err := p.flushAll(ctx)
	ps.report.ControlsWritten = written
	p.nudge(ps)
	return ps.report, errors.Join(append(errs, err)...)
}

// passError logs the error that stopped b's phone and adds it to errs (nil
// adds nothing). The batch limit and a re-link are no errors: the rest is
// read next pass (Remaining counts the first).
func passError(b mailbox, err error, errs []error) []error {
	if err == nil {
		return errs
	}
	switch {
	case errors.Is(err, errBudget):
		return errs
	case errors.Is(err, errRelinked):
		log.Printf("hub: device %s was re-linked or unlinked during a pass: its mailbox is read again next pass", b.id)
		return errs
	}
	// One phone's failure never holds back the other phones.
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

// readMailbox pulls b's own mailbox zone (the hosted relay's) page by page.
// After TOKEN_EXPIRED the whole mailbox comes again from 0 (Batch.Reset):
// every surviving action is then a repeat. The processor mirrors nothing per
// zone (held actions are the hub's own state, not a copy of the mailbox), so
// a Reset drops nothing. A pull stopped by the batch limit or by a re-link
// stores no token for the page: the rest of it (a re-linked phone's new
// records included) is read again next pass.
func (p *Processor) readMailbox(ctx context.Context, b mailbox, ps *pass) error {
	err := p.pull(ctx, b.zone, func(batch transport.Batch) error {
		for i, rec := range batch.Changed {
			if ps.budget <= 0 {
				ps.report.Remaining += len(batch.Changed) - i
				return errBudget
			}
			if err := p.handle(ctx, b, rec, ps); err != nil {
				return err
			}
		}
		return nil
	})
	if errors.Is(err, errBudget) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("actions: reading a mailbox: %w", err)
	}
	return nil
}

// handle opens one mailbox record of b's phone and routes it. A record that
// does not open as this phone's (no linked key, another phone's, the hub's
// own echo, rolled back) is dropped with no answer (D9). In the shared
// mailbox, where readShared has routed the record by its sender, a name
// naming another device than its sender is dropped too (sender_mismatch,
// protocol §7.5 point 1) and the phone's device record is read; the hosted
// relay's own mailboxes keep their phase-1 handling.
func (p *Processor) handle(ctx context.Context, b mailbox, rec transport.Stored, ps *pass) error {
	opened, err := p.cfg.Opener.FromPhone(b.zone, rec.Name, rec.Envelope)
	if err != nil {
		if !droppable(err) {
			return err
		}
		if errors.Is(err, secure.ErrWrongClass) && !b.shared { // the hub's own records come back through the feed
			o, err := p.cfg.Opener.OwnEcho(b.zone, rec.Name, rec.Envelope)
			if err != nil {
				if droppable(err) {
					return nil
				}
				return err
			}
			return p.ownReceived(ctx, b, rec, o, ps)
		}
		log.Printf("hub: dropped a mailbox record of device %s: %s", b.id, errClass(err))
		return nil
	}
	if opened.Sender != b.id {
		log.Printf("hub: dropped a record of device %s found in device %s's mailbox", opened.Sender, b.id)
		return nil
	}
	if b.shared && !namesItsSender(opened) {
		log.Printf("hub: dropped a record of device %s: sender_mismatch", b.id)
		return nil
	}
	if p.fault != nil {
		if err := p.fault("opened"); err != nil {
			return err
		}
		if err := p.fault("opened " + b.id.String() + " " + rec.Name); err != nil {
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
		if !b.shared {
			return nil // the relay path reads no device records (phase 1 handling)
		}
		ps.report.Read++
		err = p.handleDeviceRecord(ctx, b, rec, opened)
	default:
		// An unknown kind has no work (the Kit's RelayRecordKind decoding).
		return nil
	}
	return err
}

// ownEcho opens the hub's own record read back from b's mailbox: in the
// shared mailbox under b's key only (OwnEchoFor), in a phone's own mailbox
// as phase 1 did (OwnEcho).
func (p *Processor) ownEcho(b mailbox, name string, env []byte) (secure.Opened, error) {
	if b.shared {
		return p.cfg.Opener.OwnEchoFor(b.id, name, env)
	}
	return p.cfg.Opener.OwnEcho(b.zone, name, env)
}
