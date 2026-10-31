package slices

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"slices"
	"sort"
	"sync"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
)

// Publishing cadence (spec §9, ask #735).
const (
	// Debounce is the trailing quiet time after the last PublishSoon.
	Debounce = 150 * time.Millisecond
	// MaxDebounceWait bounds a trailing debounce: a dirty kind is never held
	// longer, so continuous writes cannot hold publishing off.
	MaxDebounceWait = time.Second
	// FullDiffEvery is the backstop full diff over every kind (clock-driven
	// values and writes nothing reported).
	FullDiffEvery = 60 * time.Second
	// RelaySpacing is the hosted relay's minimum time between two writes of
	// one kind.
	RelaySpacing = 150 * time.Millisecond
	// CloudKitSpacing is CloudKit's (the battery rule #724, phase 3).
	CloudKitSpacing = 2 * time.Second
	// RetryFirst and RetryMax bound Run's retry of the kinds a cycle did not
	// finish (a failed save, a failed source, an epoch abort): 1 s doubling
	// to 10 s, reset by a cycle that finishes everything it was given — so a
	// transient relay failure delays an ask by seconds, never a full diff.
	RetryFirst = time.Second
	RetryMax   = 10 * time.Second
)

// ErrNoKeys is returned while the hub has no epoch keys yet, so nothing is read or published
// (never in the clear).
var ErrNoKeys = errors.New("slices: no hub keys: nothing is published")

// errEpochMoved: a rotation committed while a kind was sealed; nothing of it
// is recorded and the cycle stops (the rotation wiped the hashes, so the next
// cycle reseals everything under the new epoch).
var errEpochMoved = errors.New("slices: epoch rotated mid-cycle")

// errGrantID: a device_grant item whose id is not a canonical device id.
var errGrantID = errors.New("slices: device_grant id is not an uppercase device id")

// Item is one record of a slice: ID makes the record name "<kind>-<ID>" (the
// heartbeat's is empty), Payload is the plain JSON (wire.Marshal), Notify the
// frame's notify level ("" for none), Asset and AssetPath an already sealed
// asset file and its descriptor, or nil and "". The publisher owns Payload
// once Items returned it.
type Item struct {
	ID        string
	Payload   []byte
	Notify    string
	Asset     *secure.AssetDescriptor
	AssetPath string
}

// Source computes one kind's whole current slice: a record missing from what
// Items returns is deleted from the zone. An Items error skips the kind for
// the cycle (nothing of it saved or deleted).
type Source interface {
	Kind() Kind
	Items(ctx context.Context) ([]Item, error)
}

// Config wires a Publisher. Spacing 0 takes the transport's (RelaySpacing,
// CloudKitSpacing on a CloudKit transport); Clock defaults to time.Now and
// stamps pushed_at and the spacing rule; Linked (nil = always linked) says
// whether a phone is linked: without one only UnlinkedKinds are published.
type Config struct {
	Store     *state.Store
	Transport transport.Transport
	Sealer    *secure.Sealer
	DataZone  string
	Sources   []Source
	Spacing   time.Duration
	Clock     func() time.Time
	Linked    func() (bool, error)
}

// CycleReport is what one cycle did. Skipped names records not published
// this cycle and not hashed, so a later cycle retries them (oversized,
// unsealable, refused by the transport, an invalid id). Deferred holds the
// kinds the spacing rule kept back, with the time they may be written.
// Failed lists the kinds whose source failed. Aborted is true when an epoch
// rotation stopped the cycle. Unfinished lists the kinds the cycle was given
// and did not finish — a failed source, the kind whose save or state write
// failed and every kind after it, the kinds left by an abort, or every kind
// asked for when the link state could not be read; Run retries them.
type CycleReport struct {
	Saved, Deleted int
	Skipped        []string
	Deferred       map[Kind]time.Time
	Failed         []Kind
	Aborted        bool
	Unfinished     []Kind
}

// Publisher is the slice publisher. PublishSoon is safe from any goroutine;
// cycles run one at a time.
type Publisher struct {
	c       Config
	spacing time.Duration
	clock   func() time.Time
	wake    chan struct{}
	// mono and timer are Run's time (the debounce, the full diff, the
	// retries); a test replaces them with a fake clock.
	mono  func() time.Time
	timer func(d time.Duration) (<-chan time.Time, func())

	cycleMu sync.Mutex // one cycle at a time; guards the fields below
	// lastWrite is when each kind last saved or deleted a record.
	lastWrite map[Kind]time.Time
	// warned is record name → payload hash of the last skip logged, so a
	// stuck record logs once per payload.
	warned map[string]string
	// unlinkedSeen: a cycle saw no phone linked and no cycle has completed
	// since one is.
	unlinkedSeen bool

	mu          sync.Mutex // guards the dirty set and lastPublish
	dirty       map[Kind]bool
	firstDirty  time.Time // monotonic, first PublishSoon of the dirty set
	lastDirty   time.Time // monotonic, latest PublishSoon
	lastPublish time.Time
}

// NewPublisher builds a Publisher over c.
func NewPublisher(c Config) *Publisher {
	if c.Clock == nil {
		c.Clock = time.Now
	}
	spacing := c.Spacing
	if spacing <= 0 {
		spacing = RelaySpacing
		if c.Transport != nil && c.Transport.Kind() == transport.KindCloudKit {
			spacing = CloudKitSpacing
		}
	}
	for _, s := range c.Sources {
		if !slices.Contains(AllKinds, s.Kind()) {
			log.Printf("hub slices: source of unknown kind %s is never published", s.Kind())
		}
	}
	return &Publisher{
		c: c, spacing: spacing, clock: c.Clock, wake: make(chan struct{}, 1), mono: time.Now, timer: realTimer,
		lastWrite: map[Kind]time.Time{}, warned: map[string]string{}, dirty: map[Kind]bool{},
	}
}

func realTimer(d time.Duration) (<-chan time.Time, func()) {
	t := time.NewTimer(d)
	return t.C, func() { t.Stop() }
}

// PublishSoon marks kinds dirty: Run diffs them Debounce after the last call,
// and never later than MaxDebounceWait after the first one of the burst.
func (p *Publisher) PublishSoon(kinds ...Kind) {
	if len(kinds) == 0 {
		return
	}
	now := p.mono()
	p.mu.Lock()
	if len(p.dirty) == 0 {
		p.firstDirty = now
	}
	for _, k := range kinds {
		p.dirty[k] = true
	}
	p.lastDirty = now
	p.mu.Unlock()
	select {
	case p.wake <- struct{}{}:
	default:
	}
}

// LastPublishAt is the end of the last completed cycle (the heartbeat's
// last_publish_at); ok is false before the first.
func (p *Publisher) LastPublishAt() (time.Time, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.lastPublish, !p.lastPublish.IsZero()
}

// debounceDue is when the dirty set is due; ok is false when it is empty.
func (p *Publisher) debounceDue() (time.Time, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.dirty) == 0 {
		return time.Time{}, false
	}
	due := p.lastDirty.Add(Debounce)
	if limit := p.firstDirty.Add(MaxDebounceWait); limit.Before(due) {
		due = limit
	}
	return due, true
}

// takeDirty empties the dirty set and returns it.
func (p *Publisher) takeDirty() []Kind {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]Kind, 0, len(p.dirty))
	for k := range p.dirty {
		out = append(out, k)
	}
	clear(p.dirty)
	return out
}

// Run publishes until ctx ends (it returns ctx.Err()): a full cycle at once
// and every FullDiffEvery, the dirty kinds after their debounce, the kinds
// the spacing rule deferred once it allows them, and the kinds a cycle did
// not finish after a bounded backoff (RetryFirst doubling to RetryMax).
func (p *Publisher) Run(ctx context.Context) error {
	held := map[Kind]time.Time{} // monotonic time each deferred or retried kind may go
	nextFull := p.mono()
	var backoff time.Duration
	for {
		now := p.mono()
		var (
			kinds []Kind
			full  = !now.Before(nextFull)
		)
		if full {
			p.takeDirty()
			clear(held)
			nextFull = now.Add(FullDiffEvery)
		} else {
			if due, ok := p.debounceDue(); ok && !now.Before(due) {
				kinds = p.takeDirty()
			}
			for k, at := range held {
				if !now.Before(at) {
					kinds = append(kinds, k)
					delete(held, k)
				}
			}
		}
		if full || len(kinds) > 0 {
			if full {
				kinds = nil
			}
			rep, err := p.Cycle(ctx, kinds)
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				log.Printf("hub slices: publish cycle failed (%s); %d kinds retried", errClass(err), len(rep.Unfinished))
			}
			after := p.mono()
			clockNow := p.clock()
			for k, at := range rep.Deferred {
				held[k] = after.Add(max(0, at.Sub(clockNow)))
			}
			if len(rep.Unfinished) == 0 {
				backoff = 0
				continue
			}
			backoff = min(max(backoff*2, RetryFirst), RetryMax)
			for _, k := range rep.Unfinished {
				if at, ok := held[k]; !ok || at.Before(after.Add(backoff)) {
					held[k] = after.Add(backoff)
				}
			}
			continue
		}
		deadline := nextFull
		if due, ok := p.debounceDue(); ok && due.Before(deadline) {
			deadline = due
		}
		for _, at := range held {
			if at.Before(deadline) {
				deadline = at
			}
		}
		fired, stop := p.timer(deadline.Sub(now))
		select {
		case <-ctx.Done():
			stop()
			return ctx.Err()
		case <-p.wake:
		case <-fired:
		}
		stop()
	}
}

// Cycle diffs kinds (nil: every kind with a source), urgent kinds first:
// each changed record is sealed and saved, its payload hash recorded with
// its wire name, and each record gone from its source deleted. Without a
// linked phone only UnlinkedKinds are diffed; the first cycle that sees a
// phone linked after one that saw none diffs every kind, so the new phone
// gets the whole window, and repeats that until such a cycle completes. A
// kind written less than the spacing ago is not read and comes back in
// Deferred. A record that cannot be sealed or is refused is skipped (logged
// once per payload); a source error skips its kind. A transport or state
// failure fails the cycle with what it did so far.
func (p *Publisher) Cycle(ctx context.Context, kinds []Kind) (CycleReport, error) {
	p.cycleMu.Lock()
	defer p.cycleMu.Unlock()
	rep := CycleReport{Deferred: map[Kind]time.Time{}}
	linked := true
	if p.c.Linked != nil {
		var err error
		if linked, err = p.c.Linked(); err != nil {
			rep.Unfinished = kinds
			if kinds == nil {
				rep.Unfinished = p.sourceKinds()
			}
			return rep, fmt.Errorf("slices: reading the link state: %w", err)
		}
	}
	newlyLinked := linked && p.unlinkedSeen
	if !linked {
		p.unlinkedSeen = true
	}
	in := func(k Kind) bool {
		switch {
		case !linked:
			return slices.Contains(UnlinkedKinds, k) && (kinds == nil || slices.Contains(kinds, k))
		case newlyLinked, kinds == nil:
			return true
		default:
			return slices.Contains(kinds, k)
		}
	}
	var todo []Kind
	for _, k := range publishOrder {
		if in(k) && len(p.sourcesOf(k)) > 0 {
			todo = append(todo, k)
		}
	}
	for i, k := range todo {
		srcs := p.sourcesOf(k)
		now := p.clock()
		if last, ok := p.lastWrite[k]; ok && now.Sub(last) < p.spacing {
			rep.Deferred[k] = last.Add(p.spacing)
			continue
		}
		wrote, err := p.publishKind(ctx, k, srcs, &rep)
		if wrote {
			p.lastWrite[k] = now
		}
		if errors.Is(err, errEpochMoved) {
			log.Printf("hub slices: epoch rotated while %s was sealed: the rest is resealed next cycle", k)
			rep.Aborted = true
			rep.Unfinished = append(rep.Unfinished, todo[i:]...)
			return rep, nil
		}
		if err != nil {
			rep.Unfinished = append(rep.Unfinished, todo[i:]...)
			return rep, err
		}
	}
	if newlyLinked {
		p.unlinkedSeen = false
	}
	at := p.clock()
	p.mu.Lock()
	p.lastPublish = at
	p.mu.Unlock()
	return rep, nil
}

// sourceKinds is every kind with a source, in publish order.
func (p *Publisher) sourceKinds() []Kind {
	var out []Kind
	for _, k := range publishOrder {
		if len(p.sourcesOf(k)) > 0 {
			out = append(out, k)
		}
	}
	return out
}

func (p *Publisher) sourcesOf(k Kind) []Source {
	var out []Source
	for _, s := range p.c.Sources {
		if s.Kind() == k {
			out = append(out, s)
		}
	}
	return out
}

// pushed is a record saved this cycle, recorded once the save succeeded.
// signal is a new alert's signal record (zero when it has none).
type pushed struct {
	name, wire, hash string
	signal           secure.Record
}

// publishKind diffs one kind; wrote is true when it saved or deleted a record.
func (p *Publisher) publishKind(ctx context.Context, k Kind, srcs []Source, rep *CycleReport) (wrote bool, err error) {
	epoch, err := latestEpoch(p.c.Store.Epochs())
	if err != nil {
		return false, err
	}
	known, err := p.c.Store.SliceHashes(string(k))
	if err != nil {
		return false, err
	}
	var items []Item
	for _, s := range srcs {
		got, err := s.Items(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return false, ctx.Err()
			}
			log.Printf("hub slices: %s source failed (%s): kind skipped this cycle", k, errClass(err))
			rep.Failed = append(rep.Failed, k)
			rep.Unfinished = append(rep.Unfinished, k)
			return false, nil
		}
		items = append(items, got...)
	}
	if k == KindDeviceGrant {
		// A keybox payload carries epoch keys: wiped once sealed.
		defer func() {
			for _, it := range items {
				clear(it.Payload)
			}
		}()
	}

	seen := map[string]bool{}
	var (
		saves   []transport.SaveItem
		pending []pushed
	)
	for _, it := range items {
		name, ok := recordName(k, it.ID)
		if !ok {
			log.Printf("hub slices: %s item with an invalid id skipped", k)
			rep.Skipped = append(rep.Skipped, string(k)+"-invalid-id")
			continue
		}
		if seen[name] {
			log.Printf("hub slices: duplicate record %s skipped", name)
			continue
		}
		seen[name] = true
		hash := itemHash(it)
		if prev, ok := known[name]; ok && prev.Hash == hash {
			continue
		}
		rec, err := p.seal(k, name, it)
		if err != nil {
			rep.Skipped = append(rep.Skipped, name)
			p.warnOnce(name, hash, fmt.Sprintf("not sealed (%s), payload %d bytes", errClass(err), len(it.Payload)))
			continue
		}
		pu := pushed{name: name, wire: rec.WireName(), hash: hash}
		if _, published := known[name]; k == KindAskAlert && !published && p.alertSignals() {
			if pu.signal, err = p.c.Sealer.Signal(rec); err != nil {
				rep.Skipped = append(rep.Skipped, name)
				p.warnOnce(name, hash, "without a signal ("+errClass(err)+")")
				continue
			}
		}
		saves = append(saves, transport.SaveItem{Record: rec})
		pending = append(pending, pu)
	}

	if len(saves) > 0 {
		// One Save per kind, not chunked: after a rotation or a new phone a
		// big kind goes as one request of up to N sealed records. The hosted
		// relay client (Task 8) or Plan 1b caps or splits the batch.
		outs, err := p.c.Transport.Save(ctx, saves)
		if err != nil {
			return false, fmt.Errorf("slices: saving %s: %w", k, err)
		}
		if len(outs) != len(saves) {
			return false, fmt.Errorf("slices: saving %s: %d outcomes for %d records", k, len(outs), len(saves))
		}
		var done []pushed
		for i, o := range outs {
			if o.Saved {
				done = append(done, pending[i])
				continue
			}
			rep.Skipped = append(rep.Skipped, pending[i].name)
			why := "a failed precondition"
			if o.Refused != nil {
				why = errClass(o.Refused)
			}
			p.warnOnce(pending[i].name, pending[i].hash, "refused by the transport ("+why+")")
		}
		if done, err = p.saveSignals(ctx, done, rep); err != nil {
			return true, err
		}
		if len(done) > 0 {
			wrote = true
			at := p.clock()
			err := p.c.Store.WithTx(ctx, func(tx *sql.Tx) error {
				now, err := latestEpoch(state.EpochsTx(tx))
				if err != nil {
					return err
				}
				if now != epoch {
					return errEpochMoved
				}
				for _, d := range done {
					if err := state.SetSliceState(tx, d.name, d.wire, d.hash, at); err != nil {
						return err
					}
				}
				return nil
			})
			if err != nil {
				return wrote, err
			}
			rep.Saved += len(done)
			for _, d := range done {
				delete(p.warned, d.name)
			}
		}
	}

	var gone []string
	for name := range known {
		if !seen[name] {
			gone = append(gone, name)
		}
	}
	if len(gone) == 0 {
		return wrote, nil
	}
	sort.Strings(gone)
	dels := make([]transport.DeleteItem, 0, len(gone))
	for _, name := range gone {
		w := known[name].WireName
		if w == "" {
			if w, err = p.c.Sealer.WireName(secure.ZoneData, name); err != nil {
				return wrote, fmt.Errorf("slices: wire name of a gone %s record: %w", k, err)
			}
		}
		dels = append(dels, transport.DeleteItem{Name: w})
	}
	dels = p.withSignalDeletes(k, dels)
	outs, err := p.c.Transport.Delete(ctx, p.c.DataZone, dels)
	if err != nil {
		return wrote, fmt.Errorf("slices: deleting %s: %w", k, err)
	}
	if len(outs) != len(dels) {
		return wrote, fmt.Errorf("slices: deleting %s: %d outcomes for %d records", k, len(outs), len(dels))
	}
	logSignalDeletes(outs[len(gone):])
	var deleted []string
	for i, o := range outs[:len(gone)] {
		if o.Saved {
			deleted = append(deleted, gone[i])
		} else {
			log.Printf("hub slices: delete of %s not done (%s); retried next cycle", gone[i], errClass(o.Refused))
		}
	}
	if len(deleted) == 0 {
		return wrote, nil
	}
	wrote = true
	if err := p.c.Store.WithTx(ctx, func(tx *sql.Tx) error {
		for _, name := range deleted {
			if err := state.DeleteSliceState(tx, name); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return wrote, err
	}
	rep.Deleted += len(deleted)
	return wrote, nil
}

// alertSignals reports whether new alerts get a signal record: on CloudKit,
// where a query subscription fires on it (the Swift AskAlertSignal). The
// hosted relay pushes an alert through send_alert instead (spec §12a), so no
// signal is written there.
func (p *Publisher) alertSignals() bool {
	return p.c.Transport != nil && p.c.Transport.Kind() == transport.KindCloudKit
}

// withSignalDeletes adds each gone alert's signal to its deletes (on a
// transport that writes signals); their outcomes are not the alerts'.
func (p *Publisher) withSignalDeletes(k Kind, dels []transport.DeleteItem) []transport.DeleteItem {
	if k != KindAskAlert || !p.alertSignals() {
		return dels
	}
	n := len(dels)
	for _, d := range dels[:n] {
		dels = append(dels, transport.DeleteItem{Name: secure.SignalName(d.Name)})
	}
	return dels
}

// logSignalDeletes logs a signal delete not done (a signal never written
// reports nothing to delete, which counts as done).
func logSignalDeletes(outs []transport.Outcome) {
	for _, o := range outs {
		if !o.Saved {
			log.Printf("hub slices: delete of an alert's signal not done (%s)", errClass(o.Refused))
		}
	}
}

// saveSignals saves the signals of the alerts in done that first reached
// the zone (after the alerts, as the Swift hub's batch orders them), each on
// the condition that it is absent: one that exists already counts as saved
// and is never re-created. An alert whose signal was refused is dropped from
// done, so its hash is not recorded and the next cycle tries both again.
func (p *Publisher) saveSignals(ctx context.Context, done []pushed, rep *CycleReport) ([]pushed, error) {
	var (
		sigs  []transport.SaveItem
		owner []int
	)
	for i, d := range done {
		if d.signal.Sealed() {
			// Absent only: a signal already in the zone (saved by a cycle
			// whose hash write then failed) is never written again. The
			// phone's subscription fires on record creation only
			// (AskAlertSubscription, firesOnRecordCreation), so one stop
			// of work never buzzes twice.
			sigs = append(sigs, transport.SaveItem{Record: d.signal, Expect: transport.Expect{Mode: transport.ExpectAbsent}})
			owner = append(owner, i)
		}
	}
	if len(sigs) == 0 {
		return done, nil
	}
	outs, err := p.c.Transport.Save(ctx, sigs)
	if err != nil {
		return nil, fmt.Errorf("slices: saving alert signals: %w", err)
	}
	if len(outs) != len(sigs) {
		return nil, fmt.Errorf("slices: saving alert signals: %d outcomes for %d records", len(outs), len(sigs))
	}
	refused := map[int]bool{}
	for j, o := range outs {
		if o.Saved || o.Refused == nil {
			// Saved, or a failed precondition: the signal already exists.
			continue
		}
		d := done[owner[j]]
		refused[owner[j]] = true
		rep.Skipped = append(rep.Skipped, d.name)
		p.warnOnce(d.name, d.hash, "signal refused by the transport ("+errClass(o.Refused)+")")
	}
	if len(refused) == 0 {
		return done, nil
	}
	kept := done[:0:0]
	for i, d := range done {
		if !refused[i] {
			kept = append(kept, d)
		}
	}
	return kept, nil
}

// seal builds the sendable record: a device_grant as the phone's keybox, an
// ask_alert as an alert, anything else as a data record.
func (p *Publisher) seal(k Kind, name string, it Item) (secure.Record, error) {
	switch k {
	case KindDeviceGrant:
		id, err := secure.ParseID(it.ID)
		if err != nil || id.String() != it.ID {
			return secure.Record{}, errGrantID
		}
		return p.c.Sealer.Keybox(p.c.DataZone, id, it.Payload)
	case KindAskAlert:
		return p.c.Sealer.Alert(p.c.DataZone, name, it.Payload)
	default:
		return p.c.Sealer.Data(p.c.DataZone, name, it.Notify, it.Payload, it.Asset, it.AssetPath)
	}
}

// warnOnce logs a skipped record once per payload hash (FILES-01: the record
// name is a kind and an id, the rest a class and a count).
func (p *Publisher) warnOnce(name, hash, what string) {
	if p.warned[name] == hash {
		return
	}
	p.warned[name] = hash
	log.Printf("hub slices: record %s %s; skipped, retried when it changes", name, what)
}

// itemHash is the hash recorded for a published item: SHA-256 hex of its
// payload, and for an asset-backed item of the payload plus the asset's
// plaintext digest (the Swift SliceDiff.recordHash), so a changed asset
// alone republishes. Hashes are of the plaintext: envelopes differ on every
// seal.
func itemHash(it Item) string {
	h := sha256.New()
	h.Write(it.Payload)
	if it.Asset != nil {
		h.Write(it.Asset.PlaintextDigest[:])
	}
	return hex.EncodeToString(h.Sum(nil))
}

// latestEpoch is the current (newest) epoch, ErrNoKeys without one.
func latestEpoch(epochs []state.Epoch, err error) (uint32, error) {
	if err != nil {
		return 0, err
	}
	if len(epochs) == 0 {
		return 0, ErrNoKeys
	}
	return epochs[len(epochs)-1].Epoch, nil
}

// errClass names an error by its sentinel for a log line, never its text.
func errClass(err error) string {
	classes := []struct {
		err  error
		name string
	}{
		{secure.ErrOversized, "oversized"},
		{secure.ErrUnknownKind, "unknown_kind"},
		{secure.ErrWrongClass, "wrong_class"},
		{secure.ErrUnsealed, "asset_unsealed"},
		{secure.ErrSignatureRequired, "no_signer"},
		{errGrantID, "bad_device_id"},
		{ErrNoKeys, "no_keys"},
		{transport.ErrUnavailable, "unavailable"},
		{transport.ErrForbidden, "forbidden"},
		{transport.ErrHubQuota, "hub_quota"},
		{transport.ErrRecordTooLarge, "record_too_large"},
		{transport.ErrRateLimited, "rate_limited"},
		{transport.ErrUnsupportedVersion, "unsupported_version"},
		{transport.ErrEntitlementInactive, "entitlement_inactive"},
		{context.Canceled, "canceled"},
		{context.DeadlineExceeded, "deadline"},
	}
	if err == nil {
		return "no outcome"
	}
	for _, c := range classes {
		if errors.Is(err, c.err) {
			return c.name
		}
	}
	return "error"
}
