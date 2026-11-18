package oauthpage

import (
	"errors"
	"io"
	"net"
	"net/http"
	"testing"

	"github.com/stretchr/testify/require"
)

// serveCallback serves h on a loopback listener and returns the server, its
// URL and Serve's result.
func serveCallback(t *testing.T, h http.Handler) (*http.Server, string, <-chan error) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	server := &http.Server{Handler: h} //nolint:gosec // a test server
	served := make(chan error, 1)
	go func() { served <- server.Serve(l) }()
	t.Cleanup(func() { _ = server.Close() })
	return server, "http://" + l.Addr().String() + "/callback", served
}

// A page still being written when the login ends reaches the browser whole:
// the close waits for it instead of cutting the connection.
func TestCloseCallbackServer_DeliversThePageInFlight(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	server, url, served := serveCallback(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		close(entered)
		<-release
		_, _ = io.WriteString(w, "connected")
	}))
	// Released only once the shutdown has begun: a bare Close would cut the
	// connection first (and never start a shutdown, so a regression hangs here
	// until go test -timeout).
	shutdown := make(chan struct{})
	server.RegisterOnShutdown(func() { close(shutdown) })

	type page struct {
		body string
		err  error
	}
	got := make(chan page, 1)
	go func() {
		resp, err := http.Get(url) //nolint:gosec,noctx // the test's own loopback URL
		if err != nil {
			got <- page{err: err}
			return
		}
		defer resp.Body.Close()
		b, err := io.ReadAll(resp.Body)
		got <- page{string(b), err}
	}()
	<-entered
	closed := make(chan struct{})
	go func() { CloseCallbackServer(server); close(closed) }()
	<-shutdown
	close(release)

	p := <-got
	require.NoError(t, p.err)
	require.Equal(t, "connected", p.body)
	<-closed
	require.True(t, errors.Is(<-served, http.ErrServerClosed))
}

// With no request in flight the server is closed and Serve returns.
func TestCloseCallbackServer_IdleServerCloses(t *testing.T) {
	server, _, served := serveCallback(t, http.NotFoundHandler())
	CloseCallbackServer(server)
	require.True(t, errors.Is(<-served, http.ErrServerClosed))
}
