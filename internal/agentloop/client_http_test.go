package agentloop

import (
	"net/http"
	"testing"

	"watchtower/internal/tools"
)

// The runtime-B client waits a bounded time for response headers (a server
// that never answers fails the turn) but carries no total timeout, which would
// cut a long generation short.
func TestNewClient_HTTPClientIsBounded(t *testing.T) {
	c := NewClient("m", "", nil, tools.Binding{})
	tr, ok := c.httpc.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("httpc.Transport = %T, want *http.Transport", c.httpc.Transport)
	}
	if tr.ResponseHeaderTimeout <= 0 {
		t.Error("ResponseHeaderTimeout unset: a server that never answers hangs the turn")
	}
	if c.httpc.Timeout != 0 {
		t.Errorf("Timeout = %v, want none (a total bound would cut long generations)", c.httpc.Timeout)
	}
}
