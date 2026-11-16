package chatengine

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"slices"
	"strconv"
	"sync"
	"time"
)

// verifyBudget bounds a hello's peer checks (codesign runs twice at most).
const verifyBudget = 15 * time.Second

// A connection's peer, decided by its hello.
type role int

const (
	roleNone role = iota
	roleApp       // the signed Watchtower app: every operation
	roleCLI       // this team's CLI: hello and chat_shutdown only
)

// request is one request line.
type request struct {
	ID     string          `json:"id"`
	Op     string          `json:"op"`
	Params json.RawMessage `json:"params"`
}

// answer is a request's answer line.
type answer struct {
	ID     string          `json:"id"`
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *answerError    `json:"error,omitempty"`
}

type answerError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// wireEvent is a subscription's event as pushed: T1's Event tagged with the
// subscription it belongs to.
type wireEvent struct {
	Event
	Subscription string `json:"subscription"`
}

// conn is one chat.sock connection.
type conn struct {
	s  *Server
	nc net.Conn

	ctx    context.Context
	cancel context.CancelFunc

	// Set by the reader goroutine at hello; read by it only.
	role   role
	client Client

	// wmu serialises the writes; a connSub's stopped is guarded by it too.
	wmu sync.Mutex

	subMu   sync.Mutex
	subs    map[string]*connSub
	nextSub int

	inFlight chan struct{} // a slot per running operation
	work     sync.WaitGroup
	killOnce sync.Once
}

// connSub is one of a connection's subscriptions.
type connSub struct {
	sub     *Subscription
	stopped bool // unsubscribed: nothing more is written for it
}

func newConn(s *Server, nc net.Conn) *conn {
	ctx, cancel := context.WithCancel(context.Background())
	return &conn{s: s, nc: nc, ctx: ctx, cancel: cancel, subs: map[string]*connSub{},
		inFlight: make(chan struct{}, maxInFlight)}
}

// kill closes the connection (its reader then returns).
func (c *conn) kill() {
	c.killOnce.Do(func() {
		c.cancel()
		_ = c.nc.Close()
	})
}

// serve reads requests until the connection ends, then ends its
// subscriptions and waits for its goroutines.
func (c *conn) serve(ctx context.Context) {
	stop := context.AfterFunc(ctx, c.kill)
	defer func() {
		stop()
		c.kill()
		c.subMu.Lock()
		subs := c.subs
		c.subs = map[string]*connSub{}
		c.subMu.Unlock()
		for _, cs := range subs {
			cs.sub.Close()
		}
		c.work.Wait()
	}()
	r := bufio.NewReaderSize(c.nc, 64<<10)
	for {
		line, err := readLine(r, MaxRequestBytes)
		if errors.Is(err, errLineTooLong) {
			c.fail("", "invalid", "the request is longer than 2 MiB")
			return
		}
		if err != nil {
			return
		}
		if len(line) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil || req.Op == "" {
			c.fail(req.ID, "invalid", "the request is not a JSON object with an op")
			if c.role == roleNone {
				return
			}
			continue
		}
		if c.role == roleNone {
			if req.Op != opHello {
				c.fail(req.ID, "invalid", "the first request must be hello")
				return
			}
			if !c.hello(req) {
				return
			}
			continue
		}
		c.dispatch(req)
	}
}

// errLineTooLong: a request line over the cap.
var errLineTooLong = errors.New("chatengine: request line too long")

// readLine reads one line, its newline dropped, refusing one longer than
// limit without reading past limit+1 bytes of it.
func readLine(r *bufio.Reader, limit int) ([]byte, error) {
	var line []byte
	for {
		chunk, err := r.ReadSlice('\n')
		line = append(line, chunk...)
		if n := len(line); n > 0 && line[n-1] == '\n' {
			line = line[:n-1]
			if len(line) > limit {
				return nil, errLineTooLong
			}
			return line, nil
		}
		if len(line) > limit {
			return nil, errLineTooLong
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if err == nil {
			err = io.ErrUnexpectedEOF
		}
		return nil, err
	}
}

// hello checks the peer and answers; false closes the connection.
func (c *conn) hello(req request) bool {
	var p struct {
		Protocol  int       `json:"protocol"`
		Client    string    `json:"client"`
		PartKinds *[]string `json:"part_kinds"`
	}
	if len(req.Params) > 0 {
		if err := json.Unmarshal(req.Params, &p); err != nil {
			c.fail(req.ID, "invalid", "bad hello params")
			return false
		}
	}
	if p.Protocol < 1 || p.Client == "" {
		c.fail(req.ID, "invalid", "hello needs protocol and client")
		return false
	}
	uid, pid, err := c.s.peer(c.nc)
	if err != nil || uid != os.Getuid() {
		logf("refused a peer whose credentials are unreadable or another user's")
		c.fail(req.ID, "forbidden", "only the Watchtower app may use the chat socket")
		return false
	}
	ctx, cancel := context.WithTimeout(c.ctx, verifyBudget)
	defer cancel()
	switch {
	case c.s.o.VerifyApp(ctx, pid) == nil:
		c.role = roleApp
	case c.s.o.VerifyCLI(ctx, pid) == nil:
		c.role = roleCLI
	default:
		logf("refused peer pid %d: not the signed Watchtower app", pid)
		c.fail(req.ID, "forbidden", "only the Watchtower app may use the chat socket")
		return false
	}
	c.client = Client{Kind: p.Client}
	if p.PartKinds != nil {
		c.client.PartKinds = make(map[string]bool, len(*p.PartKinds))
		for _, k := range *p.PartKinds {
			c.client.PartKinds[k] = true
		}
	}
	c.reply(req.ID, map[string]any{"protocol": ProtocolVersion, "ops": c.ops()})
	return true
}

// ops is what this connection's peer may send.
func (c *conn) ops() []string {
	e := c.s.e
	e.opsMu.RLock()
	defer e.opsMu.RUnlock()
	if c.role == roleCLI {
		ops := []string{opHello}
		if e.ops[opShutdown] != nil {
			ops = append(ops, opShutdown)
		}
		return ops
	}
	engine := make([]string, 0, len(e.ops))
	for op := range e.ops {
		engine = append(engine, op)
	}
	slices.Sort(engine)
	return append([]string{opHello, opSubscribe, opUnsubscribe}, engine...)
}

// dispatch answers one request after hello.
func (c *conn) dispatch(req request) {
	switch {
	case req.ID == "":
		c.fail("", "invalid", "a request needs an id")
	case req.Op == opHello:
		c.fail(req.ID, "invalid", "hello was already sent")
	case c.role == roleCLI && req.Op != opShutdown:
		c.fail(req.ID, "forbidden", "this process may only ask for the chat's shutdown")
	case req.Op == opSubscribe:
		c.subscribe(req)
	case req.Op == opUnsubscribe:
		c.unsubscribe(req)
	default:
		select {
		case c.inFlight <- struct{}{}:
		default:
			c.fail(req.ID, "busy", "too many requests at once")
			return
		}
		c.work.Add(1)
		go func() {
			defer c.work.Done()
			defer func() { <-c.inFlight }()
			res, err := c.s.e.Do(c.ctx, req.Op, req.Params, c.client)
			if err != nil {
				c.failErr(req.ID, req.Op, err)
				return
			}
			c.write(answer{ID: req.ID, OK: true, Result: res})
		}()
	}
}

// subscribe starts a subscription: the answer, then its snapshot and live
// events, each tagged with its id.
func (c *conn) subscribe(req request) {
	var p struct {
		List            bool  `json:"list"`
		ConversationID  int64 `json:"conversation_id"`
		BeforeMessageID int64 `json:"before_message_id"`
	}
	if err := decode(req.Params, &p); err != nil || p.List == (p.ConversationID > 0) || p.BeforeMessageID < 0 ||
		(p.List && p.BeforeMessageID > 0) {
		c.fail(req.ID, "invalid", "subscribe needs list or conversation_id")
		return
	}
	if c.s.engineClosed() {
		c.failErr(req.ID, req.Op, ErrClosed)
		return
	}
	sub := c.s.e.Subscribe(Target{List: p.List, Conversation: p.ConversationID, BeforeMessageID: p.BeforeMessageID}, c.client)
	c.subMu.Lock()
	c.nextSub++
	id := "s" + strconv.Itoa(c.nextSub)
	cs := &connSub{sub: sub}
	c.subs[id] = cs
	c.subMu.Unlock()
	res, _ := json.Marshal(map[string]string{"subscription": id})
	c.write(answer{ID: req.ID, OK: true, Result: res})
	c.work.Add(1)
	go c.forward(id, cs)
}

// forward writes a subscription's events until it ends. A connection that
// does not read blocks here, which fills the subscription's queue: the
// subscription then sends resync and a fresh snapshot (Ruling F3).
func (c *conn) forward(id string, cs *connSub) {
	defer c.work.Done()
	for ev := range cs.sub.Events {
		c.wmu.Lock()
		if !cs.stopped {
			c.writeLocked(wireEvent{Event: ev, Subscription: id})
		}
		c.wmu.Unlock()
	}
}

// unsubscribe ends a subscription; after its ok nothing more is written
// for it.
func (c *conn) unsubscribe(req request) {
	var p struct {
		Subscription string `json:"subscription"`
	}
	if err := decode(req.Params, &p); err != nil || p.Subscription == "" {
		c.fail(req.ID, "invalid", "unsubscribe needs a subscription")
		return
	}
	c.subMu.Lock()
	cs := c.subs[p.Subscription]
	delete(c.subs, p.Subscription)
	c.subMu.Unlock()
	if cs == nil {
		c.fail(req.ID, "not_found", "no such subscription")
		return
	}
	c.wmu.Lock()
	cs.stopped = true
	c.writeLocked(answer{ID: req.ID, OK: true, Result: json.RawMessage("{}")})
	c.wmu.Unlock()
	cs.sub.Close()
}

// reply writes an ok answer with v as its result.
func (c *conn) reply(id string, v any) {
	res, err := json.Marshal(v)
	if err != nil {
		c.fail(id, "internal", "the answer could not be encoded")
		return
	}
	c.write(answer{ID: id, OK: true, Result: res})
}

// failErr answers an operation's error by its code; an internal one is
// logged by its class only.
func (c *conn) failErr(id, op string, err error) {
	code := ErrorCode(err)
	msg := err.Error()
	if code == "internal" {
		logf("%s failed (%s)", op, errClass(err))
		msg = "the chat engine failed"
	}
	c.fail(id, code, msg)
}

func (c *conn) fail(id, code, msg string) {
	c.write(answer{ID: id, Error: &answerError{Code: code, Message: msg}})
}

// write writes one line.
func (c *conn) write(v any) {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	c.writeLocked(v)
}

// writeLocked writes one line under wmu; a failed write ends the
// connection.
func (c *conn) writeLocked(v any) {
	b, err := encodeLine(v)
	if err != nil {
		logf("a line could not be encoded (%s)", errClass(err))
		return
	}
	if _, err := c.nc.Write(b); err != nil {
		c.kill()
	}
}

// encodeLine is v's line with its newline. An ok answer's result is the
// engine's own JSON and is spliced in as it is (json.Marshal would scan
// and copy a whole page again).
func encodeLine(v any) ([]byte, error) {
	if a, ok := v.(answer); ok && a.OK && a.Error == nil && len(a.Result) > 0 {
		id, err := json.Marshal(a.ID)
		if err != nil {
			return nil, err //nolint:wrapcheck // the caller logs its class
		}
		b := make([]byte, 0, len(a.Result)+len(id)+32)
		b = append(b, `{"id":`...)
		b = append(b, id...)
		b = append(b, `,"ok":true,"result":`...)
		b = append(b, a.Result...)
		return append(b, "}\n"...), nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err //nolint:wrapcheck // the caller logs its class
	}
	return append(b, '\n'), nil
}
