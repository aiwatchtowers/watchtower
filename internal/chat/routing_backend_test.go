package chat

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/digest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

type routeTestBackend struct {
	starts, turns, closes int
	failure               error
}

func (b *routeTestBackend) Start(context.Context) (string, error) {
	b.starts++
	return "native-private", nil
}
func (b *routeTestBackend) Turn(_ context.Context, c Command, emit func(Event)) error {
	b.turns++
	emit(Event{Type: EventTextDelta, Text: "partial"})
	if b.failure != nil {
		emit(Event{Type: EventError, TurnID: c.TurnID, Cause: b.failure, Retryable: true})
	} else {
		emit(Event{Type: EventTurnDone, TurnID: c.TurnID})
	}
	return nil
}
func (b *routeTestBackend) Cancel() error { return nil }
func (b *routeTestBackend) Close() error  { b.closes++; return nil }

func TestRoutingBackendPreflightAndNeverReplayStartedQuota(t *testing.T) {
	for _, preferred := range []string{"claude", "codex"} {
		t.Run(preferred, func(t *testing.T) {
			reserve := "claude"
			if preferred == "claude" {
				reserve = "codex"
			}
			health := providerhealth.New(t.TempDir(), nil)
			router := &providerrouting.Router{Health: health, Allowed: func(string) error { return nil }}
			leaves := map[string]*routeTestBackend{preferred: {failure: &providers.Failure{Provider: preferred, Category: providers.Quota, Cause: errors.New("quota")}}, reserve: {}}
			req := providerrouting.Request{Preferred: preferred, Reserve: reserve, Mode: providerrouting.PreferredReserve, Tier: digest.TierStrong, Profile: providers.ToolPreflight, Retry: providerrouting.BeforeChild, Model: func(p string, _ digest.Tier) string { return p + "-model" }}
			b := NewRoutingBackend(RoutingOptions{Router: router, Mode: string(req.Mode), Preferred: preferred, Select: func(context.Context, Command) (providerrouting.Request, string, error) { return req, "", nil }, Build: func(_ context.Context, p, m string) (Backend, error) {
				require.Equal(t, p+"-model", m)
				return leaves[p], nil
			}})
			t.Cleanup(func() { _ = b.Close() })
			_, err := b.Start(context.Background())
			require.NoError(t, err)
			require.Zero(t, leaves[preferred].starts)
			var events []Event
			err = b.Turn(context.Background(), Command{TurnID: "one"}, func(e Event) { events = append(events, e) })
			require.Error(t, err)
			require.Equal(t, 1, leaves[preferred].starts)
			require.Equal(t, 1, leaves[preferred].turns)
			require.Zero(t, leaves[reserve].starts)
			require.Equal(t, "partial", events[1].Text)
			terminal := events[len(events)-1]
			require.False(t, terminal.Retryable)
			require.Equal(t, "quota_exhausted", terminal.Reason)
			state, err := health.Read(context.Background(), providerhealth.AccountScope(preferred, ""))
			require.NoError(t, err)
			require.Equal(t, providerhealth.QuotaWait, state.State)
			require.NoError(t, b.Turn(context.Background(), Command{TurnID: "two"}, func(Event) {}))
			require.Equal(t, 1, leaves[preferred].closes)
			require.Equal(t, 1, leaves[reserve].starts)
		})
	}
}
func TestRoutingBackendKnownQuotaCapabilityNoChild(t *testing.T) {
	health := providerhealth.New(t.TempDir(), nil)
	require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope("claude", ""), &providers.Failure{Provider: "claude", Category: providers.Quota}))
	builds := 0
	req := providerrouting.Request{Preferred: "claude", Reserve: "codex", Mode: providerrouting.PreferredReserve, Profile: providers.ToolPreflight, Model: func(string, digest.Tier) string { return "m" }, Capable: func(p string, _ providers.InvocationProfile) bool { return p == "claude" }}
	b := NewRoutingBackend(RoutingOptions{Router: &providerrouting.Router{Health: health, Allowed: func(string) error { return nil }}, Select: func(context.Context, Command) (providerrouting.Request, string, error) { return req, "", nil }, Build: func(context.Context, string, string) (Backend, error) { builds++; return &routeTestBackend{}, nil }})
	require.Error(t, b.Turn(context.Background(), Command{TurnID: "one"}, func(e Event) { require.Equal(t, "required_capability_missing", e.Reason) }))
	require.Zero(t, builds)
	req.Capable = nil
	require.NoError(t, b.Turn(context.Background(), Command{TurnID: "two"}, func(e Event) { require.Equal(t, "codex", e.Provider) }))
	require.Equal(t, 1, builds)
	require.NoError(t, b.Close())
	require.Error(t, b.Turn(context.Background(), Command{TurnID: "three"}, func(Event) {}))
	require.Equal(t, 1, builds)
}

// This traverses ClaudeBackend.Start (a real fake warm process), its reader,
// translator and the emitted-Cause/nil-Turn-error boundary, not a returned error.
func TestRoutingRealClaudeQuotaTerminalRecordsHealthOnce(t *testing.T) {
	for _, partial := range []bool{false, true} {
		name := "zero-visible-events"
		if partial {
			name = "partial-text"
		}
		t.Run(name, func(t *testing.T) { testRoutingRealClaudeQuota(t, partial) })
	}
}
func testRoutingRealClaudeQuota(t *testing.T, partial bool) {
	opts, files := fakeClaude(t, "normal")
	script := `#!/bin/sh
printf 'spawn\n' >> "$FAKE_ARGV"
while IFS= read -r line; do
 case "$line" in *'"type":"user"'*)
 [ "$TASK8_PARTIAL" = yes ] && printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial before quota"}}}'
 printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"quota exhausted","error":{"type":"usage_limit_reached"},"usage":{"input_tokens":2,"output_tokens":1}}'
 ;; esac
done
`
	if partial {
		opts.Env = append(opts.Env, "TASK8_PARTIAL=yes")
	} else {
		script = strings.ReplaceAll(script, `"input_tokens":2,"output_tokens":1`, `"input_tokens":0,"output_tokens":0`)
	}
	require.NoError(t, os.WriteFile(opts.Binary, []byte(script), 0o755))
	health := providerhealth.New(t.TempDir(), nil)
	preferred := NewClaudeBackend(opts)
	reserve := &routeTestBackend{}
	req := providerrouting.Request{Preferred: "claude", Reserve: "codex", Mode: providerrouting.PreferredReserve, Profile: providers.ToolPreflight, Model: func(p string, _ digest.Tier) string { return p + "-model" }}
	b := NewRoutingBackend(RoutingOptions{Router: &providerrouting.Router{Health: health, Allowed: func(string) error { return nil }}, Select: func(context.Context, Command) (providerrouting.Request, string, error) { return req, "", nil }, Build: func(_ context.Context, p, m string) (Backend, error) {
		if p == "claude" {
			return preferred, nil
		}
		return reserve, nil
	}})
	t.Cleanup(func() { _ = b.Close() })
	sink := collectLedger(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := b.Start(ctx)
	require.NoError(t, err)
	var events []Event
	require.Error(t, b.Turn(ctx, Command{TurnID: "first", Text: "question"}, func(e Event) { events = append(events, e) }))
	require.FileExists(t, files.argv)
	data, err := os.ReadFile(files.argv)
	require.NoError(t, err)
	require.Equal(t, "spawn\n", string(data))
	require.Zero(t, reserve.starts)
	terminal, texts := 0, 0
	for _, e := range events {
		if isTerminal(e) {
			terminal++
			require.False(t, e.Retryable)
			require.Equal(t, "quota_exhausted", e.Reason)
		}
		if e.Type == EventTextDelta {
			require.Equal(t, "partial before quota", e.Text)
			texts++
		}
		require.NotEqual(t, "reset", e.Type)
	}
	require.Equal(t, 1, terminal)
	expectedTexts := 0
	if partial {
		expectedTexts = 1
	}
	require.Equal(t, expectedTexts, texts)
	state, err := health.Read(ctx, providerhealth.AccountScope("claude", ""))
	require.NoError(t, err)
	require.Equal(t, providerhealth.QuotaWait, state.State)
	calls := sink.recorded()
	require.Len(t, calls, 1)
	require.NotEmpty(t, calls[0].OperationID)
	require.Equal(t, 1, calls[0].Attempt)
	require.NoError(t, b.Turn(ctx, Command{TurnID: "second", Text: "new question"}, func(Event) {}))
	require.Equal(t, 1, reserve.starts)
	data, err = os.ReadFile(files.argv)
	require.NoError(t, err)
	require.Equal(t, "spawn\n", string(data))
	require.NoError(t, b.Close())
}

func TestRoutingCancelBeforeSelectionNeverBuildsChild(t *testing.T) {
	entered := make(chan struct{})
	finished := make(chan error, 1)
	builds := 0
	b := NewRoutingBackend(RoutingOptions{Router: &providerrouting.Router{}, Select: func(ctx context.Context, _ Command) (providerrouting.Request, string, error) {
		close(entered)
		<-ctx.Done()
		return providerrouting.Request{}, "", ctx.Err()
	}, Build: func(context.Context, string, string) (Backend, error) { builds++; return &routeTestBackend{}, nil }})
	go func() { finished <- b.Turn(context.Background(), Command{TurnID: "cancel"}, func(Event) {}) }()
	<-entered
	require.NoError(t, b.Cancel())
	select {
	case err := <-finished:
		require.ErrorIs(t, err, context.Canceled)
	case <-time.After(time.Second):
		t.Fatal("cancel did not end preflight")
	}
	require.Zero(t, builds)
	require.NoError(t, b.Close())
}
func TestRoutingCloseReapsStubbornWarmChild(t *testing.T) {
	opts, files := fakeClaude(t, "stubborn")
	req := providerrouting.Request{Preferred: "claude", Mode: providerrouting.Pinned, Profile: providers.ToolPreflight, Model: func(string, digest.Tier) string { return "m" }}
	b := NewRoutingBackend(RoutingOptions{Router: &providerrouting.Router{Allowed: func(string) error { return nil }}, Select: func(context.Context, Command) (providerrouting.Request, string, error) { return req, "", nil }, Build: func(context.Context, string, string) (Backend, error) { return NewClaudeBackend(opts), nil }})
	t.Cleanup(func() { _ = b.Close() })
	finished := make(chan error, 1)
	go func() {
		finished <- b.Turn(context.Background(), Command{TurnID: "one", Text: "question"}, func(Event) {})
	}()
	_ = readPIDFile(t, files.pid)
	require.NoError(t, b.Close())
	select {
	case <-finished:
	case <-time.After(3 * time.Second):
		t.Fatal("close did not end the pending turn")
	}
}
