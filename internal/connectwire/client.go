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
	if started, err := c.write(callCtx, line); err != nil {
		if started {
			// Part of the frame may be on the socket: the next line would
			// be glued to it. Drop the connection; every call gets closed.
			_ = c.conn.Close()
			return nil, errClosed
		}
		// Nothing was sent; the connection and the other calls are fine.
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, &Error{Code: CodeFailed, Message: fmt.Sprintf("%s was not sent: the connection stayed busy for %s; nothing changed, call it again", tool, CallTimeout)}
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
		return nil, &Error{Code: CodeFailed, Message: noAnswer(tool)}
	}
}

// reattachTools are the calls a repeat cannot start anything new with: a
// read, or a re-attach to the same waiting step.
var reattachTools = map[string]bool{"connect_status": true, "connect_wait": true, "request_secret": true}

// noAnswer is a timed-out call's message. The outcome is unknown: only a
// re-attach tool may simply be called again; anything else may have
// started a flow, so the agent checks connect_status first.
func noAnswer(tool string) string {
	msg := fmt.Sprintf("the Watchtower app did not answer %s within %s; ", tool, CallTimeout)
	if reattachTools[tool] {
		return msg + "call it again"
	}
	return msg + "the outcome is unknown: call connect_status before repeating it"
}

// write sends one line under the call's budget: a call cancelled or out of
// budget while it waits for the write turn sends nothing (started false),
// and the write deadline (the budget left) keeps a Desktop that stopped
// reading from hanging the call. started reports that Write was entered,
// so part of the line may be on the socket.
func (c *Client) write(ctx context.Context, line []byte) (started bool, err error) {
	select {
	case c.writeTurn <- struct{}{}:
	case <-ctx.Done():
		return false, ctx.Err()
	}
	defer func() { <-c.writeTurn }()
	if err := ctx.Err(); err != nil {
		return false, err
	}
	deadline, _ := ctx.Deadline()
	if err := c.conn.SetWriteDeadline(deadline); err != nil {
		return true, err // the socket is gone: close it like a failed write
	}
	_, err = c.conn.Write(append(line, '\n'))
	return true, err
}

// Close drops the connection; waiting calls get closed.
func (c *Client) Close() error {
	return c.conn.Close()
}
