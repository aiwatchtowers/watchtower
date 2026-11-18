package hub

import (
	"encoding/json"
	"net"
	"os"
	"sync"
)

// memControl is the control socket of a hub run in a synctest bubble: each
// listen hands out a fresh in-memory listener whose connections are
// net.Pipe ends, so every goroutine blocked on it is durably blocked and the
// bubble's clock keeps moving. The peer check passes every connection (the
// unix peer check has its own tests over the real socket).
type memControl struct {
	mu      sync.Mutex
	cur     *memListener
	changed chan struct{} // closed and replaced by every listen
}

func newMemControl() *memControl { return &memControl{changed: make(chan struct{})} }

// configure points o's control socket at m.
func (m *memControl) configure(o *Options) {
	o.listen = m.listen
	o.peerUID = func(net.Conn) (int, error) { return os.Getuid(), nil }
}

func (m *memControl) listen(string) (net.Listener, error) {
	l := &memListener{conns: make(chan net.Conn), done: make(chan struct{})}
	m.mu.Lock()
	m.cur = l
	close(m.changed)
	m.changed = make(chan struct{})
	m.mu.Unlock()
	return l, nil
}

// dial connects to the current listener, waiting for one to be served.
func (m *memControl) dial() *ControlClient {
	for {
		m.mu.Lock()
		l, changed := m.cur, m.changed
		m.mu.Unlock()
		if l != nil {
			if c, ok := l.dial(); ok {
				return &ControlClient{c: c, enc: json.NewEncoder(c), dec: json.NewDecoder(c)}
			}
		}
		<-changed
	}
}

// memListener is one in-memory control listener.
type memListener struct {
	conns chan net.Conn
	done  chan struct{}
	once  sync.Once
}

func (l *memListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *memListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return nil
}

func (l *memListener) Addr() net.Addr { return memAddr{} }

// dial hands the server end to Accept; false once the listener is closed.
func (l *memListener) dial() (net.Conn, bool) {
	server, client := net.Pipe()
	select {
	case l.conns <- server:
		return client, true
	case <-l.done:
		_ = server.Close()
		_ = client.Close()
		return nil, false
	}
}

type memAddr struct{}

func (memAddr) Network() string { return "mem" }
func (memAddr) String() string  { return "hub-control" }
