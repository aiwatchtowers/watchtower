package connectwire

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/iotest"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type wireCase struct {
	Name  string `json:"name"`
	Kind  string `json:"kind"`
	Tool  string `json:"tool"`
	Shape string `json:"shape"`
	Line  string `json:"line"`
}

func loadCases(t *testing.T) []wireCase {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "wire_cases.json"))
	require.NoError(t, err)
	var f struct {
		Cases []wireCase `json:"cases"`
	}
	require.NoError(t, json.Unmarshal(b, &f))
	require.NotEmpty(t, f.Cases)
	return f.Cases
}

// strictRoundTrip decodes b into a new T refusing unknown fields and
// re-encodes it.
func strictRoundTrip[T any](t *testing.T, b []byte) []byte {
	t.Helper()
	var v T
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	require.NoError(t, dec.Decode(&v), "%s", b)
	out, err := json.Marshal(v)
	require.NoError(t, err)
	return out
}

var shapes = map[string]func(*testing.T, []byte) []byte{
	"status":        strictRoundTrip[Status],
	"started":       strictRoundTrip[Started],
	"waited":        strictRoundTrip[Waited],
	"secret":        strictRoundTrip[SecretSent],
	"pending":       strictRoundTrip[Pending],
	"choices":       strictRoundTrip[Choices],
	"company_draft": strictRoundTrip[CompanyDraft],
	"done":          strictRoundTrip[Done],
}

func TestWire_GoldenCases(t *testing.T) {
	for _, c := range loadCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			line := []byte(c.Line)
			var got []byte
			switch c.Kind {
			case "hello":
				got = strictRoundTrip[Hello](t, line)
			case "hello_reply":
				got = strictRoundTrip[HelloReply](t, line)
			case "request":
				got = strictRoundTrip[Request](t, line)
			case "response":
				var r Response
				require.NoError(t, json.Unmarshal(line, &r))
				if c.Shape == "" {
					require.NotNil(t, r.Error, "a response without a shape is an error")
					assert.Empty(t, r.Result)
				} else {
					require.Nil(t, r.Error)
					rt, ok := shapes[c.Shape]
					require.True(t, ok, "unknown shape %q", c.Shape)
					r.Result = rt(t, r.Result)
				}
				got = strictRoundTrip[Response](t, line)
				again, err := json.Marshal(r)
				require.NoError(t, err)
				assert.Equal(t, c.Line, string(again), "the result's own type re-encodes it byte-identically")
			default:
				t.Fatalf("unknown kind %q", c.Kind)
			}
			assert.Equal(t, c.Line, string(got))
		})
	}
}

// Every error code, every waiting-capable state (timeout included) and the
// hello refusal have a case: the Swift parity test reads the same file.
func TestWire_CasesCoverTheContract(t *testing.T) {
	codes := map[string]bool{}
	states := map[string]map[string]bool{}
	names := map[string]bool{}
	for _, c := range loadCases(t) {
		names[c.Name] = true
		var r Response
		if c.Kind != "response" || json.Unmarshal([]byte(c.Line), &r) != nil {
			continue
		}
		if r.Error != nil {
			codes[r.Error.Code] = true
			continue
		}
		var s struct {
			State string `json:"state"`
		}
		_ = json.Unmarshal(r.Result, &s)
		if s.State != "" {
			if states[c.Tool] == nil {
				states[c.Tool] = map[string]bool{}
			}
			states[c.Tool][s.State] = true
		}
	}
	for _, code := range []string{CodeBusy, CodePolicy, CodeLimit, CodeUnknownTool, CodeBadArgs, CodeDeclined, CodeClosed, CodeFailed} {
		assert.True(t, codes[code], "no error case for %s", code)
	}
	want := map[string][]string{
		"connect_wait":    {"connected", "failed", "waiting", "timeout"},
		"request_secret":  {"sent", "waiting", "cancelled", "timeout"},
		"connect_start":   {"waiting", "declined", "timeout"},
		"company_publish": {"waiting", "declined", "cancelled", "timeout"},
		"company_check":   {"waiting", "timeout"},
	}
	for tool, ss := range want {
		for _, s := range ss {
			assert.True(t, states[tool][s], "no %s case for %s", s, tool)
		}
	}
	for _, n := range []string{"hello", "hello_ok", "hello_busy", "choose_items", "company_draft", "start_started"} {
		assert.True(t, names[n], "no case %s", n)
	}
}

// fakeRun is a Desktop run socket: it admits a peer whose hello carries
// token, else closes.
type fakeRun struct {
	ln     net.Listener
	token  string
	handle func(r Request) *Response
}

func socketPath(t *testing.T) string {
	t.Helper()
	// t.TempDir paths can pass the 104-byte sun_path limit on macOS.
	dir, err := os.MkdirTemp("", "cw")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, "s")
}

func startFakeRun(t *testing.T, token string, handle func(Request) *Response) string {
	t.Helper()
	path := socketPath(t)
	ln, err := net.Listen("unix", path)
	require.NoError(t, err)
	f := &fakeRun{ln: ln, token: token, handle: handle}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go f.serve(conn)
		}
	}()
	t.Cleanup(func() {
		_ = ln.Close()
		<-done
	})
	return path
}

func (f *fakeRun) serve(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	sc := bufio.NewScanner(conn)
	if !sc.Scan() {
		return
	}
	var h Hello
	if json.Unmarshal(sc.Bytes(), &h) != nil || h.Token != f.token || h.V != ProtocolVersion {
		return
	}
	if _, err := conn.Write([]byte("{\"ok\":true}\n")); err != nil {
		return
	}
	for sc.Scan() {
		var r Request
		if json.Unmarshal(sc.Bytes(), &r) != nil {
			return
		}
		resp := f.handle(r)
		if resp == nil {
			return // close mid-call
		}
		b, _ := json.Marshal(resp)
		if _, err := conn.Write(append(b, '\n')); err != nil {
			return
		}
	}
}

const testToken = "1111111111111111111111111111111111111111111111111111111111111111"

func TestDial_BadTokenIsClosed(t *testing.T) {
	path := startFakeRun(t, testToken, func(Request) *Response { return nil })
	_, err := Dial(context.Background(), path, "2222", "slack")
	var we *Error
	require.ErrorAs(t, err, &we)
	assert.Equal(t, CodeClosed, we.Code)
	assert.NotContains(t, err.Error(), "2222", "the token never shows in an error")

	c, err := Dial(context.Background(), path, testToken, "slack")
	require.NoError(t, err)
	require.NoError(t, c.Close())
}

func TestDial_NoSocketIsClosed(t *testing.T) {
	_, err := Dial(context.Background(), socketPath(t), testToken, "slack")
	var we *Error
	require.ErrorAs(t, err, &we)
	assert.Equal(t, CodeClosed, we.Code)
}

// A second peer gets the pinned busy refusal (wire_cases hello_busy) as its
// *Error.
func TestDial_BusyReplyIsTheError(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, server := net.Pipe()
		defer func() { _ = server.Close() }()
		go func() {
			sc := bufio.NewScanner(server)
			if sc.Scan() {
				_, _ = server.Write([]byte(`{"ok":false,"error":{"code":"busy","message":"another assistant turn is still connected to this run"}}` + "\n"))
			}
		}()
		_, err := handshake(context.Background(), client, testToken, "slack")
		var we *Error
		require.ErrorAs(t, err, &we)
		assert.Equal(t, CodeBusy, we.Code)
	})
}

func TestCall_RoundTrip(t *testing.T) {
	path := startFakeRun(t, testToken, func(r Request) *Response {
		if r.Tool == "connect_start" {
			return &Response{ID: r.ID, Error: &Error{Code: CodeBusy, Message: "a Slack sign-in is already running"}}
		}
		return &Response{ID: r.ID, Result: json.RawMessage(`{"tool":"` + r.Tool + `","args":` + string(r.Args) + `}`)}
	})
	c, err := Dial(context.Background(), path, testToken, "slack")
	require.NoError(t, err)
	t.Cleanup(func() { _ = c.Close() })

	res, err := c.Call(context.Background(), "connect_status", nil)
	require.NoError(t, err)
	assert.JSONEq(t, `{"tool":"connect_status","args":{}}`, string(res))

	_, err = c.Call(context.Background(), "connect_start", json.RawMessage(`{"pkce":true}`))
	var we *Error
	require.ErrorAs(t, err, &we)
	assert.Equal(t, CodeBusy, we.Code)
}

func TestCall_ClosedSocketIsClosedError(t *testing.T) {
	path := startFakeRun(t, testToken, func(Request) *Response { return nil })
	c, err := Dial(context.Background(), path, testToken, "slack")
	require.NoError(t, err)
	t.Cleanup(func() { _ = c.Close() })

	_, err = c.Call(context.Background(), "connect_status", nil)
	var we *Error
	require.ErrorAs(t, err, &we)
	assert.Equal(t, CodeClosed, we.Code, "the run closed the socket mid-call")

	_, err = c.Call(context.Background(), "connect_status", nil)
	require.ErrorAs(t, err, &we)
	assert.Equal(t, CodeClosed, we.Code, "a later call on the gone socket")
}

// pipeRun serves the hello on an in-memory pipe and hands each request to
// answer (in the synctest bubble, so the fake clock runs).
func pipeRun(t *testing.T, answer func(server net.Conn, r Request)) *Client {
	t.Helper()
	client, server := net.Pipe()
	t.Cleanup(func() { _ = server.Close() })
	go func() {
		sc := bufio.NewScanner(server)
		if !sc.Scan() {
			return
		}
		if _, err := server.Write([]byte("{\"ok\":true}\n")); err != nil {
			return
		}
		for sc.Scan() {
			var r Request
			if json.Unmarshal(sc.Bytes(), &r) != nil {
				return
			}
			go answer(server, r)
		}
	}()
	c, err := handshake(context.Background(), client, testToken, "slack")
	require.NoError(t, err)
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// The Desktop answers waiting after WaitBudget; the client waits
// CallTimeout, so that answer always arrives.
func TestCall_WaitingAnswerBeatsCallTimeout(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		release := make(chan struct{})
		reply := func(server net.Conn, id int64, result string) {
			b, _ := json.Marshal(Response{ID: id, Result: json.RawMessage(result)})
			_, _ = server.Write(append(b, '\n'))
		}
		c := pipeRun(t, func(server net.Conn, r Request) {
			switch r.Tool {
			case "connect_wait":
				<-release // answered only after the call gave up
				reply(server, r.ID, `{"state":"connected","account":"acme"}`)
			case "request_secret":
				time.Sleep(WaitBudget + 5*time.Second)
				reply(server, r.ID, `{"state":"waiting"}`)
			default:
				reply(server, r.ID, `{}`)
			}
		})

		res, err := c.Call(context.Background(), "request_secret", nil)
		require.NoError(t, err, "a waiting answer at WaitBudget+5s is in time")
		assert.JSONEq(t, `{"state":"waiting"}`, string(res))

		start := time.Now()
		_, err = c.Call(context.Background(), "connect_wait", nil)
		var we *Error
		require.ErrorAs(t, err, &we)
		assert.Equal(t, CodeFailed, we.Code)
		assert.Equal(t, CallTimeout, time.Since(start), "the call gives up at exactly CallTimeout")
		assert.Contains(t, we.Message, "call it again")

		// The late answer is dropped, and the connection still serves.
		close(release)
		synctest.Wait()
		res, err = c.Call(context.Background(), "connect_status", nil)
		require.NoError(t, err)
		assert.JSONEq(t, `{}`, string(res))
	})
}

func TestError_MessageCarriesCode(t *testing.T) {
	err := error(&Error{Code: CodeBadArgs, Message: "label is too long"})
	assert.Equal(t, "bad_args: label is too long", err.Error())
	var we *Error
	assert.True(t, errors.As(err, &we))
}

func TestWire_CallTimeoutOutlastsWaitBudget(t *testing.T) {
	assert.Greater(t, CallTimeout, WaitBudget+5*time.Second, "slack for the socket and parsing")
	assert.Less(t, CallTimeout, 60*time.Second, "under Codex's MCP tool timeout")
}

// A cancelled call never reaches the Desktop, even while another call holds
// the write turn.
func TestCall_CancelledCallIsNeverSent(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		got := make(chan string, 4)
		c := pipeRun(t, func(server net.Conn, r Request) {
			got <- r.Tool
			b, _ := json.Marshal(Response{ID: r.ID, Result: json.RawMessage(`{}`)})
			_, _ = server.Write(append(b, '\n'))
		})
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err := c.Call(ctx, "connect_start", nil)
		require.ErrorIs(t, err, context.Canceled)

		c.writeTurn <- struct{}{} // another call is writing
		ctx, cancel = context.WithCancel(context.Background())
		errc := make(chan error, 1)
		go func() {
			_, err := c.Call(ctx, "connect_cancel", nil)
			errc <- err
		}()
		synctest.Wait()
		cancel()
		require.ErrorIs(t, <-errc, context.Canceled)
		<-c.writeTurn

		_, err = c.Call(context.Background(), "connect_status", nil)
		require.NoError(t, err)
		synctest.Wait()
		close(got)
		var tools []string
		for tl := range got {
			tools = append(tools, tl)
		}
		assert.Equal(t, []string{"connect_status"}, tools, "only the live call reached the Desktop")
	})
}

// A write cut mid-frame closes the connection: the next call gets closed,
// and nothing is ever appended to the partial line.
func TestCall_WriteCutMidFrameClosesTheConnection(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, server := net.Pipe()
		defer func() { _ = server.Close() }()
		rest := make(chan []byte, 1)
		go func() {
			// Unbuffered reads: net.Pipe hands a reader only what it asks for,
			// so the client's write stays half done.
			r := iotest.OneByteReader(server)
			for b := make([]byte, 1); b[0] != '\n'; {
				if _, err := r.Read(b); err != nil {
					return
				}
			}
			if _, err := server.Write([]byte("{\"ok\":true}\n")); err != nil {
				return
			}
			head := make([]byte, 5)
			if _, err := io.ReadFull(r, head); err != nil {
				return
			}
			time.Sleep(CallTimeout + time.Second) // stop reading mid-frame
			tail, _ := io.ReadAll(server)
			rest <- tail
		}()
		c, err := handshake(context.Background(), client, testToken, "slack")
		require.NoError(t, err)

		// The caller's own deadline cuts the write (the path that once left
		// the partial frame on an open socket).
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		_, err = c.Call(ctx, "connect_start", json.RawMessage(`{"code":"https://acme.example.com/connect"}`))
		var we *Error
		require.ErrorAs(t, err, &we)
		assert.Equal(t, CodeClosed, we.Code)

		_, err = c.Call(context.Background(), "connect_status", nil)
		require.ErrorAs(t, err, &we)
		assert.Equal(t, CodeClosed, we.Code, "the next call never writes after the partial frame")
		assert.NotContains(t, string(<-rest), "\n", "the Desktop sees the socket end, never a completed or glued line")
	})
}

// A call whose budget runs out while it waits for the write turn sends
// nothing and fails alone: the connection stays, and an overlapping call
// in flight still gets its answer.
func TestCall_NotSentTimeoutKeepsTheConnection(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		release := make(chan struct{})
		got := make(chan string, 4)
		c := pipeRun(t, func(server net.Conn, r Request) {
			got <- r.Tool
			if r.Tool == "connect_wait" {
				<-release
			}
			b, _ := json.Marshal(Response{ID: r.ID, Result: json.RawMessage(`{"state":"waiting"}`)})
			_, _ = server.Write(append(b, '\n'))
		})

		// Own budget: a queued call times out unsent.
		c.writeTurn <- struct{}{} // a write in progress
		_, err := c.Call(context.Background(), "connect_start", nil)
		var we *Error
		require.ErrorAs(t, err, &we)
		assert.Equal(t, CodeFailed, we.Code)
		assert.Contains(t, we.Message, "was not sent")
		<-c.writeTurn

		// Overlap: connect_wait in flight, a queued call with a shorter
		// budget gives up unsent, connect_wait still gets its answer.
		waitRes := make(chan error, 1)
		go func() {
			_, err := c.Call(context.Background(), "connect_wait", nil)
			waitRes <- err
		}()
		synctest.Wait()
		c.writeTurn <- struct{}{}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		_, err = c.Call(ctx, "company_publish", nil)
		cancel()
		require.ErrorIs(t, err, context.DeadlineExceeded)
		<-c.writeTurn
		close(release)
		require.NoError(t, <-waitRes, "the in-flight call is unharmed")

		_, err = c.Call(context.Background(), "connect_status", nil)
		require.NoError(t, err, "the connection still serves")
		synctest.Wait()
		close(got)
		var tools []string
		for tl := range got {
			tools = append(tools, tl)
		}
		assert.Equal(t, []string{"connect_wait", "connect_status"}, tools, "the unsent calls never reached the Desktop")
	})
}

// After a transport timeout only a re-attach tool is told to call again;
// a tool that may have started something is told to check connect_status.
func TestCall_TimeoutMessagePerToolKind(t *testing.T) {
	for _, tool := range []string{"connect_status", "connect_wait", "request_secret"} {
		assert.True(t, strings.HasSuffix(noAnswer(tool), "call it again"), tool)
	}
	for _, tool := range []string{"connect_start", "company_publish", "company_check", "set_fields", "connect_cancel", "choose", "company_draft", "slack_live_probe"} {
		msg := noAnswer(tool)
		assert.NotContains(t, msg, "call it again", tool)
		assert.Contains(t, msg, "outcome is unknown: call connect_status before repeating it", tool)
	}
	synctest.Test(t, func(t *testing.T) {
		c := pipeRun(t, func(net.Conn, Request) {})
		_, err := c.Call(context.Background(), "connect_start", nil)
		var we *Error
		require.ErrorAs(t, err, &we)
		assert.Contains(t, we.Message, "connect_status before repeating", "the real timeout path uses it")
	})
}
