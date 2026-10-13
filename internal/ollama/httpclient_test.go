package ollama

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// A server that accepts the request and never answers fails the call once the
// response-header bound passes, instead of hanging it forever — for both the
// non-streaming Generator and the streaming Client.
func TestHTTPClient_ServerThatNeverAnswersTimesOut(t *testing.T) {
	old := responseHeaderTimeout
	responseHeaderTimeout = 100 * time.Millisecond
	t.Cleanup(func() { responseHeaderTimeout = old })

	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(release) })

	done := make(chan error, 1)
	go func() {
		_, _, _, err := NewGenerator("m", "m", srv.URL).Generate(context.Background(), "", "hi", "")
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("Generate: want a timeout error, got nil")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Generate hung on a server that never answers")
	}

	_, errCh, _ := NewClient("m", srv.URL).Query(context.Background(), "", "hi", "")
	select {
	case err := <-errCh:
		if err == nil {
			t.Fatal("Query: want a timeout error, got nil")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Query hung on a server that never answers")
	}
}
