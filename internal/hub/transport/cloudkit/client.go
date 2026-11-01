package cloudkit

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"watchtower/internal/hub/platform"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit/bridgepb"
)

// The hub dir's folders the bridge reads assets from and writes downloads
// to. AssetsDirName is the hub's own asset dir (the Sealer's), shared with
// the hub runtime.
const (
	AssetsDirName    = "assets"
	DownloadsDirName = "downloads"
)

// writeTimeout bounds one frame write when the caller's context has no
// earlier deadline.
const writeTimeout = 30 * time.Second

// eventBuffer is the Events channel's capacity. Events never block the
// socket reader: beyond the buffer they wait in a bounded queue (see emit).
const eventBuffer = 256

// Config configures the client and the Supervisor.
//
//   - Dir is the hub dir: the socket, assets/, downloads/ and GenerationFile
//     live in it.
//   - HubID is the Watchtower hub_id the CloudKit zones are named after;
//     RelayID the hub's relay device id, which names the runtime's zones
//     (data/<RelayID>, relay/<RelayID>/…): the client speaks those names and
//     maps them onto the CloudKit zones itself.
//   - Launch starts the bridge (the Supervisor's). It must return the
//     bridge process itself — the bundle's executable started directly, in
//     its own process group (Setpgid), never through open(1) — so the
//     daemon owns its lifetime; the bundle's LSUIElement keeps it out of the
//     Dock.
//   - Clock is the time source (nil = time.Now).
type Config struct {
	Dir, HubID, RelayID string
	Launch              func(ctx context.Context) (*os.Process, error)
	Clock               func() time.Time
}

// Client is the bridge client; safe for concurrent use. It connects on the
// first op and again on the next op after the connection dropped.
type Client struct {
	c       Config
	peerUID func(*net.UnixConn) (int, error)
	gens    *generations
	events  chan transport.Event
	done    chan struct{}

	dial sync.Mutex // one connect at a time

	mu        sync.Mutex
	conn      *conn
	connected bool // a connection was ever up: a later one emits PullNow
	closed    bool
	nextID    uint64
	pending   []transport.Event
	pumping   bool
}

var (
	_ transport.Transport     = (*Client)(nil)
	_ transport.SharedMailbox = (*Client)(nil)
	_ transport.Shares        = (*Client)(nil)
)

// New returns a client of the bridge serving c.Dir/bridge.sock.
func New(c Config) *Client {
	if c.Clock == nil {
		c.Clock = time.Now
	}
	return &Client{
		c: c, peerUID: platform.PeerUID, gens: newGenerations(c.Dir, DataZoneName(c.HubID), RelayZoneName(c.HubID)),
		events: make(chan transport.Event, eventBuffer), done: make(chan struct{}),
	}
}

// Kind implements transport.Transport.
func (*Client) Kind() transport.Kind { return transport.KindCloudKit }

// Events implements transport.Transport. Zone events carry runtime names; a
// dropped connection is an Err event; the connection after it is a PullNow
// event (pushes may have been missed meanwhile).
func (c *Client) Events() <-chan transport.Event { return c.events }

// MailboxFor implements transport.SharedMailbox: every phone's mailbox is the
// hub's one RelayZone, named transport.SharedMailboxZone(hub).
func (c *Client) MailboxFor(hub, _ string) string { return transport.SharedMailboxZone(hub) }

// Close drops the connection and stops the events; Events is not closed.
func (c *Client) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	close(c.done)
	cn := c.conn
	c.conn = nil
	c.mu.Unlock()
	if cn != nil {
		cn.close()
	}
	return nil
}

var (
	errClosed = errors.New("cloudkit: client closed")
	// errUnexpected: the bridge answered with another kind of result.
	errUnexpected = errors.New("cloudkit: unexpected bridge answer")
	// errBridgeFailure: a failure class the client does not know.
	errBridgeFailure = errors.New("cloudkit: bridge failure")
)

// Save implements transport.Transport. The whole call is refused before any
// I/O when an item's Record did not come from the Sealer, when an envelope
// is not a sealed envelope (only a sig- signal record may be empty, and only
// it), when a zone has no place on CloudKit (transport.ErrUnsupportedZone),
// or when an asset file is not a regular file under <hub dir>/assets. An
// ExpectSeq on a tag of an older bridge generation is refused per item
// (ErrStaleTag) and never sent. Items go out in frames of at most MaxFrame;
// one item that cannot fit is refused per item with
// transport.ErrRecordTooLarge. A failure part-way may leave earlier frames'
// items saved.
func (c *Client) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	zones := make([]zone, len(items))
	wire := make([]*bridgepb.SaveItem, len(items))
	for i, it := range items {
		r := it.Record
		if err := checkSealed(r); err != nil {
			return nil, fmt.Errorf("cloudkit: save item %d: %w", i, err)
		}
		z, err := c.zone(r.Zone())
		if err != nil {
			return nil, fmt.Errorf("cloudkit: save item %d: %w", i, err)
		}
		if err := checkMode(it.Expect); err != nil {
			return nil, fmt.Errorf("cloudkit: save item %d: %w", i, err)
		}
		w := &bridgepb.SaveItem{Zone: z.ck, Name: r.WireName(), Envelope: r.Envelope()}
		if p := r.AssetPath(); p != "" {
			if w.AssetPath, err = c.assetPath(p); err != nil {
				return nil, fmt.Errorf("cloudkit: save item %d: %w", i, err)
			}
		}
		zones[i], wire[i] = z, w
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, nil
	}
	if _, err := c.connect(ctx); err != nil {
		return nil, fmt.Errorf("cloudkit: save: %w", err)
	}
	out := make([]transport.Outcome, len(items))
	var sendable []int
	for i, w := range wire {
		e := items[i].Expect
		switch {
		case e.Mode == transport.ExpectSeq && !c.gens.tagOK(zones[i].ck, w.GetName(), e.Seq):
			out[i] = transport.Outcome{Refused: fmt.Errorf("cloudkit: save item %d: %w", i, ErrStaleTag)}
		case marshal.Size(w) > itemBudget:
			out[i] = transport.Outcome{Refused: fmt.Errorf("cloudkit: save item %d: %w", i, transport.ErrRecordTooLarge)}
		default:
			w.Expect = c.wireExpect(e)
			sendable = append(sendable, i)
		}
	}
	names := func(i int) string { return wire[i].GetName() }
	for _, chunk := range chunks(sendable, func(i int) int { return marshal.Size(wire[i]) }) {
		req := &bridgepb.Save{}
		mailbox := true
		for _, i := range chunk {
			req.Items = append(req.Items, wire[i])
			mailbox = mailbox && zones[i].mailbox
		}
		resp, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_Save{Save: req}}, mailbox)
		if err != nil {
			return nil, fmt.Errorf("cloudkit: save: %w", err)
		}
		if err := c.fillOutcomes(resp, chunk, zones, names, out); err != nil {
			return nil, fmt.Errorf("cloudkit: save: %w", err)
		}
	}
	return out, nil
}

// Delete implements transport.Transport; an ExpectSeq on a tag of an older
// bridge generation is refused per item (ErrStaleTag) and never sent.
func (c *Client) Delete(ctx context.Context, zoneName string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	z, err := c.zone(zoneName)
	if err != nil {
		return nil, err
	}
	for i, it := range items {
		if err := checkMode(it.Expect); err != nil {
			return nil, fmt.Errorf("cloudkit: delete item %d: %w", i, err)
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, nil
	}
	if _, err := c.connect(ctx); err != nil {
		return nil, fmt.Errorf("cloudkit: delete: %w", err)
	}
	out := make([]transport.Outcome, len(items))
	wire := make([]*bridgepb.DeleteItem, len(items))
	zones := make([]zone, len(items))
	var sendable []int
	for i, it := range items {
		zones[i] = z
		if it.Expect.Mode == transport.ExpectSeq && !c.gens.tagOK(z.ck, it.Name, it.Expect.Seq) {
			out[i] = transport.Outcome{Refused: fmt.Errorf("cloudkit: delete item %d: %w", i, ErrStaleTag)}
			continue
		}
		wire[i] = &bridgepb.DeleteItem{Name: it.Name, Expect: c.wireExpect(it.Expect)}
		sendable = append(sendable, i)
	}
	names := func(i int) string { return items[i].Name }
	for _, chunk := range chunks(sendable, func(i int) int { return marshal.Size(wire[i]) }) {
		req := &bridgepb.Delete{Zone: z.ck}
		for _, i := range chunk {
			req.Items = append(req.Items, wire[i])
		}
		resp, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_Delete{Delete: req}}, z.mailbox)
		if err != nil {
			return nil, fmt.Errorf("cloudkit: delete: %w", err)
		}
		if err := c.fillOutcomes(resp, chunk, zones, names, out); err != nil {
			return nil, fmt.Errorf("cloudkit: delete: %w", err)
		}
	}
	return out, nil
}

// Changes implements transport.Transport. since and NewSeq are the bridge's
// cursor for the zone; a record's RecordSeq is its tag_seq — opaque, never
// comparable with a cursor. Records carry the zone's runtime name (a phone's
// mailbox name reads the shared mailbox). A cursor of an older bridge
// generation is transport.ErrTokenExpired, never read: the caller reads the
// zone again from 0 and gets a Reset batch.
func (c *Client) Changes(ctx context.Context, zoneName string, since uint64) (transport.Batch, error) {
	z, err := c.zone(zoneName)
	if err != nil {
		return transport.Batch{}, err
	}
	if _, err := c.connect(ctx); err != nil {
		return transport.Batch{}, fmt.Errorf("cloudkit: changes: %w", err)
	}
	switch ok, err := c.gens.sinceOK(z.ck, since); {
	case err != nil:
		return transport.Batch{}, fmt.Errorf("cloudkit: changes: %w", err)
	case !ok:
		return transport.Batch{}, fmt.Errorf("cloudkit: changes: a cursor of an older bridge generation: %w", transport.ErrTokenExpired)
	}
	resp, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_Changes{Changes: &bridgepb.Changes{
		Zone: z.ck, Since: since, Generation: c.gens.current(),
	}}}, z.mailbox)
	if err != nil {
		return transport.Batch{}, fmt.Errorf("cloudkit: changes: %w", err)
	}
	b := resp.GetBatch()
	if b == nil {
		return transport.Batch{}, fmt.Errorf("cloudkit: changes: %w", errUnexpected)
	}
	changed, err := c.gens.adopt(b.GetGeneration())
	if err != nil {
		return transport.Batch{}, fmt.Errorf("cloudkit: changes: %w", err)
	}
	if changed && since != 0 {
		return transport.Batch{}, fmt.Errorf("cloudkit: changes: the bridge's generation changed: %w", transport.ErrTokenExpired)
	}
	c.gens.handedOut(z.ck, b.GetNewSeq())
	out := transport.Batch{Deleted: b.GetDeleted(), NewSeq: b.GetNewSeq(), More: b.GetMore(), Reset: since == 0}
	for _, r := range b.GetChanged() {
		c.gens.note(z.ck, r.GetName(), r.GetTagSeq())
		out.Changed = append(out.Changed, stored(z.name, r))
	}
	for _, n := range b.GetDeleted() {
		c.gens.note(z.ck, n, 0)
	}
	return out, nil
}

// Download implements transport.Transport. The bridge writes the sealed
// bytes into <hub dir>/downloads; the client moves that file to dst (0600).
func (c *Client) Download(ctx context.Context, zoneName, attachmentID, dst string) error {
	z, err := c.zone(zoneName)
	if err != nil {
		return err
	}
	if attachmentID == "" {
		return fmt.Errorf("cloudkit: download without an attachment: %w", transport.ErrForbidden)
	}
	dir := filepath.Join(c.c.Dir, DownloadsDirName)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("cloudkit: downloads dir: %w", err)
	}
	var rnd [8]byte
	_, _ = rand.Read(rnd[:])
	part := filepath.Join(dir, hex.EncodeToString(rnd[:])+".part")
	defer func() { _ = os.Remove(part) }()
	resp, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_Download{Download: &bridgepb.Download{
		Zone: z.ck, AssetId: attachmentID, Dst: part,
	}}}, z.mailbox)
	if err != nil {
		return fmt.Errorf("cloudkit: download: %w", err)
	}
	if resp.GetDone() == nil {
		return fmt.Errorf("cloudkit: download: %w", errUnexpected)
	}
	return moveDownload(part, dst)
}

// checkSealed is the E2E red line on the socket: a Record must come from the
// Sealer, and its envelope must be a sealed envelope — except a signal
// record, the one key-free kind, which is empty (Sealer.Signal).
func checkSealed(r secure.Record) error {
	if !r.Sealed() {
		return secure.ErrUnsealed
	}
	env := r.Envelope()
	if strings.HasPrefix(r.WireName(), secure.SignalPrefix) {
		if len(env) != 0 {
			return fmt.Errorf("%w: a signal record carries an envelope", secure.ErrUnsealed)
		}
		return nil
	}
	if _, err := secure.ParseHeader(env); err != nil {
		return fmt.Errorf("%w: not an envelope", secure.ErrUnsealed)
	}
	return nil
}

func checkMode(e transport.Expect) error {
	switch e.Mode {
	case transport.ExpectNone, transport.ExpectAbsent, transport.ExpectSeq:
		return nil
	}
	return fmt.Errorf("cloudkit: unknown expect mode %d", e.Mode)
}

// wireExpect is e on the wire; a tag travels with the generation it is of.
func (c *Client) wireExpect(e transport.Expect) *bridgepb.Expect {
	switch e.Mode {
	case transport.ExpectAbsent:
		return &bridgepb.Expect{Mode: bridgepb.ExpectMode_EXPECT_ABSENT}
	case transport.ExpectSeq:
		return &bridgepb.Expect{Mode: bridgepb.ExpectMode_EXPECT_SEQ, TagSeq: e.Seq, Generation: c.gens.current()}
	case transport.ExpectNone:
	}
	return nil
}

// itemBudget is the most bytes one item may take so that a frame holding it
// alone stays under MaxFrame (the request id, the oneof and the item's own
// tag and length fit in the slack).
const itemBudget = MaxFrame - 64

// chunks splits ids into runs whose items' sizes sum to at most itemBudget;
// every id fits alone.
func chunks(ids []int, size func(int) int) [][]int {
	var out [][]int
	var cur []int
	total := 0
	for _, i := range ids {
		n := size(i) + 8 // the item's tag and length
		if len(cur) > 0 && total+n > itemBudget {
			out, cur, total = append(out, cur), nil, 0
		}
		cur, total = append(cur, i), total+n
	}
	if len(cur) > 0 {
		out = append(out, cur)
	}
	return out
}

// fillOutcomes copies an Outcomes answer for the items at index (zones and
// record names by item) into out and notes the tags it hands out; an answer
// that does not cover the request exactly is an error.
func (c *Client) fillOutcomes(resp *bridgepb.Response, index []int, zones []zone, name func(int) string, out []transport.Outcome) error {
	got := resp.GetOutcomes()
	if got == nil || len(got.GetItems()) != len(index) {
		return fmt.Errorf("outcomes do not match the request: %w", errUnexpected)
	}
	for k, o := range got.GetItems() {
		i := index[k]
		z := zones[i]
		switch {
		case o.GetRefusedClass() != "":
			out[i] = transport.Outcome{Refused: classError(o.GetRefusedClass(), z.mailbox)}
		case o.GetSaved():
			out[i] = transport.Outcome{Saved: true, RecordSeq: o.GetTagSeq()}
			c.gens.note(z.ck, name(i), o.GetTagSeq())
		case o.GetConflict() != nil:
			s := stored(z.name, o.GetConflict())
			c.gens.note(z.ck, s.Name, s.RecordSeq)
			out[i] = transport.Outcome{Conflict: &s}
		default:
			out[i] = transport.Outcome{}
		}
	}
	return nil
}

func stored(zone string, r *bridgepb.Record) transport.Stored {
	s := transport.Stored{Zone: zone, Name: r.GetName(), Envelope: r.GetEnvelope(), RecordSeq: r.GetTagSeq(), AttachmentID: r.GetAssetId()}
	if ms := r.GetServerAtMs(); ms != 0 {
		s.ServerAt = time.UnixMilli(ms).UTC()
	}
	return s
}

// classError maps a bridge error class to the transport's errors (a quota
// on the mailbox zone is the mailbox's, else the hub's); the class is
// carried, never the bridge's text.
func classError(class string, mailbox bool) error {
	var base error
	switch class {
	case "unavailable":
		base = transport.ErrUnavailable
	case "token_expired":
		base = transport.ErrTokenExpired
	case "rate_limited":
		base = transport.ErrRateLimited
	case "record_too_large":
		base = transport.ErrRecordTooLarge
	case "quota":
		base = transport.ErrHubQuota
		if mailbox {
			base = transport.ErrMailboxQuota
		}
	case "forbidden":
		base = transport.ErrForbidden
	case "unsupported_zone":
		base = transport.ErrUnsupportedZone
	case "unsupported_version":
		base = transport.ErrUnsupportedVersion
	default:
		return fmt.Errorf("%w %q", errBridgeFailure, safeClass(class))
	}
	return fmt.Errorf("cloudkit: bridge: %w", base)
}

// safeClass keeps a class word (lowercase letters and '_', at most 32).
func safeClass(class string) string {
	if len(class) > 32 {
		return "unknown"
	}
	for _, r := range class {
		if (r < 'a' || r > 'z') && r != '_' {
			return "unknown"
		}
	}
	return class
}

// assetPath is a record's asset file as the bridge may read it: a non-empty
// regular file under <hub dir>/assets, reached without a symlink as its last
// component (the Sealer's own directory, where nothing else writes). The
// resolved path goes on the socket, never the bytes.
func (c *Client) assetPath(path string) (string, error) {
	root, err := filepath.EvalSymlinks(filepath.Join(c.c.Dir, AssetsDirName))
	if err != nil {
		return "", fmt.Errorf("%w: no asset directory", secure.ErrUnsealed)
	}
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("%w: asset path is not absolute", secure.ErrUnsealed)
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(filepath.Clean(path)))
	if err != nil {
		return "", fmt.Errorf("%w: asset path", secure.ErrUnsealed)
	}
	if !within(root, parent) {
		return "", fmt.Errorf("%w: asset file is outside the hub's asset directory", secure.ErrUnsealed)
	}
	full := filepath.Join(parent, filepath.Base(path))
	info, err := os.Lstat(full)
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
		return "", fmt.Errorf("%w: asset is not a non-empty regular file", secure.ErrUnsealed)
	}
	return full, nil
}

func within(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// moveDownload moves the bridge's finished file to dst (0600, replaced whole);
// a part that is not a regular file is refused.
func moveDownload(part, dst string) error {
	info, err := os.Lstat(part)
	if err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("cloudkit: download: no file written: %w", transport.ErrUnavailable)
	}
	if err := os.Chmod(part, 0o600); err != nil {
		return fmt.Errorf("cloudkit: download: %w", err)
	}
	if err := os.Rename(part, dst); err == nil {
		return nil
	} else if !errors.Is(err, syscall.EXDEV) {
		return fmt.Errorf("cloudkit: download: %w", err)
	}
	return copyFile(part, dst)
}

// copyFile copies src to dst through a temp file beside dst.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("cloudkit: download: %w", err)
	}
	defer func() { _ = in.Close() }()
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".download-*")
	if err != nil {
		return fmt.Errorf("cloudkit: download: %w", err)
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := io.Copy(tmp, in); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("cloudkit: download: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("cloudkit: download: %w", err)
	}
	if err := os.Rename(tmp.Name(), dst); err != nil {
		return fmt.Errorf("cloudkit: download: %w", err)
	}
	return nil
}
