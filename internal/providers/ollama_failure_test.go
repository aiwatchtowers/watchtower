package providers

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
	"unicode/utf8"
)

// TestOllamaFailure_StatusTable: an OpenAI-compatible server's HTTP status
// and body become one typed category; the cause is kept for the owner.
func TestOllamaFailure_StatusTable(t *testing.T) {
	cause := errors.New("ollama returned HTTP …")
	for _, tc := range []struct {
		status int
		body   string
		want   ErrorCategory
	}{
		{401, `{"error":"unauthorized"}`, Auth},
		{403, `{"error":"forbidden"}`, Auth},
		{404, `{"error":"model \"llama9\" not found, try pulling it first"}`, Model},
		{404, `404 page not found`, Transport},
		{429, `{"error":"too many requests"}`, RateLimit},
		{500, `{"error":"llama runner process has terminated"}`, Transport},
		{503, `{"error":"server busy, please try again"}`, Overload},
		{400, `{"error":{"message":"This model's maximum context length is 8192 tokens"}}`, ContextLimit},
		{500, `{"error":"input length exceeds the context length"}`, ContextLimit},
		{0, `the request exceeds the available context size`, ContextLimit},
		{400, `{"error":"invalid request"}`, Unknown},
		{0, `out of memory`, Unknown},
	} {
		t.Run(fmt.Sprintf("%d/%s", tc.status, tc.body), func(t *testing.T) {
			err := OllamaFailure(tc.status, tc.body, cause)
			failure := requireCategory(t, err, tc.want)
			if failure.Provider != "ollama" {
				t.Fatalf("provider=%q", failure.Provider)
			}
			if !errors.Is(err, cause) || err.Error() != cause.Error() {
				t.Fatalf("cause lost: %v", err)
			}
		})
	}
}

// A request that never got an answer is typed from the error itself:
// cancellation and deadlines stay theirs, a refused connection is transport.
func TestOllamaRequestFailure_Typed(t *testing.T) {
	_ = requireCategory(t, OllamaRequestFailure(fmt.Errorf("ollama request failed: %w", context.Canceled)), Cancelled)
	_ = requireCategory(t, OllamaRequestFailure(fmt.Errorf("ollama request failed: %w", context.DeadlineExceeded)), Timeout)
	_ = requireCategory(t, OllamaRequestFailure(fmt.Errorf("ollama request failed: %w", &net.OpError{Op: "dial", Err: errors.New("connection refused")})), Transport)
	if OllamaRequestFailure(nil) != nil {
		t.Fatal("nil stays nil")
	}
}

// ServerErrorText is the owner's text of an error an OpenAI-compatible
// server reports inside a 200 answer: the type in brackets, never empty,
// capped on a rune boundary.
func TestServerErrorText(t *testing.T) {
	if got := ServerErrorText("  model not found ", "invalid_request_error"); got != "model not found (invalid_request_error)" {
		t.Errorf("got %q", got)
	}
	if got := ServerErrorText("", ""); got != "the model server reported an error with no message" {
		t.Errorf("empty: got %q", got)
	}
	long := ServerErrorText(strings.Repeat("é", 2000), "")
	if !utf8.ValidString(long) || len(long) > maxServerErrorText+64 || !strings.Contains(long, "bytes truncated") {
		t.Errorf("long: %d bytes, valid=%v", len(long), utf8.ValidString(long))
	}
}
