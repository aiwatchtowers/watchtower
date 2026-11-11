package ollama

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/http"
	"testing"
	"testing/synctest"
	"time"
)

// A server that accepts the request and never answers fails the call once the
// response-header bound passes, instead of hanging it forever — for both the
// non-streaming Generator and the streaming Client. On synctest's clock over
// in-memory connections, so the bound passes in virtual time.
func TestHTTPClient_ServerThatNeverAnswersTimesOut(t *testing.T) {
	oldTimeout, oldDial := responseHeaderTimeout, dialContext
	responseHeaderTimeout = 100 * time.Millisecond
	t.Cleanup(func() { responseHeaderTimeout, dialContext = oldTimeout, oldDial })

	synctest.Test(t, func(t *testing.T) {
		// Each connection's server reads the request and then only waits:
		// it never writes a byte back.
		dialContext = func(context.Context, string, string) (net.Conn, error) {
			client, server := net.Pipe()
			go func() {
				defer func() { _ = server.Close() }()
				br := bufio.NewReader(server)
				if _, err := http.ReadRequest(br); err != nil {
					return
				}
				_, _ = io.Copy(io.Discard, br) // until the client gives up and closes
			}()
			return client, nil
		}
		const url = "http://ollama.invalid"

		start := time.Now()
		_, _, _, err := NewGenerator("m", "m", url).Generate(context.Background(), "", "hi", "")
		if err == nil {
			t.Fatal("Generate: want a timeout error, got nil")
		}
		if got := time.Since(start); got != responseHeaderTimeout {
			t.Errorf("Generate failed after %v, want the %v response-header bound", got, responseHeaderTimeout)
		}

		start = time.Now()
		_, errCh, _ := NewClient("m", url).Query(context.Background(), "", "hi", "")
		if err := <-errCh; err == nil {
			t.Fatal("Query: want a timeout error, got nil")
		}
		if got := time.Since(start); got != responseHeaderTimeout {
			t.Errorf("Query failed after %v, want the %v response-header bound", got, responseHeaderTimeout)
		}
	})
}
