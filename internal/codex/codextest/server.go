// Package codextest serves the codex app-server protocol in-process, over
// io.Pipe, for tests of codex.StartAppServer's and codex.ReadUsage's
// conversations. A *Server satisfies codex.AppServerConn; every wait in it is
// a channel operation, so a test runs the whole conversation — budgets,
// cancels, a server that never answers — under testing/synctest.
package codextest

import (
	"bufio"
	"encoding/json"
	"io"
	"slices"
	"sync"
)

// Message is one JSON-RPC message the client sent: a request (ID set) or a
// notification.
type Message struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// Handler answers one message. Each returned value is written back as one
// line: a []byte verbatim, anything else as JSON. Nothing returned leaves the
// message unanswered.
type Handler func(Message) []any

// Server is one in-process app-server. It reads its input until EOF, then
// exits — or, with Linger, keeps running until Kill.
type Server struct {
	// Linger keeps the server running after its input closes, until Kill:
	// a server that does not exit at EOF. Set before Serve.
	Linger bool

	handle           Handler
	inR              *io.PipeReader
	inW              *io.PipeWriter
	outR             *io.PipeReader
	outW             *io.PipeWriter
	errR             *io.PipeReader
	errW             *io.PipeWriter
	exited, killed   chan struct{}
	inputEnded       chan struct{}
	killOnce         sync.Once
	mu               sync.Mutex
	lines            []string
	killedBeforeExit bool
}

// New returns a server answering through handle; Serve starts it.
func New(handle Handler) *Server {
	s := &Server{handle: handle, exited: make(chan struct{}), killed: make(chan struct{}), inputEnded: make(chan struct{})}
	s.inR, s.inW = io.Pipe()
	s.outR, s.outW = io.Pipe()
	s.errR, s.errW = io.Pipe()
	return s
}

// Serve starts the server's goroutine and returns s, ready to be the
// connection a launcher hands back.
func (s *Server) Serve() *Server {
	go s.run()
	return s
}

func (s *Server) run() {
	defer close(s.exited)
	defer func() { _ = s.inR.CloseWithError(io.ErrClosedPipe) }() // a write after exit fails, as EPIPE does
	defer func() { _ = s.errW.Close() }()
	defer func() { _ = s.outW.Close() }()
	sc := bufio.NewScanner(s.inR)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		s.mu.Lock()
		s.lines = append(s.lines, sc.Text())
		s.mu.Unlock()
		var m Message
		if json.Unmarshal(sc.Bytes(), &m) != nil {
			continue
		}
		for _, reply := range s.handle(m) {
			b, ok := reply.([]byte)
			if !ok {
				var err error
				if b, err = json.Marshal(reply); err != nil {
					panic(err)
				}
			}
			if _, err := s.outW.Write(append(b, '\n')); err != nil {
				return // killed while writing
			}
		}
	}
	select {
	case <-s.killed:
		return
	default:
	}
	close(s.inputEnded)
	if s.Linger {
		<-s.killed
	}
}

// Stdin is the server's input.
func (s *Server) Stdin() io.WriteCloser { return s.inW }

// Stdout is the server's output.
func (s *Server) Stdout() io.ReadCloser { return s.outR }

// Stderr is the server's diagnostics: always empty, closed at exit.
func (s *Server) Stderr() io.ReadCloser { return s.errR }

// Exited is closed once the server has exited.
func (s *Server) Exited() <-chan struct{} { return s.exited }

// Kill ends the server at once, wherever it is.
func (s *Server) Kill() {
	s.killOnce.Do(func() {
		s.mu.Lock()
		select {
		case <-s.exited:
		default:
			s.killedBeforeExit = true
		}
		s.mu.Unlock()
		close(s.killed)
		_ = s.inR.CloseWithError(io.ErrClosedPipe)
		_ = s.outW.CloseWithError(io.ErrClosedPipe)
	})
}

// Killed reports whether Kill ended a server that was still running.
func (s *Server) Killed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.killedBeforeExit
}

// InputEnded is closed once the server has read its input's EOF.
func (s *Server) InputEnded() <-chan struct{} { return s.inputEnded }

// Lines is every line the server read, verbatim, in order.
func (s *Server) Lines() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.lines)
}

// Result is the answer to request m with result.
func Result(m Message, result any) map[string]any {
	return map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": result}
}

// Error is the error answer to request m.
func Error(m Message, code int, message string) map[string]any {
	return map[string]any{"jsonrpc": "2.0", "id": m.ID, "error": map[string]any{"code": code, "message": message}}
}
