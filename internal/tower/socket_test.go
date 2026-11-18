package tower

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"watchtower/internal/ownerconfirm"
	"watchtower/internal/tower/api"
)

// shortDir is a fresh directory under /tmp: macOS limits a socket path
// (sun_path) to 104 bytes, which t.TempDir often exceeds.
func shortDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "tw")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

// serve serves f's Tower on path until the test ends.
func serve(t *testing.T, path string, f *fixture) {
	t.Helper()
	stop, err := Serve(context.Background(), path, f.tower)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(stop)
}

// setPeerUID replaces the peer check for the servers the test starts after
// it (Serve reads it once).
func setPeerUID(t *testing.T, fn func(net.Conn) (int, error)) {
	t.Helper()
	old := peerUID
	peerUID = fn
	t.Cleanup(func() { peerUID = old })
}

type sockClient struct {
	t *testing.T
	c net.Conn
	r *bufio.Reader
}

func dialTower(t *testing.T, path string) *sockClient {
	t.Helper()
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return &sockClient{t: t, c: c, r: bufio.NewReader(c)}
}

func (c *sockClient) send(id, command string, params any) {
	c.t.Helper()
	req := api.Request{V: api.EnvelopeVersion, ID: id, Command: command}
	if params != nil {
		raw, err := json.Marshal(params)
		if err != nil {
			c.t.Fatal(err)
		}
		req.Params = raw
	}
	b, err := json.Marshal(req)
	if err != nil {
		c.t.Fatal(err)
	}
	c.sendRaw(append(b, '\n'))
}

func (c *sockClient) sendRaw(b []byte) {
	c.t.Helper()
	if _, err := c.c.Write(b); err != nil {
		c.t.Fatal(err)
	}
}

// line reads the next frame; err is the connection's error (io.EOF once the
// server closed it).
func (c *sockClient) line() ([]byte, error) {
	return c.r.ReadBytes('\n')
}

func (c *sockClient) response() api.Response {
	c.t.Helper()
	b, err := c.line()
	if err != nil {
		c.t.Fatalf("read a response: %v", err)
	}
	var r api.Response
	if err := json.Unmarshal(b, &r); err != nil {
		c.t.Fatalf("decode %q: %v", b, err)
	}
	return r
}

func (c *sockClient) ping(id string) api.Response {
	c.t.Helper()
	c.send(id, "tower.ping", nil)
	return c.response()
}

func TestSocket_IsPrivateAndChecksPeer(t *testing.T) {
	dir := filepath.Join(shortDir(t), "ws")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "tower.sock")
	f := newFixture(t)
	serve(t, path, f)

	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Type() != fs.ModeSocket || fi.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %v, want a 0600 socket", fi.Mode())
	}
	di, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if di.Mode().Perm() != 0o700 {
		t.Fatalf("socket directory mode %v, want 0700 (a 0755 one is tightened)", di.Mode().Perm())
	}
	if r := dialTower(t, path).ping("p1"); r.Status != api.StatusOK {
		t.Fatalf("the owner's ping: %+v", r)
	}

	// Another user's connection is closed without an answer and its request
	// never runs. The server may close before the write lands, so the write
	// can fail (EPIPE/ECONNRESET): either way the read ends in an error.
	setPeerUID(t, func(net.Conn) (int, error) { return os.Getuid() + 1, nil })
	foreign := filepath.Join(dir, "foreign.sock")
	serve(t, foreign, f)
	c := dialTower(t, foreign)
	raw, err := json.Marshal(api.Request{V: api.EnvelopeVersion, ID: "w-foreign", Command: "test.guarded",
		Params: json.RawMessage(`{"request_id":"foreign-1","note":"foreign"}`)})
	if err != nil {
		t.Fatal(err)
	}
	_, _ = c.c.Write(append(raw, '\n')) // fails when the refusal closed it first
	if b, err := c.line(); err == nil {
		t.Fatalf("another user's connection was answered: %s", b)
	}
	if n := f.rows(); n != 0 {
		t.Fatalf("another user's write ran: %d rows", n)
	}
	if row := f.ledger("foreign-1"); row != nil {
		t.Fatalf("another user's write reached the ledger: %+v", row)
	}
}

func TestSocket_PingEndToEnd(t *testing.T) {
	path := filepath.Join(shortDir(t), "tower.sock")
	serve(t, path, newFixture(t))
	r := dialTower(t, path).ping("ping-1")
	if r.Status != api.StatusOK || r.ID != "ping-1" {
		t.Fatalf("ping: %+v", r)
	}
	var out api.PingResponse
	if err := json.Unmarshal(r.Result, &out); err != nil || out.At == "" {
		t.Fatalf("ping result %s: %v", r.Result, err)
	}
}

func TestSocket_AnswersMatchIDsWhenInterleaved(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	f := newFixtureWith(t, func(r *Registry, _ *Options) {
		Register(r, "test.slow", func(_ context.Context, _ *Ctx, _ struct{}) (readResult, error) {
			close(entered)
			<-release
			return readResult{Rows: 7}, nil
		}, Spec{Read: true})
	})
	path := filepath.Join(shortDir(t), "tower.sock")
	serve(t, path, f)
	c := dialTower(t, path)

	c.send("slow", "test.slow", nil)
	<-entered
	// The slow call holds no other call on the same connection back.
	if r := c.ping("fast"); r.ID != "fast" || r.Status != api.StatusOK {
		t.Fatalf("the second request's answer: %+v", r)
	}
	close(release)
	r := c.response()
	if r.ID != "slow" || r.Status != api.StatusOK || string(r.Result) != `{"rows":7}` {
		t.Fatalf("the first request's answer: %+v (%s)", r, r.Result)
	}
}

func TestSocket_GarbageLineAnswersUnsupported(t *testing.T) {
	path := filepath.Join(shortDir(t), "tower.sock")
	serve(t, path, newFixture(t))
	c := dialTower(t, path)
	c.sendRaw([]byte("this is not json\n"))
	r := c.response()
	if r.Status != api.StatusRefused || r.Refusal == nil || r.Refusal.Code != api.CodeUnsupported {
		t.Fatalf("garbage answered %+v", r)
	}
	// The connection keeps serving.
	if r := c.ping("after"); r.Status != api.StatusOK || r.ID != "after" {
		t.Fatalf("ping after garbage: %+v", r)
	}
}

func TestSocket_OversizeFrameClosesOnlyThatConnection(t *testing.T) {
	path := filepath.Join(shortDir(t), "tower.sock")
	serve(t, path, newFixture(t))
	big := dialTower(t, path)
	// MaxFrame bytes and more, no newline: the server stops reading and
	// closes, so this write may fail part-way.
	go func() { _, _ = big.c.Write([]byte(strings.Repeat("x", 2*MaxFrame))) }()
	if b, err := big.line(); err == nil {
		t.Fatalf("an oversize frame was answered: %.80s", b)
	}
	if r := dialTower(t, path).ping("other"); r.Status != api.StatusOK {
		t.Fatalf("another connection after an oversize frame: %+v", r)
	}
}

func TestSocket_StaleSocketFileIsReplaced(t *testing.T) {
	path := filepath.Join(shortDir(t), "tower.sock")
	// A socket file a crashed daemon left behind.
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	l.(*net.UnixListener).SetUnlinkOnClose(false)
	_ = l.Close()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the stale socket is not there: %v", err)
	}
	serve(t, path, newFixture(t))
	if r := dialTower(t, path).ping("p"); r.Status != api.StatusOK {
		t.Fatalf("ping over the replaced socket: %+v", r)
	}

	// A file that is not a socket is never removed.
	file := filepath.Join(filepath.Dir(path), "plain")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if stop, err := Serve(context.Background(), file, newFixture(t).tower); err == nil {
		stop()
		t.Fatal("Serve replaced a file that is not a socket")
	}
	if b, err := os.ReadFile(file); err != nil || string(b) != "x" {
		t.Fatalf("the plain file changed: %q, %v", b, err)
	}
}

func TestSocketPath_LongWorkspaceFallsBackAndWritesThePathFile(t *testing.T) {
	tmp := shortDir(t)
	t.Setenv("TMPDIR", tmp)
	ws := filepath.Join(t.TempDir(), strings.Repeat("w", 110))
	if err := os.MkdirAll(ws, 0o700); err != nil {
		t.Fatal(err)
	}
	path, fallback := SocketPath(ws)
	if !fallback {
		t.Fatalf("SocketPath(%d-byte workspace) = %s, no fallback", len(ws), path)
	}
	if dir := filepath.Dir(path); dir != filepath.Join(tmp, "wt-"+itoa(os.Getuid())) {
		t.Fatalf("fallback directory %s", dir)
	}
	if base := filepath.Base(path); len(base) != len("0123456789ab.sock") || !strings.HasSuffix(base, ".sock") {
		t.Fatalf("fallback name %s, want <12 hex>.sock", base)
	}
	if len(path) > SunPathMax {
		t.Fatalf("fallback path is %d bytes", len(path))
	}

	stop, err := ServeWorkspace(context.Background(), ws, newFixture(t).tower)
	if err != nil {
		t.Fatal(err)
	}
	di, err := os.Stat(filepath.Dir(path))
	if err != nil || di.Mode().Perm() != 0o700 {
		t.Fatalf("fallback directory: %v, %v", di, err)
	}
	pf := filepath.Join(ws, SocketPathFile)
	pi, err := os.Stat(pf)
	if err != nil || pi.Mode().Perm() != 0o600 {
		t.Fatalf("path file: %v, %v", pi, err)
	}
	got, err := os.ReadFile(pf)
	if err != nil || string(got) != path {
		t.Fatalf("path file holds %q (%v), want %q", got, err, path)
	}
	// A client finds the socket through the file.
	if r := dialTower(t, string(got)).ping("p"); r.Status != api.StatusOK {
		t.Fatalf("ping through the path file: %+v", r)
	}
	stop()
	if _, err := os.Stat(pf); !os.IsNotExist(err) {
		t.Fatalf("the path file outlived stop: %v", err)
	}

	// A short workspace binds in place and writes no path file.
	short := shortDir(t)
	if p, fb := SocketPath(short); fb || p != filepath.Join(short, "tower.sock") {
		t.Fatalf("SocketPath(short) = %s, %v", p, fb)
	}
	stop, err = ServeWorkspace(context.Background(), short, newFixture(t).tower)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	if _, err := os.Stat(filepath.Join(short, SocketPathFile)); !os.IsNotExist(err) {
		t.Fatalf("a short workspace has a path file: %v", err)
	}
	if r := dialTower(t, filepath.Join(short, "tower.sock")).ping("p"); r.Status != api.StatusOK {
		t.Fatalf("ping in place: %+v", r)
	}
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

type desktopResult struct {
	Desktop bool `json:"desktop"`
}

// tokenFor is an audit token naming pid (audit_token_to_pid: word 5).
func tokenFor(pid int) ownerconfirm.PeerToken {
	var t ownerconfirm.PeerToken
	binary.LittleEndian.PutUint32(t[20:24], uint32(pid))
	return t
}

// TestSocket_DesktopIsTheSignedPeerCheckedOncePerConnection: a socket call's
// Origin.Desktop checks the connection's peer audit token with
// Options.VerifyDesktop once per connection; a tower without VerifyDesktop
// trusts no peer as the Desktop.
func TestSocket_DesktopIsTheSignedPeerCheckedOncePerConnection(t *testing.T) {
	oldToken := peerToken
	peerToken = func(net.Conn) (ownerconfirm.PeerToken, error) { return tokenFor(4242), nil }
	t.Cleanup(func() { peerToken = oldToken })
	register := func(r *Registry) {
		Register(r, "test.desktop", func(ctx context.Context, c *Ctx, _ struct{}) (desktopResult, error) {
			return desktopResult{Desktop: c.Origin.Desktop != nil && c.Origin.Desktop(ctx) == nil}, nil
		}, Spec{Read: true})
	}
	for _, tc := range []struct {
		name   string
		verify func(context.Context, int) error
		want   bool
	}{
		{"signed", func(_ context.Context, pid int) error {
			if pid != 4242 {
				return errors.New("wrong pid")
			}
			return nil
		}, true},
		{"unsigned", func(context.Context, int) error { return errors.New("not the Desktop") }, false},
		{"no check", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			f := newFixtureWith(t, func(r *Registry, o *Options) {
				register(r)
				if tc.verify != nil {
					o.VerifyDesktop = func(ctx context.Context, peer ownerconfirm.PeerToken) error {
						calls++
						return tc.verify(ctx, peer.PID())
					}
				}
			})
			path := filepath.Join(shortDir(t), "t.sock")
			serve(t, path, f)
			c := dialTower(t, path)
			for i := range 2 {
				c.send(itoa(i), "test.desktop", nil)
				resp := c.response()
				var got desktopResult
				if err := json.Unmarshal(resp.Result, &got); err != nil {
					t.Fatalf("%s: %+v", err, resp)
				}
				if got.Desktop != tc.want {
					t.Errorf("call %d: desktop %v, want %v", i, got.Desktop, tc.want)
				}
			}
			if tc.verify != nil && calls != 1 {
				t.Errorf("%d signature checks for one connection, want 1", calls)
			}
		})
	}
}

// TestSocket_DesktopRechecksANewPeerPidAndNeverKeepsACancelledCheck: the
// peer's audit token is read on every gesture, so a verified connection
// handed to another process (an inherited descriptor) is checked again and
// refused for an unsigned peer; a check cut short by its context is not
// kept.
func TestSocket_DesktopRechecksANewPeerPidAndNeverKeepsACancelledCheck(t *testing.T) {
	var pid atomic.Int64
	pid.Store(4242)
	oldToken := peerToken
	peerToken = func(net.Conn) (ownerconfirm.PeerToken, error) { return tokenFor(int(pid.Load())), nil }
	t.Cleanup(func() { peerToken = oldToken })
	var checks atomic.Int64
	cancelFirst := atomic.Bool{}
	cancelFirst.Store(true)
	f := newFixtureWith(t, func(r *Registry, o *Options) {
		Register(r, "test.desktop", func(ctx context.Context, c *Ctx, _ struct{}) (desktopResult, error) {
			return desktopResult{Desktop: c.Origin.Desktop(ctx) == nil}, nil
		}, Spec{Read: true})
		o.VerifyDesktop = func(_ context.Context, peer ownerconfirm.PeerToken) error {
			p := peer.PID()
			checks.Add(1)
			if cancelFirst.Swap(false) {
				return fmt.Errorf("codesign: %w", context.Canceled)
			}
			if p != 4242 {
				return errors.New("not the Desktop")
			}
			return nil
		}
	})
	path := filepath.Join(shortDir(t), "t.sock")
	serve(t, path, f)
	c := dialTower(t, path)
	desktop := func(id string) bool {
		c.send(id, "test.desktop", nil)
		var got desktopResult
		if err := json.Unmarshal(c.response().Result, &got); err != nil {
			t.Fatal(err)
		}
		return got.Desktop
	}
	if desktop("1") {
		t.Fatal("a cancelled check passed")
	}
	if !desktop("2") {
		t.Fatal("the cancelled check was kept: the signed Desktop is refused")
	}
	pid.Store(99)
	if desktop("3") {
		t.Error("the connection's new, unsigned peer pid passed on the old verdict")
	}
	pid.Store(4242)
	if !desktop("4") {
		t.Error("the signed Desktop is refused after its pid came back")
	}
	if n := checks.Load(); n != 3 {
		t.Errorf("%d signature checks, want 3 (cancelled, 4242, 99)", n)
	}
}

// TestSocket_DesktopRechecksANewTokenOfTheSamePid: the verdict is kept per
// audit token, not per pid, so a peer whose pid is unchanged but whose
// process image changed (it exec'd: another pidversion, word 7) is checked
// again and refused when it is no longer the signed Desktop.
func TestSocket_DesktopRechecksANewTokenOfTheSamePid(t *testing.T) {
	signed := tokenFor(4242)
	execd := tokenFor(4242)
	binary.LittleEndian.PutUint32(execd[28:32], 7)
	var current atomic.Value
	current.Store(signed)
	oldToken := peerToken
	peerToken = func(net.Conn) (ownerconfirm.PeerToken, error) {
		return current.Load().(ownerconfirm.PeerToken), nil
	}
	t.Cleanup(func() { peerToken = oldToken })
	var checks atomic.Int64
	f := newFixtureWith(t, func(r *Registry, o *Options) {
		Register(r, "test.desktop", func(ctx context.Context, c *Ctx, _ struct{}) (desktopResult, error) {
			return desktopResult{Desktop: c.Origin.Desktop(ctx) == nil}, nil
		}, Spec{Read: true})
		o.VerifyDesktop = func(_ context.Context, peer ownerconfirm.PeerToken) error {
			checks.Add(1)
			if peer != signed {
				return errors.New("not the Desktop")
			}
			return nil
		}
	})
	path := filepath.Join(shortDir(t), "t.sock")
	serve(t, path, f)
	c := dialTower(t, path)
	desktop := func(id string) bool {
		c.send(id, "test.desktop", nil)
		var got desktopResult
		if err := json.Unmarshal(c.response().Result, &got); err != nil {
			t.Fatal(err)
		}
		return got.Desktop
	}
	if !desktop("1") {
		t.Fatal("the signed Desktop is refused")
	}
	current.Store(execd)
	if desktop("2") {
		t.Error("a new token of the same pid passed on the old verdict")
	}
	if n := checks.Load(); n != 2 {
		t.Errorf("%d signature checks, want 2 (one per token)", n)
	}
}
