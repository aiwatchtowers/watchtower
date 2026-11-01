// Package memfake is the in-memory transport the hub's tests run on, in two
// kinds with one record model (the relay sim's FakeCloudKit, carried over):
//
//   - relay: a record's RecordSeq is the zone's change counter at its last
//     write (the hosted relay's record_seq = server_seq);
//   - cloudkit: a record's RecordSeq stands for a CloudKit change tag — opaque,
//     unique, unordered and never equal to a Changes cursor — so code that
//     compares a record's version with a cursor, or orders versions, fails on
//     this kind.
//
// Both keep last-version records, tombstones in the change feed, conditional
// writes with the current record on conflict, pages of PageLimit changes and a
// zone event per change. One Fake is shared by the hub (the Transport methods)
// and the phone (Write, plus Changes/Delete).
package memfake

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// PageLimit is the most changes one Changes call returns (the hub's batch limit).
const PageLimit = 200

// PageBytes caps the envelope bytes of one Changes page (the relay's 4 MiB);
// a page always holds at least one record.
const PageBytes = 4 << 20

// eventBuffer is the Events channel's capacity. Like the relay's Go client the
// fake never drops an event: beyond the buffer, events wait in a queue that a
// pump goroutine delivers in order, a zone event folding into one already
// waiting for the same zone, controls and errors each kept.
const eventBuffer = 256

// The op names FailNext takes.
var failOps = []string{"save", "delete", "changes", "download"}

type record struct {
	stored  transport.Stored
	change  uint64 // the zone counter of the record's last change
	deleted bool
}

type zoneState struct {
	counter uint64 // last change in the zone; the Changes cursor
	floor   uint64 // cursors below it (other than 0) are expired
	recs    map[string]*record
}

// Fake is the in-memory transport; safe for concurrent use.
type Fake struct {
	kind   transport.Kind
	clock  func() time.Time
	events chan transport.Event

	mu          sync.Mutex
	down        bool
	failures    map[string][]error
	zones       map[string]*zoneState
	frames      [][]byte
	attachments map[string][]byte
	attZones    map[string]string // attachment id → its record's zone
	tagCounter  uint64
	attCounter  uint64
	pending     []transport.Event // events waiting for room in the channel
	pumping     bool              // a pump goroutine owns pending
	account     *relayv1.AccountState
	accountRead int
}

var _ transport.Transport = (*Fake)(nil)

// New returns an empty, available fake of kind (KindRelay or KindCloudKit);
// clock stamps ServerAt (nil = time.Now). An unknown kind panics.
func New(kind transport.Kind, clock func() time.Time) *Fake {
	if kind != transport.KindRelay && kind != transport.KindCloudKit {
		panic(fmt.Sprintf("memfake: unknown kind %q", kind))
	}
	if clock == nil {
		clock = time.Now
	}
	return &Fake{
		kind: kind, clock: clock, events: make(chan transport.Event, eventBuffer),
		failures: map[string][]error{}, zones: map[string]*zoneState{}, attachments: map[string][]byte{}, attZones: map[string]string{},
	}
}

// Kind implements transport.Transport.
func (f *Fake) Kind() transport.Kind { return f.kind }

// Events implements transport.Transport.
func (f *Fake) Events() <-chan transport.Event { return f.events }

// SetAvailable turns an outage off (true) or on (false): while down every op,
// the phone's Write included, fails with transport.ErrUnavailable.
func (f *Fake) SetAvailable(ok bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.down = !ok
}

// FailNext makes the next call of op ("save", "delete", "changes" or
// "download") fail with err, writing nothing; calls queue per op. It applies
// to the Transport methods only, never to Write. An unknown op panics.
func (f *Fake) FailNext(op string, err error) {
	known := false
	for _, o := range failOps {
		known = known || o == op
	}
	if !known {
		panic(fmt.Sprintf("memfake: unknown op %q", op))
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.failures[op] = append(f.failures[op], err)
}

// Frames is a copy of every envelope the fake ever received, in order — the
// hub's saves (conflicting ones too) and the phone's writes (canary capture).
func (f *Fake) Frames() [][]byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([][]byte, len(f.frames))
	for i, b := range f.frames {
		out[i] = bytes.Clone(b)
	}
	return out
}

// ExpireBefore makes every later Changes(zone, since) with 0 < since < seq
// fail with transport.ErrTokenExpired, and purges the zone's tombstones older
// than seq (the relay's 30-day tombstone purge). A resync from 0 still works.
func (f *Fake) ExpireBefore(zone string, seq uint64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	z := f.zone(zone)
	z.floor = max(z.floor, seq)
	for name, r := range z.recs {
		if r.deleted && r.change < seq {
			delete(z.recs, name)
		}
	}
}

// Attachments is a copy of every uploaded attachment's bytes, keyed by
// attachment id (canary capture; Frames stays envelope-only).
func (f *Fake) Attachments() map[string][]byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make(map[string][]byte, len(f.attachments))
	for id, b := range f.attachments {
		out[id] = bytes.Clone(b)
	}
	return out
}

// SendEvent puts e on the Events stream (a server control, a transport error);
// it is never dropped.
func (f *Fake) SendEvent(e transport.Event) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.emit(e)
}

// SetAccountState sets what AccountState answers (nil: no phone holds the
// hub in a slot).
func (f *Fake) SetAccountState(st *relayv1.AccountState) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.account = nil
	if st != nil {
		f.account = proto.Clone(st).(*relayv1.AccountState)
	}
}

// AccountState is the hosted relay's get_account_state over the fake: a copy
// of what SetAccountState set, or an empty state; it fails while the fake is
// down, and every call is counted (AccountStateReads).
func (f *Fake) AccountState(context.Context) (*relayv1.AccountState, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.accountRead++
	if f.down {
		return nil, transport.ErrUnavailable
	}
	if f.account == nil {
		return &relayv1.AccountState{}, nil
	}
	return proto.Clone(f.account).(*relayv1.AccountState), nil
}

// AccountStateReads is how many times AccountState was called.
func (f *Fake) AccountStateReads() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.accountRead
}

// Write is the phone's side: it stores env under name in zone with no sealer
// (the phone seals its own records), subject to expect and to SetAvailable.
func (f *Fake) Write(zone, name string, env []byte, expect transport.Expect) (transport.Outcome, error) {
	return f.WriteAs("", zone, name, env, expect)
}

// WriteAs is Write by the iCloud user creator: the record reads back with
// Stored.Creator set (CloudKit's record creator; a rewrite keeps the
// record's first creator, as CloudKit does).
func (f *Fake) WriteAs(creator, zone, name string, env []byte, expect transport.Expect) (transport.Outcome, error) {
	if err := checkExpect(expect); err != nil {
		return transport.Outcome{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.down {
		return transport.Outcome{}, transport.ErrUnavailable
	}
	f.frames = append(f.frames, bytes.Clone(env))
	out := f.put(zone, name, env, "", expect)
	if out.Saved {
		rec := f.zone(zone).recs[name]
		if rec.stored.Creator == "" {
			rec.stored.Creator = creator
		}
	}
	return out, nil
}

// WriteWithAsset is Write for a phone record that carries an attachment (a
// recording upload): the sealed asset bytes are stored and served by Download.
func (f *Fake) WriteWithAsset(zone, name string, env, asset []byte, expect transport.Expect) (transport.Outcome, error) {
	if err := checkExpect(expect); err != nil {
		return transport.Outcome{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.down {
		return transport.Outcome{}, transport.ErrUnavailable
	}
	f.frames = append(f.frames, bytes.Clone(env))
	f.attCounter++
	att := "att-" + strconv.FormatUint(f.attCounter, 10)
	f.attachments[att] = bytes.Clone(asset)
	f.attZones[att] = zone
	return f.put(zone, name, env, att, expect), nil
}

// Save implements transport.Transport. An unsealed Record refuses the whole
// call with secure.ErrUnsealed before anything else; an asset file is read
// whole, stored as an attachment and served by Download (the fake does not
// re-check it — that is the real transport's job, see package transport).
func (f *Fake) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	for i, it := range items {
		if !it.Record.Sealed() {
			return nil, fmt.Errorf("memfake: save item %d: %w", i, secure.ErrUnsealed)
		}
		if err := checkExpect(it.Expect); err != nil {
			return nil, fmt.Errorf("memfake: save item %d: %w", i, err)
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	assets := make([][]byte, len(items))
	for i, it := range items {
		if p := it.Record.AssetPath(); p != "" && !isPairZone(it.Record.Zone()) {
			b, err := os.ReadFile(p)
			if err != nil {
				return nil, fmt.Errorf("memfake: read asset of item %d: %w", i, err)
			}
			assets[i] = b
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.gate("save"); err != nil {
		return nil, err
	}
	out := make([]transport.Outcome, len(items))
	for i, it := range items {
		r := it.Record
		env := r.Envelope()
		f.frames = append(f.frames, bytes.Clone(env))
		if r.AssetPath() != "" && isPairZone(r.Zone()) {
			out[i] = transport.Outcome{Refused: fmt.Errorf("memfake: attachment in a pairing zone: %w", transport.ErrForbidden)}
			continue
		}
		att := ""
		if assets[i] != nil {
			f.attCounter++
			att = "att-" + strconv.FormatUint(f.attCounter, 10)
			f.attachments[att] = assets[i]
			f.attZones[att] = r.Zone()
		}
		out[i] = f.put(r.Zone(), r.WireName(), env, att, it.Expect)
	}
	return out, nil
}

// Delete implements transport.Transport. A delete that took effect, or found
// nothing to delete with no precondition, reports Saved with RecordSeq 0.
func (f *Fake) Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	for i, it := range items {
		if err := checkExpect(it.Expect); err != nil {
			return nil, fmt.Errorf("memfake: delete item %d: %w", i, err)
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.gate("delete"); err != nil {
		return nil, err
	}
	z := f.zone(zone)
	out := make([]transport.Outcome, len(items))
	for i, it := range items {
		cur := live(z, it.Name)
		if conflict(cur, it.Expect) {
			out[i] = transport.Outcome{Conflict: current(cur)}
			continue
		}
		out[i] = transport.Outcome{Saved: true}
		if cur == nil {
			continue
		}
		z.counter++
		cur.deleted, cur.change = true, z.counter
		cur.stored = transport.Stored{Zone: zone, Name: it.Name, ServerAt: f.clock()}
		f.emit(transport.Event{Zone: zone})
	}
	return out, nil
}

// Changes implements transport.Transport: up to PageLimit changes after since
// in change order; a cursor below the zone's ExpireBefore floor (other than 0)
// or above anything the zone issued is transport.ErrTokenExpired.
func (f *Fake) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	if err := ctx.Err(); err != nil {
		return transport.Batch{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.gate("changes"); err != nil {
		return transport.Batch{}, err
	}
	z := f.zone(zone)
	if since > z.counter || (since != 0 && since < z.floor) {
		return transport.Batch{}, fmt.Errorf("memfake: %s since %d: %w", zone, since, transport.ErrTokenExpired)
	}
	var recs []*record
	for _, r := range z.recs {
		if r.change > since {
			recs = append(recs, r)
		}
	}
	sort.Slice(recs, func(i, j int) bool { return recs[i].change < recs[j].change })
	b := transport.Batch{NewSeq: z.counter, Reset: since == 0}
	n, size := 0, 0
	for n < len(recs) && n < PageLimit {
		size += len(recs[n].stored.Envelope)
		if n > 0 && size > PageBytes {
			break
		}
		n++
	}
	if n < len(recs) {
		recs = recs[:n]
		b.More, b.NewSeq = true, recs[n-1].change
	}
	for _, r := range recs {
		if r.deleted {
			b.Deleted = append(b.Deleted, r.stored.Name)
		} else {
			b.Changed = append(b.Changed, clone(r.stored))
		}
	}
	return b, nil
}

// Download implements transport.Transport: it writes the attachment's bytes
// to dst with mode 0600; an attachment of another zone is ErrForbidden.
func (f *Fake) Download(ctx context.Context, zone, attachmentID, dst string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	f.mu.Lock()
	if err := f.gate("download"); err != nil {
		f.mu.Unlock()
		return err
	}
	b, ok := f.attachments[attachmentID]
	ok = ok && f.attZones[attachmentID] == zone
	f.mu.Unlock()
	if !ok {
		return fmt.Errorf("memfake: unknown attachment: %w", transport.ErrForbidden)
	}
	if err := os.WriteFile(dst, b, 0o600); err != nil {
		return fmt.Errorf("memfake: write download: %w", err)
	}
	if err := os.Chmod(dst, 0o600); err != nil {
		return fmt.Errorf("memfake: chmod download: %w", err)
	}
	return nil
}

// gate answers an outage or a queued failure of op; f.mu is held.
func (f *Fake) gate(op string) error {
	if f.down {
		return transport.ErrUnavailable
	}
	if q := f.failures[op]; len(q) > 0 {
		f.failures[op] = q[1:]
		return q[0]
	}
	return nil
}

// put applies one conditional write; f.mu is held.
func (f *Fake) put(zone, name string, env []byte, att string, expect transport.Expect) transport.Outcome {
	z := f.zone(zone)
	cur := live(z, name)
	if conflict(cur, expect) {
		return transport.Outcome{Conflict: current(cur)}
	}
	z.counter++
	version := z.counter
	if f.kind == transport.KindCloudKit {
		version = f.nextTag()
	}
	creator := ""
	if cur != nil {
		creator = cur.stored.Creator // a record keeps its first creator
	}
	z.recs[name] = &record{
		change: z.counter,
		stored: transport.Stored{Zone: zone, Name: name, Envelope: bytes.Clone(env), RecordSeq: version, ServerAt: f.clock(),
			AttachmentID: att, Creator: creator},
	}
	f.emit(transport.Event{Zone: zone})
	return transport.Outcome{Saved: true, RecordSeq: version}
}

// nextTag is a fresh change tag: splitmix64 over a counter (a bijection, so
// tags never repeat), skipping values small enough to pass for a counter.
func (f *Fake) nextTag() uint64 {
	for {
		f.tagCounter++
		x := f.tagCounter + 0x9e3779b97f4a7c15
		x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
		x = (x ^ (x >> 27)) * 0x94d049bb133111eb
		x ^= x >> 31
		if x >= 1<<32 {
			return x
		}
	}
}

// emit queues e for delivery without blocking; f.mu is held. While nothing
// waits it goes straight into the channel; otherwise it joins pending (a zone
// event already waiting for its zone absorbs it) and the pump delivers it.
func (f *Fake) emit(e transport.Event) {
	if !f.pumping {
		select {
		case f.events <- e:
			return
		default:
		}
	}
	if e.Zone != "" && e.Control == nil && e.Err == nil {
		for _, p := range f.pending {
			if p.Zone == e.Zone && p.Control == nil && p.Err == nil {
				return
			}
		}
	}
	f.pending = append(f.pending, e)
	if !f.pumping {
		f.pumping = true
		go f.pump()
	}
}

// pump delivers pending in order, blocking on the channel, and exits once the
// queue is empty, so a drained fake holds no goroutine.
func (f *Fake) pump() {
	for {
		f.mu.Lock()
		if len(f.pending) == 0 {
			f.pumping = false
			f.mu.Unlock()
			return
		}
		e := f.pending[0]
		f.pending = f.pending[1:]
		f.mu.Unlock()
		f.events <- e
	}
}

func (f *Fake) zone(name string) *zoneState {
	z := f.zones[name]
	if z == nil {
		z = &zoneState{recs: map[string]*record{}}
		f.zones[name] = z
	}
	return z
}

func live(z *zoneState, name string) *record {
	if r := z.recs[name]; r != nil && !r.deleted {
		return r
	}
	return nil
}

func conflict(cur *record, e transport.Expect) bool {
	switch e.Mode {
	case transport.ExpectAbsent:
		return cur != nil
	case transport.ExpectSeq:
		return cur == nil || cur.stored.RecordSeq != e.Seq
	default:
		return false
	}
}

func current(cur *record) *transport.Stored {
	if cur == nil {
		return nil
	}
	s := clone(cur.stored)
	return &s
}

func clone(s transport.Stored) transport.Stored {
	s.Envelope = bytes.Clone(s.Envelope)
	return s
}

func checkExpect(e transport.Expect) error {
	switch e.Mode {
	case transport.ExpectNone, transport.ExpectAbsent, transport.ExpectSeq:
		return nil
	default:
		return fmt.Errorf("memfake: unknown expect mode %d", e.Mode)
	}
}

func isPairZone(zone string) bool { return strings.HasPrefix(zone, transport.PairZone("")) }
