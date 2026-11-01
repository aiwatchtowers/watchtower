package cloudkit

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
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

// The hub dir's folders the bridge reads assets from and writes downloads to.
const (
	AssetsDirName    = "assets"
	DownloadsDirName = "downloads"
)

// writeTimeout bounds one frame write when the caller's context has no
// earlier deadline.
const writeTimeout = 30 * time.Second

// eventBuffer is the Events channel's capacity. Events never block the
// socket reader: beyond the buffer they wait in a queue (a zone event folds
// into one already waiting for its zone, pull_now into a waiting pull_now).
const eventBuffer = 256

// Config configures the client and the Supervisor. Dir is the hub dir (the
// socket, assets/ and downloads/ live in it), HubID the Watchtower hub_id the
// CloudKit zones are named after, Launch starts the bridge process (the
// Supervisor's), Clock the time source (nil = time.Now).
type Config struct {
	Dir, HubID string
	Launch     func(ctx context.Context) (*os.Process, error)
	Clock      func() time.Time
}

// Client is the bridge client; safe for concurrent use. It connects on the
// first op and again on the next op after the connection dropped.
type Client struct {
	c       Config
	peerUID func(*net.UnixConn) (int, error)
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
		c: c, peerUID: platform.PeerUID,
		events: make(chan transport.Event, eventBuffer), done: make(chan struct{}),
	}
}

// Kind implements transport.Transport.
func (*Client) Kind() transport.Kind { return transport.KindCloudKit }

// Events implements transport.Transport. A dropped connection is an Err
// event; the connection after it is a PullNow event (pushes may have been
// missed meanwhile).
func (c *Client) Events() <-chan transport.Event { return c.events }

// MailboxFor implements transport.SharedMailbox: every phone's mailbox is the
// hub's one RelayZone.
func (c *Client) MailboxFor(_, _ string) string { return RelayZoneName(c.c.HubID) }

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

var errClosed = errors.New("cloudkit: client closed")

// Save implements transport.Transport. The whole call is refused before any
// I/O when an item's Record did not come from the Sealer, when an envelope
// is not a sealed envelope (only a sig- signal record may be empty, and only
// it), when a zone has no place on CloudKit (transport.ErrUnsupportedZone),
// or when an asset file is not a regular file under <hub dir>/assets. Items
// go out in frames of at most MaxFrame; one item that cannot fit is refused
// per item with transport.ErrRecordTooLarge. A failure part-way may leave
// earlier frames' items saved.
func (c *Client) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	zones := make([]string, len(items))
	wire := make([]*bridgepb.SaveItem, len(items))
	for i, it := range items {
		r := it.Record
		if err := checkSealed(r); err != nil {
			return nil, fmt.Errorf("cloudkit: save item %d: %w", i, err)
		}
		zone, err := zoneName(c.c.HubID, r.Zone())
		if err != nil {
			return nil, fmt.Errorf("cloudkit: save item %d: %w", i, err)
		}
		exp, err := wireExpect(it.Expect)
		if err != nil {
			return nil, fmt.Errorf("cloudkit: save item %d: %w", i, err)
		}
		w := &bridgepb.SaveItem{Zone: zone, Name: r.WireName(), Envelope: r.Envelope(), Expect: exp}
		if p := r.AssetPath(); p != "" {
			if w.AssetPath, err = c.assetPath(p); err != nil {
				return nil, fmt.Errorf("cloudkit: save item %d: %w", i, err)
			}
		}
		zones[i], wire[i] = r.Zone(), w
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	out := make([]transport.Outcome, len(items))
	var sendable []int
	for i, w := range wire {
		if marshal.Size(w) > itemBudget {
			out[i] = transport.Outcome{Refused: fmt.Errorf("cloudkit: save item %d: %w", i, transport.ErrRecordTooLarge)}
			continue
		}
		sendable = append(sendable, i)
	}
	for _, chunk := range chunks(sendable, func(i int) int { return marshal.Size(wire[i]) }) {
		req := &bridgepb.Save{}
		for _, i := range chunk {
			req.Items = append(req.Items, wire[i])
		}
		resp, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_Save{Save: req}})
		if err != nil {
			return nil, fmt.Errorf("cloudkit: save: %w", err)
		}
		if err := fillOutcomes(resp, chunk, zones, out); err != nil {
			return nil, fmt.Errorf("cloudkit: save: %w", err)
		}
	}
	return out, nil
}

// Delete implements transport.Transport.
func (c *Client) Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	ckZone, err := zoneName(c.c.HubID, zone)
	if err != nil {
		return nil, err
	}
	wire := make([]*bridgepb.DeleteItem, len(items))
	zones := make([]string, len(items))
	all := make([]int, len(items))
	for i, it := range items {
		exp, err := wireExpect(it.Expect)
		if err != nil {
			return nil, fmt.Errorf("cloudkit: delete item %d: %w", i, err)
		}
		wire[i], zones[i], all[i] = &bridgepb.DeleteItem{Name: it.Name, Expect: exp}, zone, i
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	out := make([]transport.Outcome, len(items))
	for _, chunk := range chunks(all, func(i int) int { return marshal.Size(wire[i]) }) {
		req := &bridgepb.Delete{Zone: ckZone}
		for _, i := range chunk {
			req.Items = append(req.Items, wire[i])
		}
		resp, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_Delete{Delete: req}})
		if err != nil {
			return nil, fmt.Errorf("cloudkit: delete: %w", err)
		}
		if err := fillOutcomes(resp, chunk, zones, out); err != nil {
			return nil, fmt.Errorf("cloudkit: delete: %w", err)
		}
	}
	return out, nil
}

// Changes implements transport.Transport. since and NewSeq are the bridge's
// cursor for the zone; a record's RecordSeq is its tag_seq — opaque, never
// comparable with a cursor.
func (c *Client) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	ckZone, err := zoneName(c.c.HubID, zone)
	if err != nil {
		return transport.Batch{}, err
	}
	resp, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_Changes{Changes: &bridgepb.Changes{Zone: ckZone, Since: since}}})
	if err != nil {
		return transport.Batch{}, fmt.Errorf("cloudkit: changes: %w", err)
	}
	b := resp.GetBatch()
	if b == nil {
		return transport.Batch{}, errUnexpected
	}
	out := transport.Batch{Deleted: b.GetDeleted(), NewSeq: b.GetNewSeq(), More: b.GetMore(), Reset: since == 0}
	for _, r := range b.GetChanged() {
		out.Changed = append(out.Changed, stored(zone, r))
	}
	return out, nil
}

// Download implements transport.Transport. The bridge writes the sealed
// bytes into <hub dir>/downloads; the client moves that file to dst (0600).
func (c *Client) Download(ctx context.Context, zone, attachmentID, dst string) error {
	ckZone, err := zoneName(c.c.HubID, zone)
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
	if _, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_Download{Download: &bridgepb.Download{
		Zone: ckZone, AssetId: attachmentID, Dst: part,
	}}}); err != nil {
		return fmt.Errorf("cloudkit: download: %w", err)
	}
	return moveDownload(part, dst)
}

// errUnexpected: the bridge answered with another kind of result.
var errUnexpected = errors.New("cloudkit: unexpected bridge answer")

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

func wireExpect(e transport.Expect) (*bridgepb.Expect, error) {
	switch e.Mode {
	case transport.ExpectNone:
		return nil, nil
	case transport.ExpectAbsent:
		return &bridgepb.Expect{Mode: bridgepb.ExpectMode_EXPECT_ABSENT}, nil
	case transport.ExpectSeq:
		return &bridgepb.Expect{Mode: bridgepb.ExpectMode_EXPECT_SEQ, TagSeq: e.Seq}, nil
	}
	return nil, fmt.Errorf("cloudkit: unknown expect mode %d", e.Mode)
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

// fillOutcomes copies an Outcomes answer for the items at index (zones by
// item) into out; an answer that does not cover the request exactly is an
// error.
func fillOutcomes(resp *bridgepb.Response, index []int, zones []string, out []transport.Outcome) error {
	got := resp.GetOutcomes()
	if got == nil || len(got.GetItems()) != len(index) {
		return fmt.Errorf("outcomes do not match the request: %w", errUnexpected)
	}
	for k, o := range got.GetItems() {
		i := index[k]
		switch {
		case o.GetRefusedClass() != "":
			out[i] = transport.Outcome{Refused: classError(o.GetRefusedClass())}
		case o.GetSaved():
			out[i] = transport.Outcome{Saved: true, RecordSeq: o.GetTagSeq()}
		case o.GetConflict() != nil:
			s := stored(zones[i], o.GetConflict())
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

// classError maps a bridge error class to the transport's errors; the class
// is carried, never the bridge's text.
func classError(class string) error {
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
	case "forbidden":
		base = transport.ErrForbidden
	case "unsupported_zone":
		base = transport.ErrUnsupportedZone
	case "unsupported_version":
		base = transport.ErrUnsupportedVersion
	default:
		return fmt.Errorf("cloudkit: bridge failure %q", safeClass(class))
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

// checkSocket refuses a socket file that is not a socket, is open to anyone
// but its owner, or is owned by another user.
func checkSocket(path string) error {
	fi, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("cloudkit: bridge not running: %w", transport.ErrUnavailable)
	}
	if fi.Mode().Type() != fs.ModeSocket {
		return errors.New("cloudkit: the bridge socket path is not a socket")
	}
	if fi.Mode().Perm()&0o077 != 0 {
		return errors.New("cloudkit: the bridge socket is open to other users")
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Getuid() {
		return errors.New("cloudkit: the bridge socket belongs to another user")
	}
	return nil
}

// conn is one connection to the bridge: frames out under wmu, answers routed
// to their pending request by id.
type conn struct {
	uc   *net.UnixConn
	wmu  sync.Mutex
	dead chan struct{}
	once sync.Once

	mu      sync.Mutex
	pending map[uint64]chan *bridgepb.Response
}

func (k *conn) close() {
	k.once.Do(func() {
		close(k.dead)
		_ = k.uc.Close()
	})
}

func (k *conn) alive() bool {
	select {
	case <-k.dead:
		return false
	default:
		return true
	}
}

// write sends one frame, bounded by ctx's deadline or writeTimeout.
func (k *conn) write(ctx context.Context, req *bridgepb.Request) error {
	frame, err := EncodeFrame(req)
	if err != nil {
		return err
	}
	k.wmu.Lock()
	defer k.wmu.Unlock()
	deadline := time.Now().Add(writeTimeout)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	if err := k.uc.SetWriteDeadline(deadline); err != nil {
		return err
	}
	_, err = k.uc.Write(frame)
	return err
}

// do sends req on the current connection (connecting first when there is
// none) and waits for its answer; a Failure answer is its class's error.
func (c *Client) do(ctx context.Context, req *bridgepb.Request) (*bridgepb.Response, error) {
	k, err := c.connect(ctx)
	if err != nil {
		return nil, err
	}
	return c.roundTrip(ctx, k, req)
}

func (c *Client) roundTrip(ctx context.Context, k *conn, req *bridgepb.Request) (*bridgepb.Response, error) {
	c.mu.Lock()
	c.nextID++
	req.Id = c.nextID
	c.mu.Unlock()
	ch := make(chan *bridgepb.Response, 1)
	k.mu.Lock()
	k.pending[req.Id] = ch
	k.mu.Unlock()
	defer func() {
		k.mu.Lock()
		delete(k.pending, req.Id)
		k.mu.Unlock()
	}()
	if err := k.write(ctx, req); err != nil {
		if errors.Is(err, ErrFrameTooLarge) {
			return nil, fmt.Errorf("cloudkit: %w", transport.ErrRecordTooLarge)
		}
		k.close()
		return nil, fmt.Errorf("cloudkit: bridge write failed: %w", transport.ErrUnavailable)
	}
	select {
	case r := <-ch:
		if f := r.GetFailure(); f != nil {
			return nil, classError(f.GetClass())
		}
		return r, nil
	case <-k.dead:
		return nil, fmt.Errorf("cloudkit: bridge connection lost: %w", transport.ErrUnavailable)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// connect returns the live connection or makes one: the socket must be a
// 0600 socket of this user, the process behind it must run as this user
// (checked before any frame is written), and the bridge must answer Hello
// with this protocol version.
func (c *Client) connect(ctx context.Context) (*conn, error) {
	if k, err := c.current(); k != nil || err != nil {
		return k, err
	}
	c.dial.Lock()
	defer c.dial.Unlock()
	if k, err := c.current(); k != nil || err != nil {
		return k, err
	}
	path := filepath.Join(c.c.Dir, SocketName)
	if err := checkSocket(path); err != nil {
		return nil, err
	}
	var d net.Dialer
	nc, err := d.DialContext(ctx, "unix", path)
	if err != nil {
		return nil, fmt.Errorf("cloudkit: bridge not reachable: %w", transport.ErrUnavailable)
	}
	uc, ok := nc.(*net.UnixConn)
	if !ok {
		_ = nc.Close()
		return nil, errors.New("cloudkit: the bridge socket is not a unix socket")
	}
	if uid, err := c.peerUID(uc); err != nil || uid != os.Getuid() {
		_ = uc.Close()
		return nil, errors.New("cloudkit: a bridge of another user refused")
	}
	k := &conn{uc: uc, dead: make(chan struct{}), pending: map[uint64]chan *bridgepb.Response{}}
	go c.read(k)
	resp, err := c.roundTrip(ctx, k, &bridgepb.Request{Op: &bridgepb.Request_Hello{Hello: &bridgepb.Hello{
		Version: ProtocolVersion, HubId: c.c.HubID,
	}}})
	if err == nil && resp.GetHello().GetVersion() != ProtocolVersion {
		err = fmt.Errorf("cloudkit: bridge protocol: %w", transport.ErrUnsupportedVersion)
	}
	if err != nil {
		k.close()
		return nil, err
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		k.close()
		return nil, errClosed
	}
	c.conn = k
	again := c.connected
	c.connected = true
	c.mu.Unlock()
	if again {
		c.emit(transport.Event{PullNow: true})
	}
	return k, nil
}

func (c *Client) current() (*conn, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil, errClosed
	}
	if c.conn != nil && c.conn.alive() {
		return c.conn, nil
	}
	return nil, nil
}

// read routes the bridge's frames until the connection ends; a connection
// that was the client's current one ending is an Err event.
func (c *Client) read(k *conn) {
	for {
		var r bridgepb.Response
		if _, err := ReadFrame(k.uc, &r); err != nil {
			k.close()
			break
		}
		if r.GetId() == 0 {
			if e, ok := c.eventOf(r.GetEvent()); ok {
				c.emit(e)
			}
			continue
		}
		k.mu.Lock()
		ch := k.pending[r.GetId()]
		delete(k.pending, r.GetId())
		k.mu.Unlock()
		if ch != nil {
			ch <- &r
		}
	}
	c.mu.Lock()
	current := c.conn == k
	if current {
		c.conn = nil
	}
	c.mu.Unlock()
	if current {
		c.emit(transport.Event{Err: fmt.Errorf("cloudkit: bridge connection lost: %w", transport.ErrUnavailable)})
	}
}

// eventOf is a bridge event as a transport event: a zone of this hub (by its
// CloudKit name, as MailboxFor and DataZoneName give it), a pull_now, or an
// error class. Anything else is dropped.
func (c *Client) eventOf(ev *bridgepb.Event) (transport.Event, bool) {
	switch {
	case ev == nil:
		return transport.Event{}, false
	case ev.GetPullNow():
		return transport.Event{PullNow: true}, true
	case ev.GetErrorClass() != "":
		return transport.Event{Err: classError(ev.GetErrorClass())}, true
	case ev.GetZone() == DataZoneName(c.c.HubID), ev.GetZone() == RelayZoneName(c.c.HubID):
		return transport.Event{Zone: ev.GetZone()}, true
	}
	return transport.Event{}, false
}

// emit queues e without blocking the socket reader: straight into the
// channel while nothing waits, else into pending (a zone event or a pull_now
// already waiting absorbs an equal one) for the pump.
func (c *Client) emit(e transport.Event) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	if !c.pumping {
		select {
		case c.events <- e:
			return
		default:
		}
	}
	if e.Err == nil && e.Control == nil {
		for _, p := range c.pending {
			if p.Err == nil && p.Control == nil && p.Zone == e.Zone && p.PullNow == e.PullNow {
				return
			}
		}
	}
	c.pending = append(c.pending, e)
	if !c.pumping {
		c.pumping = true
		go c.pump()
	}
}

// pump delivers pending in order and exits once it is empty or the client
// closed.
func (c *Client) pump() {
	for {
		c.mu.Lock()
		if len(c.pending) == 0 || c.closed {
			c.pumping, c.pending = false, nil
			c.mu.Unlock()
			return
		}
		e := c.pending[0]
		c.pending = c.pending[1:]
		c.mu.Unlock()
		select {
		case c.events <- e:
		case <-c.done:
			return
		}
	}
}
