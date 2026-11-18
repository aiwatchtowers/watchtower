package relaytest

import (
	"context"
	"net"
	"net/http"
	"sync"
)

// pipeListener serves the fake relay over net.Pipe connections: nothing
// touches the network, so a test may run the relay, the hub and the phone in
// one synctest bubble (a goroutine blocked on a pipe is durably blocked; one
// in a socket read is not).
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

func (l *pipeListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return nil
}

func (l *pipeListener) Addr() net.Addr { return pipeAddr{} }

func (l *pipeListener) dial(ctx context.Context) (net.Conn, error) {
	server, client := net.Pipe()
	select {
	case l.conns <- server:
		return client, nil
	case <-l.done:
	case <-ctx.Done():
	}
	_ = server.Close()
	_ = client.Close()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return nil, net.ErrClosed
}

type pipeAddr struct{}

func (pipeAddr) Network() string { return "pipe" }
func (pipeAddr) String() string  { return "relaytest.pipe:80" }

// HTTPClient is the client every caller of an in-memory server
// (StartInMemory) must use: it dials the server's pipes whatever the URL's
// host. For a Start server it is a plain client over the network.
func (s *Server) HTTPClient() *http.Client {
	if s.pipes == nil {
		return s.srv.Client()
	}
	return s.pipeClient
}
