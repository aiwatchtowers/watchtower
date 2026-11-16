package chatengine

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/ownerconfirm"
	"watchtower/internal/platform"
)

// frame is one line the server wrote: an answer (ID set) or an event.
type frame struct {
	ID     string          `json:"id"`
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
	Event        string `json:"event"`
	Subscription string `json:"subscription"`
	Conversation int64  `json:"conversation_id"`
	Snapshot     *Feed  `json:"snapshot"`
	Message      *struct {
		ID     int64  `json:"id"`
		Status string `json:"status"`
		Text   string `json:"text"`
	} `json:"message"`
	List *List `json:"list"`
}

// client is the test's end of one chat.sock connection.
type client struct {
	t    testing.TB
	conn net.Conn
	r    *bufio.Reader
}

func newClient(t testing.TB, conn net.Conn) *client {
	t.Helper()
	t.Cleanup(func() { _ = conn.Close() })
	return &client{t: t, conn: conn, r: bufio.NewReader(conn)}
}

// send writes one request line.
func (c *client) send(id, op string, params any) {
	c.t.Helper()
	req := map[string]any{"id": id, "op": op}
	if params != nil {
		req["params"] = params
	}
	b, err := json.Marshal(req)
	require.NoError(c.t, err)
	_, err = c.conn.Write(append(b, '\n'))
	require.NoError(c.t, err)
}

// next is the server's next line; ok is false once the connection ended.
func (c *client) next() (frame, bool) {
	c.t.Helper()
	line, err := c.r.ReadBytes('\n')
	if err != nil {
		return frame{}, false
	}
	var f frame
	require.NoError(c.t, json.Unmarshal(line, &f), string(line))
	return f, true
}

func (c *client) mustNext() frame {
	c.t.Helper()
	f, ok := c.next()
	require.True(c.t, ok, "the connection ended")
	return f
}

// ended: the server closed the connection.
func (c *client) ended() bool {
	_, err := c.r.ReadByte()
	return err != nil
}

// hello sends hello and returns its result's ops.
func (c *client) hello() []string {
	c.t.Helper()
	c.send("h", "hello", map[string]any{"protocol": ProtocolVersion, "client": "mac", "part_kinds": []string{"text"}})
	f := c.mustNext()
	require.True(c.t, f.OK, "hello refused: %+v", f.Error)
	var res struct {
		Protocol int      `json:"protocol"`
		Ops      []string `json:"ops"`
	}
	require.NoError(c.t, json.Unmarshal(f.Result, &res))
	require.Equal(c.t, ProtocolVersion, res.Protocol)
	return res.Ops
}

// allow and refuse are VerifyApp/VerifyCLI stubs.
func allow(context.Context, ownerconfirm.PeerToken) error { return nil }
func refuse(context.Context, ownerconfirm.PeerToken) error {
	return errors.New("not signed by the team")
}

// appOnly is a server that takes every peer as the app.
var appOnly = ServerOptions{VerifyApp: allow, VerifyCLI: refuse}

// shortTempDir is a folder short enough for a socket path on darwin.
func shortTempDir(t testing.TB) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "wtc")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

// serveSocket serves e on a real chat.sock in a temp folder until the test
// ends; it returns the socket's path.
func serveSocket(t testing.TB, e *Engine, o ServerOptions) string {
	t.Helper()
	path := filepath.Join(shortTempDir(t), "ws", SocketName)
	l, err := Listen(path)
	require.NoError(t, err)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- NewServer(e, o).Serve(ctx, l) }()
	t.Cleanup(func() {
		cancel()
		assert.NoError(t, <-done)
	})
	return path
}

func dialSocket(t testing.TB, path string) *client {
	t.Helper()
	conn, err := net.Dial("unix", path)
	require.NoError(t, err)
	return newClient(t, conn)
}

// pipeListener is an in-memory listener for tests inside a synctest bubble
// (a goroutine in a real Accept or Read is not durably blocked).
type pipeListener struct {
	conns chan net.Conn
	done  chan struct{}
	once  sync.Once
}

func newPipeListener() *pipeListener {
	return &pipeListener{conns: make(chan net.Conn), done: make(chan struct{})}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error   { l.once.Do(func() { close(l.done) }); return nil }
func (l *pipeListener) Addr() net.Addr { return &net.UnixAddr{Name: "pipe", Net: "unix"} }

func (l *pipeListener) dial(t *testing.T) *client {
	t.Helper()
	a, b := net.Pipe()
	l.conns <- b
	return newClient(t, a)
}

// servePipe serves e over an in-memory listener; every peer is this
// process (uid) as pid 4242.
func servePipe(t *testing.T, e *Engine, o ServerOptions) *pipeListener {
	t.Helper()
	l := newPipeListener()
	s := NewServer(e, o)
	s.peer = func(net.Conn) peerCreds { return peerCreds{uid: os.Getuid()} }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Serve(ctx, l) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	return l
}

func convCount(t *testing.T, g *rig) int {
	t.Helper()
	var n int
	require.NoError(t, g.d.QueryRow(`SELECT COUNT(*) FROM chat_conversations`).Scan(&n))
	return n
}

// TestChatengine_UnsignedPeerRefused: a peer that is neither the signed app
// nor this team's CLI gets forbidden on its hello, the connection closes,
// and nothing it sent is applied. The verifier sees the real peer's pid.
func TestChatengine_UnsignedPeerRefused(t *testing.T) {
	g := newRig(t, fakeOpts{})
	var seen atomic.Int64
	verify := func(_ context.Context, tok ownerconfirm.PeerToken) error {
		seen.Store(int64(tok.PID()))
		return errors.New("unsigned")
	}
	path := serveSocket(t, g.r, ServerOptions{VerifyApp: verify, VerifyCLI: verify})
	before := convCount(t, g)

	c := dialSocket(t, path)
	c.send("1", "hello", map[string]any{"protocol": 1, "client": "mac"})
	f := c.mustNext()
	assert.Equal(t, "1", f.ID)
	assert.False(t, f.OK)
	require.NotNil(t, f.Error)
	assert.Equal(t, "forbidden", f.Error.Code)
	_, _ = c.conn.Write([]byte(`{"id":"2","op":"chat_new","params":{}}` + "\n"))
	assert.True(t, c.ended(), "the connection stays open after forbidden")
	assert.Equal(t, int64(os.Getpid()), seen.Load(), "the verifier got the socket peer's audit token")
	assert.Equal(t, before, convCount(t, g), "a refused peer wrote a row")
}

// TestChatengine_CLIPeerMayOnlyShutdown: a peer verified as this team's CLI
// may say hello and ask for chat_shutdown, nothing else.
func TestChatengine_CLIPeerMayOnlyShutdown(t *testing.T) {
	g := newRig(t, fakeOpts{})
	var shutdowns atomic.Int32
	var kind atomic.Value
	g.r.Register("chat_shutdown", func(_ context.Context, _ json.RawMessage, c Client) (any, error) {
		shutdowns.Add(1)
		kind.Store(c.Kind)
		return struct{}{}, nil
	})
	path := serveSocket(t, g.r, ServerOptions{VerifyApp: refuse, VerifyCLI: allow})
	conv := newConversation(t, g.d)

	c := dialSocket(t, path)
	assert.Equal(t, []string{"hello", "chat_shutdown"}, c.hello())
	for i, op := range []string{"chat_turn", "chat_new", "subscribe", "chat_page", "unsubscribe", "no_such_op"} {
		id := strconv.Itoa(i)
		c.send(id, op, map[string]any{"conversation_id": conv, "mode": "send", "text": "hi", "list": true})
		f := c.mustNext()
		assert.Equal(t, id, f.ID)
		require.NotNil(t, f.Error, op)
		assert.Equal(t, "forbidden", f.Error.Code, op)
	}
	c.send("s", "chat_shutdown", nil)
	f := c.mustNext()
	assert.True(t, f.OK, "%+v", f.Error)
	assert.Equal(t, int32(1), shutdowns.Load())
	assert.Equal(t, "cli", kind.Load(), `a CLI peer saying client "mac" is never Kind mac`)
	assert.Zero(t, ownerRows(t, g.d, conv), "a CLI peer started a turn")
}

// TestServer_HelloRequired: a first request other than hello is invalid and
// closes the connection; so is a first line that is no JSON.
func TestServer_HelloRequired(t *testing.T) {
	g := newRig(t, fakeOpts{})
	path := serveSocket(t, g.r, appOnly)

	c := dialSocket(t, path)
	c.send("1", "chat_new", map[string]any{})
	f := c.mustNext()
	assert.Equal(t, "1", f.ID)
	require.NotNil(t, f.Error)
	assert.Equal(t, "invalid", f.Error.Code)
	assert.True(t, c.ended())
	assert.Zero(t, convCount(t, g))

	c = dialSocket(t, path)
	_, err := c.conn.Write([]byte("not json\n"))
	require.NoError(t, err)
	f = c.mustNext()
	require.NotNil(t, f.Error)
	assert.Equal(t, "invalid", f.Error.Code)
	assert.True(t, c.ended())

	// After hello, a second hello is invalid but the connection stays.
	c = dialSocket(t, path)
	c.hello()
	c.send("2", "hello", map[string]any{"protocol": 1, "client": "mac"})
	f = c.mustNext()
	require.NotNil(t, f.Error)
	assert.Equal(t, "invalid", f.Error.Code)
	c.send("3", "chat_new", map[string]any{})
	f = c.mustNext()
	assert.True(t, f.OK, "%+v", f.Error)
}

// TestServer_OversizeLineRefused: a request line longer than 2 MiB is
// invalid and closes the connection, unread past the cap.
func TestServer_OversizeLineRefused(t *testing.T) {
	g := newRig(t, fakeOpts{})
	path := serveSocket(t, g.r, appOnly)
	c := dialSocket(t, path)
	c.hello()

	line := make([]byte, MaxRequestBytes+2)
	for i := range line {
		line[i] = 'a'
	}
	line[len(line)-1] = '\n' // MaxRequestBytes + 1 bytes, then the newline
	go func() { _, _ = c.conn.Write(line) }()
	f := c.mustNext()
	require.NotNil(t, f.Error)
	assert.Equal(t, "invalid", f.Error.Code)
	assert.True(t, c.ended())

	// Exactly MaxRequestBytes is read (and refused only as bad JSON).
	c = dialSocket(t, path)
	c.hello()
	line = line[:MaxRequestBytes+1]
	line[len(line)-1] = '\n'
	go func() { _, _ = c.conn.Write(line) }()
	f = c.mustNext()
	require.NotNil(t, f.Error)
	assert.Equal(t, "invalid", f.Error.Code)
	c.send("x", "chat_new", map[string]any{})
	f = c.mustNext()
	assert.True(t, f.OK, "a line at the cap closed the connection: %+v", f.Error)
}

// TestServer_SecondListenerRefused: one engine per socket.
func TestServer_SecondListenerRefused(t *testing.T) {
	path := filepath.Join(shortTempDir(t), "ws", SocketName)
	l, err := Listen(path)
	require.NoError(t, err)
	defer func() { _ = l.Close() }()
	_, err = Listen(path)
	assert.ErrorIs(t, err, platform.ErrSocketBusy)
}

// TestServer_SocketModes: the socket is 0600 and its folder 0700, even when
// the folder existed with wider modes.
func TestServer_SocketModes(t *testing.T) {
	dir := filepath.Join(shortTempDir(t), "ws")
	require.NoError(t, os.Mkdir(dir, 0o755))
	require.NoError(t, os.Chmod(dir, 0o755))
	path := filepath.Join(dir, SocketName)
	l, err := Listen(path)
	require.NoError(t, err)
	defer func() { _ = l.Close() }()
	fi, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())
	di, err := os.Stat(dir)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), di.Mode().Perm())

	// A fallback folder under the temp folder is made 0700 too.
	nested := filepath.Join(shortTempDir(t), "wtchat-x", SocketName)
	l2, err := Listen(nested)
	require.NoError(t, err)
	defer func() { _ = l2.Close() }()
	di, err = os.Stat(filepath.Dir(nested))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), di.Mode().Perm())
}

// TestServer_AnswerEchoesID: each answer carries its request's id, errors
// included, whatever order they finish in.
func TestServer_AnswerEchoesID(t *testing.T) {
	g := newRig(t, fakeOpts{})
	path := serveSocket(t, g.r, appOnly)
	c := dialSocket(t, path)
	c.hello()
	c.send("alpha", "chat_new", map[string]any{})
	c.send("beta", "chat_cancel", map[string]any{"conversation_id": 999, "turn_id": "t"})
	c.send("gamma", "no_such_op", nil)
	c.send("delta", "chat_page", map[string]any{"conversation_id": "x"})
	got := map[string]frame{}
	for range 4 {
		f := c.mustNext()
		got[f.ID] = f
	}
	assert.True(t, got["alpha"].OK)
	assert.Contains(t, string(got["alpha"].Result), "conversation_id")
	require.NotNil(t, got["beta"].Error)
	assert.Equal(t, "not_found", got["beta"].Error.Code)
	require.NotNil(t, got["gamma"].Error)
	assert.Equal(t, "invalid", got["gamma"].Error.Code)
	require.NotNil(t, got["delta"].Error)
	assert.Equal(t, "invalid", got["delta"].Error.Code)
}

// subscribeID subscribes and returns the subscription's id.
func (c *client) subscribe(id string, params map[string]any) string {
	c.t.Helper()
	c.send(id, "subscribe", params)
	f := c.mustNext()
	require.Equal(c.t, id, f.ID)
	require.True(c.t, f.OK, "%+v", f.Error)
	var res struct {
		Subscription string `json:"subscription"`
	}
	require.NoError(c.t, json.Unmarshal(f.Result, &res))
	require.NotEmpty(c.t, res.Subscription)
	return res.Subscription
}

// TestServer_SubscribeConversationSnapshotThenEvents: a conversation's
// subscription answers, then sends its snapshot, then the running turn's
// message_upsert, every event tagged with the subscription.
func TestServer_SubscribeConversationSnapshotThenEvents(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, text: "streamed"})
		conv := newConversation(t, g.d)
		l := servePipe(t, g.r, appOnly)
		c := l.dial(t)
		c.hello()
		sub := c.subscribe("s", map[string]any{"conversation_id": conv})

		f := c.mustNext()
		assert.Equal(t, EventSnapshot, f.Event)
		assert.Equal(t, sub, f.Subscription)
		require.NotNil(t, f.Snapshot)
		assert.Empty(t, f.Snapshot.Messages)

		st, err := g.r.Turn(context.Background(), turnReq(conv, "hello", ""))
		require.NoError(t, err)
		var upserts []frame
		for len(upserts) == 0 || upserts[len(upserts)-1].Message.ID != st.AssistantMessageID ||
			upserts[len(upserts)-1].Message.Text != "streamed" {
			f := c.mustNext()
			assert.Equal(t, sub, f.Subscription)
			if f.Event == EventMessageUpsert {
				upserts = append(upserts, f)
			} else {
				assert.Contains(t, []string{EventSnapshot, EventConversationUpdate}, f.Event)
			}
		}
		g.f.all()[0].finish()
		for {
			f := c.mustNext()
			if f.Event == EventMessageUpsert && f.Message.ID == st.AssistantMessageID && f.Message.Status == chatstore.StatusComplete {
				break
			}
		}
	})
}

// TestServer_SubscribeListSnapshotThenUpdates: the list subscription sends
// the list, then a list_update after a new conversation.
func TestServer_SubscribeListSnapshotThenUpdates(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		l := servePipe(t, g.r, appOnly)
		c := l.dial(t)
		c.hello()
		sub := c.subscribe("s", map[string]any{"list": true})
		f := c.mustNext()
		assert.Equal(t, EventSnapshot, f.Event)
		assert.Equal(t, sub, f.Subscription)
		require.NotNil(t, f.List)
		assert.Empty(t, f.List.Conversations)

		c.send("n", "chat_new", map[string]any{})
		var got []frame
		for len(got) < 2 {
			got = append(got, c.mustNext())
		}
		var answered, updated bool
		for _, f := range got {
			switch {
			case f.ID == "n":
				answered = f.OK
			case f.Event == EventListUpdate:
				updated = f.Subscription == sub && f.List != nil && len(f.List.Conversations) == 1
			}
		}
		assert.True(t, answered)
		assert.True(t, updated, "%+v", got)
	})
}

// TestServer_UnsubscribeStopsEvents: after unsubscribe's ok, a new turn
// sends nothing for that subscription (the other one still gets it).
func TestServer_UnsubscribeStopsEvents(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		conv := newConversation(t, g.d)
		l := servePipe(t, g.r, appOnly)
		c := l.dial(t)
		c.hello()
		gone := c.subscribe("a", map[string]any{"conversation_id": conv})
		require.Equal(t, EventSnapshot, c.mustNext().Event)
		kept := c.subscribe("b", map[string]any{"list": true})
		require.Equal(t, EventSnapshot, c.mustNext().Event)

		c.send("u", "unsubscribe", map[string]any{"subscription": gone})
		f := c.mustNext()
		require.Equal(t, "u", f.ID)
		require.True(t, f.OK)
		c.send("u2", "unsubscribe", map[string]any{"subscription": gone})
		f = c.mustNext()
		require.NotNil(t, f.Error)
		assert.Equal(t, "not_found", f.Error.Code)

		_, err := g.r.Turn(context.Background(), turnReq(conv, "hello", ""))
		require.NoError(t, err)
		f = c.mustNext() // the list's update: the turn reached the other subscription
		assert.Equal(t, kept, f.Subscription)
		// Everything written in the next seconds (fake time) is read.
		require.NoError(t, c.conn.SetReadDeadline(time.Now().Add(5*time.Second)))
		for {
			f, ok := c.next()
			if !ok {
				break
			}
			assert.NotEqual(t, gone, f.Subscription, "an event after unsubscribe: %+v", f)
		}
	})
}

// TestServer_SubscribeBeforeMessageIDReturnsThatPage: before_message_id M
// snapshots the 60 messages ending just before M.
func TestServer_SubscribeBeforeMessageIDReturnsThatPage(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		conv := newConversation(t, g.d)
		var ids []int64
		var parent any
		for i := range 2*PageSize + 10 {
			res, err := g.d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, parent_id, status)
				VALUES (?, 'user', ?, ?, ?, 'complete')`, conv, "m"+strconv.Itoa(i), i+1, parent)
			require.NoError(t, err)
			id, _ := res.LastInsertId()
			ids = append(ids, id)
			parent = id
		}
		_, err := g.d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, parent, conv)
		require.NoError(t, err)
		before := ids[100]

		l := servePipe(t, g.r, appOnly)
		c := l.dial(t)
		c.hello()
		c.subscribe("s", map[string]any{"conversation_id": conv, "before_message_id": before})
		f := c.mustNext()
		require.Equal(t, EventSnapshot, f.Event)
		require.NotNil(t, f.Snapshot)
		msgs := f.Snapshot.Messages
		require.Len(t, msgs, PageSize)
		assert.Equal(t, ids[100-PageSize], msgs[0].ID)
		assert.Equal(t, ids[99], msgs[len(msgs)-1].ID)
	})
}

// TestServer_SlowConnectionGetsResyncThenSnapshot: a client that stops
// reading while a turn streams falls behind the subscription's queue (the
// only queue, Ruling F3); once it reads again it gets one resync and then a
// fresh snapshot that holds the turn's end.
func TestServer_SlowConnectionGetsResyncThenSnapshot(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, text: "x"})
		conv := newConversation(t, g.d)
		st, err := g.r.Turn(context.Background(), turnReq(conv, "go", ""))
		require.NoError(t, err)
		synctest.Wait()
		l := servePipe(t, g.r, appOnly)
		c := l.dial(t)
		c.hello()
		sub := c.subscribe("s", map[string]any{"conversation_id": conv})

		// The client reads nothing while the turn streams.
		p := g.f.all()[0]
		for range subscriptionQueue + 20 {
			p.emit(chat.Event{Type: chat.EventTextDelta, TurnID: st.TurnID, Text: "y"})
			time.Sleep(FeedCoalesce + 10*time.Millisecond)
		}
		p.finish()
		time.Sleep(time.Second)
		synctest.Wait()

		var resync bool
		for {
			f := c.mustNext()
			assert.Equal(t, sub, f.Subscription)
			if f.Event == EventResync {
				resync = true
				continue
			}
			if resync {
				require.Equal(t, EventSnapshot, f.Event, "the resync is followed by a snapshot")
				require.NotNil(t, f.Snapshot)
				last := f.Snapshot.Messages[len(f.Snapshot.Messages)-1]
				assert.Equal(t, st.AssistantMessageID, last.ID)
				assert.Equal(t, chatstore.StatusComplete, last.Status)
				break
			}
		}
		assert.True(t, resync)
	})
}

// TestServer_EngineClosedAnswersClosed: once the engine closed, an
// operation is answered closed (the daemon stops).
func TestServer_EngineClosedAnswersClosed(t *testing.T) {
	g := newRig(t, fakeOpts{})
	path := serveSocket(t, g.r, appOnly)
	c := dialSocket(t, path)
	c.hello()
	require.NoError(t, g.r.Close(context.Background()))
	conv := newConversation(t, g.d)
	c.send("1", "chat_turn", map[string]any{"conversation_id": conv, "mode": "send", "text": "x"})
	c.send("2", "subscribe", map[string]any{"list": true})
	for range 2 {
		f := c.mustNext()
		require.NotNil(t, f.Error, f.ID)
		assert.Equal(t, "closed", f.Error.Code, f.ID)
	}
}

// helloOps keeps the ops' order stable.
func TestServer_HelloListsOps(t *testing.T) {
	g := newRig(t, fakeOpts{})
	path := serveSocket(t, g.r, appOnly)
	ops := dialSocket(t, path).hello()
	assert.Equal(t, []string{"hello", "subscribe", "unsubscribe"}, ops[:3])
	assert.Contains(t, ops, "chat_turn")
	assert.True(t, strings.Join(ops, ",") != "")
}

// TestServer_HelloPartKindsAreAlwaysASet: a socket client's part kinds reach
// the engine as a set — the ones it named, or an empty, non-nil set when it
// named none or sent no part_kinds (fallbacks only, D15); only the
// in-process relay passes nil (all kinds, D21).
func TestServer_HelloPartKindsAreAlwaysASet(t *testing.T) {
	g := newRig(t, fakeOpts{})
	g.r.Register("test_client", func(_ context.Context, _ json.RawMessage, c Client) (any, error) {
		return map[string]any{"nil": c.PartKinds == nil, "kinds": c.PartKinds, "kind": c.Kind}, nil
	})
	path := serveSocket(t, g.r, appOnly)
	for name, params := range map[string]map[string]any{
		"absent": {"protocol": 1, "client": "mac"},
		"empty":  {"protocol": 1, "client": "mac", "part_kinds": []string{}},
		"named":  {"protocol": 1, "client": "mac", "part_kinds": []string{"text", "steps"}},
	} {
		c := dialSocket(t, path)
		c.send("h", "hello", params)
		require.True(t, c.mustNext().OK, name)
		c.send("1", "test_client", nil)
		f := c.mustNext()
		require.True(t, f.OK, name)
		var res struct {
			Nil   bool            `json:"nil"`
			Kinds map[string]bool `json:"kinds"`
			Kind  string          `json:"kind"`
		}
		require.NoError(t, json.Unmarshal(f.Result, &res))
		assert.False(t, res.Nil, "%s: nil part kinds (all) on chat.sock", name)
		assert.Equal(t, "mac", res.Kind, "the signed app reaches the engine as Kind mac")
		if name == "named" {
			assert.Equal(t, map[string]bool{"text": true, "steps": true}, res.Kinds)
		} else {
			assert.Empty(t, res.Kinds, name)
		}
	}
}

// TestServer_HelloWithoutPartKindsGetsFallbacksOnly: end to end over
// chat.sock — a client that named no part kinds gets a non-text part (the
// answer's steps) with its fallback only, in the subscription's snapshot and
// in chat_page; a client that named "steps" gets its payload (D15, F2).
func TestServer_HelloWithoutPartKindsGetsFallbacksOnly(t *testing.T) {
	g := newRig(t, fakeOpts{})
	conv := newConversation(t, g.d)
	res, err := g.d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, status) VALUES (?, 'user', 'q', 1, 'complete')`, conv)
	require.NoError(t, err)
	owner, _ := res.LastInsertId()
	res, err = g.d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, parent_id, status, turn_id)
		VALUES (?, 'assistant', 'answer', 2, ?, 'complete', 't1')`, conv, owner)
	require.NoError(t, err)
	reply, _ := res.LastInsertId()
	_, err = g.d.Exec(`INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, ok, summary, started_at, ended_at)
		VALUES (?, 1, 'tool-1', 'search_knowledge', 1, 'Searched the knowledge base', 2, 2)`, reply)
	require.NoError(t, err)
	_, err = g.d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, reply, conv)
	require.NoError(t, err)
	path := serveSocket(t, g.r, appOnly)

	stepsOf := func(msgs []FeedMessage) Part {
		t.Helper()
		for _, m := range msgs {
			if m.ID != reply {
				continue
			}
			for _, p := range m.Parts {
				if p.Kind == PartSteps {
					return p
				}
			}
		}
		t.Fatalf("no steps part on the reply: %+v", msgs)
		return Part{}
	}
	for name, hello := range map[string]map[string]any{
		"no part_kinds": {"protocol": 1, "client": "mac"},
		"steps listed":  {"protocol": 1, "client": "mac", "part_kinds": []string{PartSteps}},
	} {
		c := dialSocket(t, path)
		c.send("h", "hello", hello)
		require.True(t, c.mustNext().OK, name)
		c.subscribe("s", map[string]any{"conversation_id": conv})
		f := c.mustNext()
		require.Equal(t, EventSnapshot, f.Event, name)
		require.NotNil(t, f.Snapshot, name)
		snap := stepsOf(f.Snapshot.Messages)
		c.send("p", "chat_page", map[string]any{"conversation_id": conv, "before_message_id": reply})
		f = c.mustNext()
		require.True(t, f.OK, "%s: %+v", name, f.Error)
		var page Feed
		require.NoError(t, json.Unmarshal(f.Result, &page))
		require.NotEmpty(t, page.Messages, name) // the owner row before the reply
		for _, p := range page.Messages[0].Parts {
			if name == "no part_kinds" {
				assert.Empty(t, p.Payload, "%s: chat_page part %s kept its payload", name, p.Kind)
			}
		}
		assert.NotEmpty(t, snap.Fallback.Text, name)
		if name == "no part_kinds" {
			assert.Empty(t, snap.Payload, "a client that named no kinds got the steps payload")
		} else {
			assert.NotEmpty(t, snap.Payload, "a client that named steps lost its payload")
		}
	}
}

// TestServer_AppMustSayMac: the signed app's hello names client "mac" (the
// Kind the engine's path-taking ops require); any other client is invalid.
func TestServer_AppMustSayMac(t *testing.T) {
	g := newRig(t, fakeOpts{})
	path := serveSocket(t, g.r, appOnly)
	c := dialSocket(t, path)
	c.send("h", "hello", map[string]any{"protocol": 1, "client": "phone"})
	f := c.mustNext()
	require.NotNil(t, f.Error)
	assert.Equal(t, "invalid", f.Error.Code)
	assert.True(t, c.ended())
}
