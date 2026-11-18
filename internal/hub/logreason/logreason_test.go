package logreason

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

func TestReasonOf(t *testing.T) {
	conflict := &client.Error{E: &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_CONFLICT, Message: "record acme-secret"}}
	opErr := &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connection refused to acme.example.com")}
	cases := []struct {
		name string
		err  error
		want string
	}{
		{"nil", nil, "no error"},
		{"an unmapped relay code", fmt.Errorf("slices: saving: %w", relay.MapError(conflict)), "relay code CONFLICT"},
		{"a mapped relay code", relay.MapError(&client.Error{E: &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_UNAVAILABLE}}), "relay code UNAVAILABLE"},
		{"a relay code inside a join", errors.Join(errors.New("kind a"), fmt.Errorf("kind b: %w", conflict)), "relay code CONFLICT"},
		{"a typed error under wrappers", fmt.Errorf("saving: %w", fmt.Errorf("%w: %w", transport.ErrUnavailable, opErr)), "*net.OpError"},
		{"plain texts only", fmt.Errorf("x: %w", errors.New("y")), "untyped"},
		{"a context error", fmt.Errorf("x: %w", context.Canceled), "untyped"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := of(c.err)
			if got != c.want {
				t.Fatalf("of = %q, want %q", got, c.want)
			}
			if strings.Contains(got, "acme") {
				t.Fatalf("of leaked the error's text: %q", got)
			}
		})
	}
	if got := With("other", conflict); got != "other: relay code CONFLICT" {
		t.Fatalf("With = %q", got)
	}
	// #1872's classes already name the code: no repeat.
	if got := With("relay_conflict", conflict); got != "relay_conflict" {
		t.Fatalf("With = %q", got)
	}
}

func newTestLimiter(every time.Duration) (*Limiter, *time.Time, *[]string) {
	now := time.Date(2026, 11, 16, 14, 0, 0, 0, time.UTC)
	var out []string
	l := NewLimiter(every, func() time.Time { return now })
	l.print = func(s string) { out = append(out, s) }
	return l, &now, &out
}

func TestLimiterHoldsRepeatsAndCountsThem(t *testing.T) {
	l, now, out := newTestLimiter(10 * time.Minute)
	l.Printf("publish failed (%s)", "other")
	for range 5 {
		*now = now.Add(10 * time.Second)
		l.Printf("publish failed (%s)", "other")
	}
	if len(*out) != 1 || (*out)[0] != "publish failed (other)" {
		t.Fatalf("within the window: %q", *out)
	}
	*now = now.Add(10 * time.Minute)
	l.Printf("publish failed (%s)", "other")
	want := "publish failed (other) (repeated 5 more times over 10m50s)"
	if len(*out) != 2 || (*out)[1] != want {
		t.Fatalf("after the window: %q, want %q", *out, want)
	}
	// The count starts again from the line just logged.
	*now = now.Add(11 * time.Minute)
	l.Printf("publish failed (%s)", "other")
	if (*out)[2] != "publish failed (other)" {
		t.Fatalf("no copy held: %q", (*out)[2])
	}
}

func TestLimiterLogsADifferentLineAtOnce(t *testing.T) {
	l, now, out := newTestLimiter(10 * time.Minute)
	l.Printf("a")
	*now = now.Add(time.Second)
	l.Printf("b")
	l.Printf("a")
	if strings.Join(*out, ",") != "a,b" {
		t.Fatalf("got %q", *out)
	}
}

func TestLimiterPrunesWhenFull(t *testing.T) {
	l, now, out := newTestLimiter(time.Minute)
	for i := range maxLines {
		l.Printf("line %d", i)
	}
	*now = now.Add(time.Minute)
	l.Printf("one more")
	if len(l.lines) != 1 {
		t.Fatalf("old lines kept: %d", len(l.lines))
	}
	// Every line recent: the map is cleared rather than grown.
	for i := range maxLines {
		l.Printf("fresh %d", i)
	}
	if len(l.lines) > maxLines {
		t.Fatalf("map grew past the bound: %d", len(l.lines))
	}
	if len(*out) != 2*maxLines+1 {
		t.Fatalf("lines logged: %d", len(*out))
	}
}

// Keyed holds copies by their key though their lines differ, and logs the
// copy after the window with its own line.
func TestLimiterKeyedHoldsByKey(t *testing.T) {
	l, now, out := newTestLimiter(10 * time.Minute)
	l.Keyed("unavailable", "failed; kinds: a")
	*now = now.Add(time.Minute)
	l.Keyed("unavailable", "failed; kinds: a, b")
	*now = now.Add(10 * time.Minute)
	l.Keyed("unavailable", "failed; kinds: b")
	want := []string{"failed; kinds: a", "failed; kinds: b (repeated 1 more times over 11m0s)"}
	if strings.Join(*out, "|") != strings.Join(want, "|") {
		t.Fatalf("got %q, want %q", *out, want)
	}
}

// A nil Limiter (a runtime a test built by hand) logs every line.
func TestNilLimiterLogs(t *testing.T) {
	var l *Limiter
	l.Printf("line %d", 1)
	l.Keyed("k", "line 2")
}
