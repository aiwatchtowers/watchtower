package connectwire

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// errClosed is what every call gets once the run's socket is gone: the run
// ended, the Desktop refused this peer, or the connection broke.
var errClosed = &Error{Code: CodeClosed, Message: "the connect run in the Watchtower app has ended; ask the customer to start it again"}

// Client is one MCP process's connection to the run's socket. It sends the
// hello on dial; calls may overlap (each waits for the response with its
// own id).
type Client struct {
	conn net.Conn
	// writeTurn holds one token while a line is written (a lock a
	// cancelled call can stop waiting for).
	writeTurn chan struct{}
	nextID    atomic.Int64

	mu      sync.Mutex
	pending map[int64]chan Response
	closed  bool
}

// Dial connects to the run's socket and sends the hello. A refused hello
// comes back as *Error: the reply's own error (busy), or closed when the
// Desktop closed the socket (a bad token, a run that ended). The token is
// never part of an error.
func Dial(ctx context.Context, socket, token, service string) (*Client, error) {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "unix", socket)
	if err != nil {
		return nil, fmt.Errorf("connecting to the connect run: %w", errClosed)
	}
	return handshake(ctx, conn, token, service)
}

// handshake sends the hello on conn and reads its reply, then starts the
// response reader.
func handshake(ctx context.Context, conn net.Conn, token, service string) (*Client, error) {
	deadline := time.Now().Add(CallTimeout)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	if err := conn.SetDeadline(deadline); err != nil {
		_ = conn.Close()
		return nil, errClosed
	}
	line, err := json.Marshal(Hello{V: ProtocolVersion, Token: token, Service: service})
	if err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("encoding the hello: %w", err)
	}
	if _, err := conn.Write(append(line, '\n')); err != nil {
		_ = conn.Close()
		return nil, errClosed
	}
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 0, 64<<10), MaxLine)
	if !sc.Scan() {
		_ = conn.Close()
		var ne net.Error
		if errors.As(sc.Err(), &ne) && ne.Timeout() {
			return nil, &Error{Code: CodeFailed, Message: "the Watchtower app did not answer the connect run's hello"}
		}
		return nil, errClosed
	}
	var reply HelloReply
	if err := json.Unmarshal(sc.Bytes(), &reply); err != nil || !reply.OK {
		_ = conn.Close()
		if err == nil && reply.Error != nil {
			return nil, reply.Error
		}
		return nil, errClosed
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		_ = conn.Close()
		return nil, errClosed
	}
	c := &Client{conn: conn, writeTurn: make(chan struct{}, 1), pending: map[int64]chan Response{}}
	go c.read(sc)
	return c, nil
}

// read hands each response to the call waiting for its id; a response no
// call waits for (one that came after its call timed out) is dropped. When
// the socket ends, or a line is not a response, every waiting call gets
// closed.
func (c *Client) read(sc *bufio.Scanner) {
	for sc.Scan() {
		var r Response
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			break
		}
		c.mu.Lock()
		ch := c.pending[r.ID]
		delete(c.pending, r.ID)
		c.mu.Unlock()
		if ch != nil {
			ch <- r
		}
	}
	c.mu.Lock()
	c.closed = true
	for id, ch := range c.pending {
		close(ch)
		delete(c.pending, id)
	}
	c.mu.Unlock()
	_ = c.conn.Close()
}

// Call sends one tool call and waits up to CallTimeout for its response. A
// refused or failed call comes back as *Error.
func (c *Client) Call(ctx context.Context, tool string, args json.RawMessage) (json.RawMessage, error) {
	if len(args) == 0 {
		args = json.RawMessage(`{}`)
	}
	id := c.nextID.Add(1)
	line, err := json.Marshal(Request{ID: id, Tool: tool, Args: args})
	if err != nil {
		return nil, &Error{Code: CodeBadArgs, Message: "the arguments are not valid JSON"}
	}
	if len(line) >= MaxLine {
		return nil, &Error{Code: CodeBadArgs, Message: "the arguments are too long"}
	}

	ch := make(chan Response, 1)
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, errClosed
	}
	c.pending[id] = ch
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
	}()

	callCtx, cancel := context.WithTimeout(ctx, CallTimeout)
	defer cancel()
	if err := c.write(callCtx, line); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err() // cancelled before the line went out
		}
		_ = c.conn.Close()
		return nil, errClosed
	}
	select {
	case r, ok := <-ch:
		switch {
		case !ok:
			return nil, errClosed
		case r.Error != nil:
			return nil, r.Error
		case len(r.Result) == 0:
			return nil, &Error{Code: CodeFailed, Message: "the Watchtower app answered without a result"}
		}
		return r.Result, nil
	case <-callCtx.Done():
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, &Error{Code: CodeFailed, Message: fmt.Sprintf("the Watchtower app did not answer %s within %s; call it again", tool, CallTimeout)}
	}
}

// write sends one line under the call's budget: a call cancelled while it
// waits for the write turn never reaches the Desktop, and the write
// deadline (the budget left) keeps a Desktop that stopped reading from
// hanging the call.
func (c *Client) write(ctx context.Context, line []byte) error {
	select {
	case c.writeTurn <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	defer func() { <-c.writeTurn }()
	if err := ctx.Err(); err != nil {
		return err
	}
	deadline, _ := ctx.Deadline()
	if err := c.conn.SetWriteDeadline(deadline); err != nil {
		return err
	}
	_, err := c.conn.Write(append(line, '\n'))
	return err
}

// Close drops the connection; waiting calls get closed.
func (c *Client) Close() error {
	return c.conn.Close()
}
