package chatengine

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"

	"watchtower/internal/ownerconfirm"
	"watchtower/internal/platform"
)

// MaxRequestBytes is the longest request line chat.sock reads, its newline
// excluded (spec §5.1): attachments travel by path, never inline.
const MaxRequestBytes = 2 << 20

// ConnQueue is the events a connection's subscription may have waiting
// (spec §5.1). The bound is each subscription's own queue (Ruling F3: the
// connection adds no second one): a connection that does not read blocks
// its writer, the subscription's queue fills, and the subscriber gets one
// resync and then a fresh snapshot.
const ConnQueue = subscriptionQueue

// ProtocolVersion is chat.sock's protocol, answered by hello.
const ProtocolVersion = 1

// The operations the server answers itself; every other one goes to
// Engine.Do.
const (
	opHello       = "hello"
	opSubscribe   = "subscribe"
	opUnsubscribe = "unsubscribe"
	// opShutdown is the one operation a CLI peer may send (D17; the handler
	// is the engine's, registered by the daemon).
	opShutdown = "chat_shutdown"
)

// maxInFlight bounds a connection's operations running at once; one more is
// answered busy.
const maxInFlight = 32

// ServerOptions are the peer checks of chat.sock (D17): the connecting
// process must be the Watchtower app signed by this CLI's team; a process
// that is this team's CLI may only say hello and ask for chat_shutdown.
type ServerOptions struct {
	VerifyApp func(ctx context.Context, pid int) error // default ownerconfirm.VerifyDesktop
	VerifyCLI func(ctx context.Context, pid int) error // default ownerconfirm.VerifySameTeamCLI
}

// Server serves the engine on chat.sock: one goroutine per connection, one
// JSON object per line both ways (spec §5.1).
type Server struct {
	e *Engine
	o ServerOptions
	// peer reads a connection's uid and pid (nil = the unix socket's
	// credentials); a test seam for in-memory connections.
	peer func(net.Conn) (uid, pid int, err error)

	mu     sync.Mutex
	conns  map[*conn]struct{}
	closed bool
	wg     sync.WaitGroup
}

// NewServer returns a server of e.
func NewServer(e *Engine, o ServerOptions) *Server {
	if o.VerifyApp == nil {
		o.VerifyApp = ownerconfirm.VerifyDesktop
	}
	if o.VerifyCLI == nil {
		o.VerifyCLI = ownerconfirm.VerifySameTeamCLI
	}
	return &Server{e: e, o: o, peer: unixPeer, conns: map[*conn]struct{}{}}
}

// unixPeer is the uid and pid at the other end of a unix connection.
func unixPeer(c net.Conn) (uid, pid int, err error) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return 0, 0, errors.New("chatengine: not a unix connection")
	}
	if uid, err = platform.PeerUID(uc); err != nil {
		return 0, 0, err //nolint:wrapcheck // platform's errors say what failed
	}
	if pid, err = platform.PeerPID(uc); err != nil {
		return 0, 0, err //nolint:wrapcheck // platform's errors say what failed
	}
	return uid, pid, nil
}

// Listen binds chat.sock at socketPath: its folder made 0700 (created when
// missing), the socket 0600, one listener per path (platform.ListenLocked;
// another engine serving it is platform.ErrSocketBusy).
func Listen(socketPath string) (net.Listener, error) {
	dir := filepath.Dir(socketPath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("chatengine: socket folder: %w", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, fmt.Errorf("chatengine: socket folder: %w", err)
	}
	return platform.ListenLocked(socketPath) //nolint:wrapcheck // platform's errors name the socket
}

// Serve accepts connections on l until ctx ends, then closes l and every
// connection and waits for their goroutines. A subscription ends with its
// connection; a running operation finishes (the engine's own lifetime is
// the daemon's).
func (s *Server) Serve(ctx context.Context, l net.Listener) error {
	stop := context.AfterFunc(ctx, func() {
		_ = l.Close()
		s.closeAll()
	})
	defer stop()
	var err error
	for {
		nc, aerr := l.Accept()
		if aerr != nil {
			if ctx.Err() == nil {
				err = fmt.Errorf("chatengine: accepting on chat.sock: %w", aerr)
				_ = l.Close()
				s.closeAll()
			}
			break
		}
		c := newConn(s, nc)
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			_ = nc.Close()
			continue
		}
		s.conns[c] = struct{}{}
		s.wg.Add(1)
		s.mu.Unlock()
		go func() {
			defer s.wg.Done()
			c.serve(ctx)
			s.mu.Lock()
			delete(s.conns, c)
			s.mu.Unlock()
		}()
	}
	s.wg.Wait()
	return err
}

// closeAll closes every connection and refuses new ones.
func (s *Server) closeAll() {
	s.mu.Lock()
	s.closed = true
	conns := make([]*conn, 0, len(s.conns))
	for c := range s.conns {
		conns = append(conns, c)
	}
	s.mu.Unlock()
	for _, c := range conns {
		c.kill()
	}
}

// engineClosed is true once the engine stopped taking work.
func (s *Server) engineClosed() bool {
	s.e.mu.Lock()
	defer s.e.mu.Unlock()
	return s.e.closed
}

// logf logs a connection's refusal; ids and classes only (FILES-01).
func logf(format string, args ...any) {
	log.Printf("chatengine: chat.sock: "+format, args...)
}
