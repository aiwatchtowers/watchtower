package ollama

import (
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/logcanary"
	"watchtower/internal/logredact"
)

// TestFILES01_OllamaBodyStaysOnTheError: an Ollama error body is kept whole
// on the returned error and reaches the log only as a fingerprint.
func TestFILES01_OllamaBodyStaysOnTheError(t *testing.T) {
	canary := logcanary.Text("ollama.body")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"model said: '` + canary + `'"}`))
	}))
	t.Cleanup(srv.Close)
	sink := logcanary.Capture(t)
	ctx := context.Background()

	c := NewClient("m", srv.URL)
	_, _, err := c.QuerySync(ctx, "sys", "msg", "")
	require.Contains(t, logredact.Full(err), canary)
	log.Printf("ollama sync: %v", err)

	textCh, errCh, _ := c.Query(ctx, "sys", "msg", "")
	for range textCh {
	}
	err = <-errCh
	require.Contains(t, logredact.Full(err), canary)
	log.Printf("ollama stream: %v", err)

	_, _, _, err = NewGenerator("l", "s", srv.URL).Generate(ctx, "sys", "msg", "")
	require.Contains(t, logredact.Full(err), canary)
	log.Printf("ollama generate: %v", err)

	require.Contains(t, sink.String(), "HTTP 500")
	sink.AssertClean(t)
}
