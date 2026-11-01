package cloudkit

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit/bridgepb"
)

// ErrBridgeRefused is a bridge socket the client will not use: not a
// socket, open to other users, owned by another user, or with a process of
// another user (or of unknown credentials) behind it. Nothing is written to
// it.
var ErrBridgeRefused = errors.New("cloudkit: bridge socket refused")

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
// none) and waits for its answer; a Failure answer is its class's error, a
// quota one ErrMailboxQuota when the op is on the mailbox zone.
func (c *Client) do(ctx context.Context, req *bridgepb.Request, mailbox bool) (*bridgepb.Response, error) {
	k, err := c.connect(ctx)
	if err != nil {
		return nil, err
	}
	return c.roundTrip(ctx, k, req, mailbox)
}

func (c *Client) roundTrip(ctx context.Context, k *conn, req *bridgepb.Request, mailbox bool) (*bridgepb.Response, error) {
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
			return nil, classError(f.GetClass(), mailbox)
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
// with this protocol version and its generation.
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
		return nil, fmt.Errorf("%w: not a unix socket", ErrBridgeRefused)
	}
	if uid, err := c.peerUID(uc); err != nil || uid != os.Getuid() {
		_ = uc.Close()
		return nil, fmt.Errorf("%w: a bridge of another user", ErrBridgeRefused)
	}
	k := &conn{uc: uc, dead: make(chan struct{}), pending: map[uint64]chan *bridgepb.Response{}}
	go c.read(k)
	resp, err := c.roundTrip(ctx, k, &bridgepb.Request{Op: &bridgepb.Request_Hello{Hello: &bridgepb.Hello{
		Version: ProtocolVersion, HubId: c.c.HubID,
	}}}, false)
	switch {
	case err != nil:
	case resp.GetHello() == nil:
		err = fmt.Errorf("cloudkit: hello: %w", errUnexpected)
	case resp.GetHello().GetVersion() != ProtocolVersion:
		err = fmt.Errorf("cloudkit: bridge protocol: %w", transport.ErrUnsupportedVersion)
	default:
		_, err = c.gens.adopt(resp.GetHello().GetGeneration())
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

// checkSocket refuses (ErrBridgeRefused) a socket file that is not a
// socket, is open to anyone but its owner, or is owned by another user; a
// missing one is ErrUnavailable (the bridge is not running).
func checkSocket(path string) error {
	fi, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("cloudkit: bridge not running: %w", transport.ErrUnavailable)
	}
	if fi.Mode().Type() != fs.ModeSocket {
		return fmt.Errorf("%w: the path is not a socket", ErrBridgeRefused)
	}
	if fi.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("%w: open to other users", ErrBridgeRefused)
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Getuid() {
		return fmt.Errorf("%w: owned by another user", ErrBridgeRefused)
	}
	return nil
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

// eventOf is a bridge event as a transport event: a zone of this hub under
// its runtime name (data/<relay id>, or the shared mailbox relay/<relay
// id>/*, which the runtime reads as a mailbox event), a pull_now, or an
// error class. Anything else is dropped.
func (c *Client) eventOf(ev *bridgepb.Event) (transport.Event, bool) {
	switch {
	case ev == nil:
		return transport.Event{}, false
	case ev.GetPullNow():
		return transport.Event{PullNow: true}, true
	case ev.GetAccountChanged():
		return transport.Event{AccountChanged: true}, true
	case ev.GetErrorClass() != "":
		return transport.Event{Err: classError(ev.GetErrorClass(), false)}, true
	}
	if name, ok := c.runtimeName(ev.GetZone()); ok {
		return transport.Event{Zone: name}, true
	}
	return transport.Event{}, false
}

// emit queues e without blocking the socket reader: straight into the
// channel while nothing waits, else into pending for the pump. A waiting
// event absorbs an equal one — a zone event its zone's, pull_now a
// pull_now — and a waiting error takes the place of an older one of its
// class, so the queue stays bounded by the zones, the error classes and one
// pull_now.
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
	for i, p := range c.pending {
		switch {
		case e.Err != nil && p.Err != nil && errors.Is(errKind(p.Err), errKind(e.Err)):
			c.pending[i] = e // the latest of its class
			return
		case e.Err == nil && p.Err == nil && p.Zone == e.Zone && p.PullNow == e.PullNow && p.AccountChanged == e.AccountChanged:
			return
		}
	}
	c.pending = append(c.pending, e)
	if !c.pumping {
		c.pumping = true
		go c.pump()
	}
}

// errKind is the transport error an event's error stands for.
func errKind(err error) error {
	for _, k := range []error{
		transport.ErrUnavailable, transport.ErrTokenExpired, transport.ErrRateLimited, transport.ErrRecordTooLarge,
		transport.ErrHubQuota, transport.ErrMailboxQuota, transport.ErrForbidden, transport.ErrUnsupportedZone,
		transport.ErrUnsupportedVersion, ErrBridgeRefused,
	} {
		if errors.Is(err, k) {
			return k
		}
	}
	return errBridgeFailure
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
