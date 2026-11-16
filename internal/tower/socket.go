package tower

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"watchtower/internal/fsutil"
	"watchtower/internal/hub/platform"
	"watchtower/internal/tower/api"
)

const (
	// SunPathMax is the longest socket path macOS binds: sun_path is 104
	// bytes with its terminator.
	SunPathMax = 103
	// SocketPathFile, inside the workspace, holds the socket's path when it
	// is not <workspace>/tower.sock (SocketPath's fallback); clients read it.
	SocketPathFile = "tower.sock.path"
	// MaxFrame is the longest request frame, newline excluded; a longer one
	// closes its connection.
	MaxFrame = 1 << 20

	socketName = "tower.sock"
	// maxInFlight bounds the calls one connection runs at once; reading the
	// next frame waits for a free slot.
	maxInFlight = 64
	// writeTimeout bounds one frame's write; a client that stops reading is
	// disconnected instead of holding the connection's other answers.
	writeTimeout = 10 * time.Second
)

// peerUID is the uid of the process at the other end of a connection (the
// hub control socket's check); a test replaces it. Serve reads it once.
var peerUID = func(c net.Conn) (int, error) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return 0, errors.New("tower: not a unix connection")
	}
	return platform.PeerUID(uc)
}

// SocketPath is where the daemon of workspace serves the tower:
// <workspace>/tower.sock when that fits sun_path (SunPathMax), else
// <TMPDIR>/wt-<uid>/<first 12 hex of sha256(workspace)>.sock, with fallback
// true (the daemon then writes the path into SocketPathFile).
func SocketPath(workspace string) (path string, fallback bool) {
	path = filepath.Join(workspace, socketName)
	if len(path) <= SunPathMax {
		return path, false
	}
	sum := sha256.Sum256([]byte(filepath.Clean(workspace)))
	dir := filepath.Join(os.TempDir(), fmt.Sprintf("wt-%d", os.Getuid()))
	return filepath.Join(dir, hex.EncodeToString(sum[:])[:12]+".sock"), true
}

// ServeWorkspace serves t at SocketPath(workspace). On the fallback path it
// writes that path into <workspace>/tower.sock.path (0600, temp file and
// rename) and removes the file on stop; in place, it removes a stale one.
func ServeWorkspace(ctx context.Context, workspace string, t *Tower) (stop func(), err error) {
	path, fallback := SocketPath(workspace)
	pathFile := filepath.Join(workspace, SocketPathFile)
	stopServe, err := Serve(ctx, path, t)
	if err != nil {
		return nil, err
	}
	if !fallback {
		if err := os.Remove(pathFile); err != nil && !errors.Is(err, fs.ErrNotExist) {
			log.Printf("tower: removing a stale %s: %v", SocketPathFile, err)
		}
		return stopServe, nil
	}
	if err := fsutil.WriteFileAtomic(pathFile, []byte(path), 0o600); err != nil {
		stopServe()
		return nil, fmt.Errorf("tower: writing %s: %w", SocketPathFile, err)
	}
	return func() {
		stopServe()
		_ = os.Remove(pathFile)
	}, nil
}

// Serve listens on path until stop is called (or ctx ends) and answers each
// newline-delimited api.Request frame with an api.Response frame carrying
// its id; one connection's calls run concurrently, so answers may come out
// of order. A watch command (Spec.Watch) answers ok once and then streams
// api.ChangedEvent frames (with the watch's id) until the client closes the
// connection. The socket is 0600 in a 0700 directory, and a connection
// whose peer is another user is closed unanswered. A frame that is not a
// request answers refused/unsupported; one longer than MaxFrame closes its
// connection. stop closes the listener and every connection, waits for the
// running calls, and removes the socket.
func Serve(ctx context.Context, path string, t *Tower) (stop func(), err error) {
	if err := privateDir(filepath.Dir(path)); err != nil {
		return nil, err
	}
	l, err := listen(path)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	s := &server{t: t, uid: peerUID, ctx: ctx, conns: map[net.Conn]bool{}}
	s.wg.Add(1)
	go s.accept(l)
	var once sync.Once
	return func() {
		once.Do(func() {
			cancel()
			_ = l.Close()
			s.mu.Lock()
			for c := range s.conns {
				_ = c.Close()
			}
			s.mu.Unlock()
			s.wg.Wait()
			_ = os.Remove(path)
		})
	}, nil
}

// privateDir makes dir (created 0700 when missing) a directory of this user
// with mode 0700. One owned by another user is refused: in a shared temp
// directory it could be a trap.
func privateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("tower: creating the socket directory: %w", err)
	}
	fi, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("tower: the socket directory: %w", err)
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !fi.IsDir() || !ok || int(st.Uid) != os.Getuid() {
		return fmt.Errorf("tower: the socket directory %s is not this user's directory", dir)
	}
	if fi.Mode().Perm() != 0o700 {
		if err := os.Chmod(dir, 0o700); err != nil {
			return fmt.Errorf("tower: tightening the socket directory: %w", err)
		}
	}
	return nil
}

// listen binds path 0600, replacing a stale socket (the daemon holds the
// sync lock, so no other daemon serves it); a non-socket file there is
// refused.
func listen(path string) (net.Listener, error) {
	if fi, err := os.Lstat(path); err == nil {
		if fi.Mode().Type() != fs.ModeSocket {
			return nil, fmt.Errorf("tower: %s is not a socket", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, fmt.Errorf("tower: removing a stale socket: %w", err)
		}
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("tower: listening on the socket: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = l.Close()
		return nil, fmt.Errorf("tower: tightening the socket: %w", err)
	}
	return l, nil
}

type server struct {
	t   *Tower
	uid func(net.Conn) (int, error)
	// ctx is the calls' context: a client that disconnects mid-call does not
	// cancel it (its ledger row records the outcome for a resend); stop does.
	ctx   context.Context
	wg    sync.WaitGroup
	mu    sync.Mutex
	conns map[net.Conn]bool
}

func (s *server) accept(l net.Listener) {
	defer s.wg.Done()
	for {
		c, err := l.Accept()
		if err != nil {
			return
		}
		uid, err := s.uid(c)
		if err != nil || uid != os.Getuid() {
			log.Printf("tower: socket: a client refused (another user, or its credentials unreadable)")
			_ = c.Close()
			continue
		}
		s.mu.Lock()
		if s.ctx.Err() != nil {
			s.mu.Unlock()
			_ = c.Close()
			return
		}
		s.conns[c] = true
		s.wg.Add(1)
		s.mu.Unlock()
		go func() {
			defer s.wg.Done()
			s.serveConn(c)
			s.mu.Lock()
			delete(s.conns, c)
			s.mu.Unlock()
		}()
	}
}

// frameWriter writes one connection's frames, one at a time.
type frameWriter struct {
	mu   sync.Mutex
	c    net.Conn
	dead bool
}

// write sends v as one frame; false once the connection is dead (a failed
// or timed-out write closes it).
func (w *frameWriter) write(v any) bool {
	b, err := json.Marshal(v)
	if err != nil {
		log.Printf("tower: socket: marshal a frame: %v", err)
		return false
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.dead {
		return false
	}
	_ = w.c.SetWriteDeadline(time.Now().Add(writeTimeout))
	if _, err := w.c.Write(append(b, '\n')); err != nil {
		w.dead = true
		_ = w.c.Close()
		return false
	}
	return true
}

var errFrameTooLong = errors.New("tower: frame longer than MaxFrame")

// readFrame reads one frame without its newline; past MaxFrame it fails.
func readFrame(r *bufio.Reader) ([]byte, error) {
	var buf []byte
	for {
		chunk, err := r.ReadSlice('\n')
		if len(buf)+len(chunk) > MaxFrame+1 {
			return nil, errFrameTooLong
		}
		buf = append(buf, chunk...)
		switch {
		case err == nil:
			return buf[:len(buf)-1], nil
		case !errors.Is(err, bufio.ErrBufferFull):
			return nil, err
		}
	}
}

func (s *server) serveConn(c net.Conn) {
	defer func() { _ = c.Close() }()
	w := &frameWriter{c: c}
	var (
		calls   sync.WaitGroup
		watches []func()
	)
	slots := make(chan struct{}, maxInFlight)
	defer func() {
		// The connection is closed (the client left, or stop): end its
		// watches, then wait for its calls and pumps.
		_ = c.Close()
		for _, cancel := range watches {
			cancel()
		}
		calls.Wait()
	}()
	r := bufio.NewReaderSize(c, 64<<10)
	for {
		line, err := readFrame(r)
		if err != nil {
			if errors.Is(err, errFrameTooLong) {
				log.Printf("tower: socket: a frame past %d bytes, connection closed", MaxFrame)
			}
			return
		}
		if len(line) == 0 {
			continue
		}
		var req api.Request
		if err := json.Unmarshal(line, &req); err != nil {
			w.write(refused(api.Response{}, api.CodeUnsupported, "Watchtower couldn't read this request."))
			continue
		}
		if spec, ok := s.t.watchSpec(req.Command); ok {
			if cancel := s.watch(w, req, spec, &calls); cancel != nil {
				watches = append(watches, cancel)
			}
			continue
		}
		select {
		case slots <- struct{}{}:
		case <-s.ctx.Done():
			return
		}
		calls.Add(1)
		go func() {
			defer calls.Done()
			defer func() { <-slots }()
			w.write(s.t.Call(s.ctx, req, Origin{Transport: "socket"}))
		}()
	}
}

// watch answers a watch request and, when it is ok, pumps its events until
// the returned cancel (nil when the watch did not open).
func (s *server) watch(w *frameWriter, req api.Request, spec Spec, pumps *sync.WaitGroup) (cancel func()) {
	ch := s.t.opts.Changes
	if ch == nil {
		w.write(refused(api.Response{ID: req.ID}, api.CodeUnsupported, "This Watchtower can't watch for changes."))
		return nil
	}
	// Subscribed before the answer, so no change after it is missed.
	events, cancel := ch.Subscribe(spec.ChangeTables)
	resp := s.t.Call(s.ctx, req, Origin{Transport: "socket"})
	if resp.Status != api.StatusOK {
		cancel()
		w.write(resp)
		return nil
	}
	if !w.write(resp) {
		cancel()
		return nil
	}
	pumps.Add(1)
	go func() {
		defer pumps.Done()
		for ev := range events {
			ev.ID = req.ID
			if !w.write(ev) {
				// The connection is dead: serveConn's read fails and cancels
				// the watch; a publish never blocks on its full queue.
				return
			}
		}
	}()
	return cancel
}

// watchSpec returns the spec of command when it is a watch command.
func (t *Tower) watchSpec(command string) (Spec, bool) {
	cmd, ok := t.opts.Registry.cmds[command]
	if !ok || !cmd.Spec.Watch {
		return Spec{}, false
	}
	return cmd.Spec, true
}
