package digest

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// DaemonAICallTimeout bounds a single AI subprocess call made from the
// daemon's sequential pipeline cycle. Without a deadline, a hung claude/codex
// process holds sync.lock for as long as the process lives, freezing every
// later phase in that cycle indefinitely (H8). Interactive commands (ask,
// chat) are bounded by the user instead and must NOT go through this
// decorator — see cliPooledGenerator vs cliGenerator in cmd/generator.go.
const DaemonAICallTimeout = 10 * time.Minute

// timeoutGenerator wraps a Generator so every call is bounded by a wall-clock
// deadline derived from the caller's context, without replacing that
// context — a parent cancellation (e.g. daemon shutdown) still propagates.
type timeoutGenerator struct {
	inner   Generator
	timeout time.Duration
}

// WithCallTimeout returns a Generator that fails a call once it runs longer
// than d, rather than blocking forever on a hung subprocess. Every
// implementation of Generator ultimately runs its subprocess via
// exec.CommandContext(ctx, ...), so the derived deadline kills the process.
//
// The decorator sits INSIDE PooledGenerator (cliPooledGenerator wraps the raw
// generator, then hands it to NewPooledGenerator), so d bounds the call
// itself: time a call spends queued for a pool slot is NOT counted against it.
// A saturated pool can therefore still delay a phase past d — what this
// guarantees is that no single subprocess runs longer than d.
func WithCallTimeout(inner Generator, d time.Duration) Generator {
	return &timeoutGenerator{inner: inner, timeout: d}
}

// CallTimeout reports the bound g carries, if any. Boundedness is otherwise
// invisible from outside this package, and the wiring tests that pin every
// unattended AI path as bounded (H8) need to see it.
func CallTimeout(g Generator) (time.Duration, bool) {
	tg, ok := g.(*timeoutGenerator)
	if !ok {
		return 0, false
	}
	return tg.timeout, true
}

// Generate implements Generator.
//
// A call killed by OUR deadline is reported as a deadline error — wrapping
// context.DeadlineExceeded so errors.Is works at every caller — with the
// inner generator's own message kept in the text (a killed subprocess reports
// "signal: killed", which is the useful part). A call that died because the
// CALLER's context expired (daemon shutdown, a shorter caller deadline) is
// passed through untouched: it is not our cap that fired, and saying so would
// send the reader looking for a 10-minute hang that never happened.
func (g *timeoutGenerator) Generate(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, string, error) {
	parent := ctx
	ctx, cancel := context.WithTimeout(parent, g.timeout)
	defer cancel()

	result, usage, newSessionID, err := g.inner.Generate(ctx, systemPrompt, userMessage, sessionID)
	if err != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) && parent.Err() == nil {
		return "", nil, "", aiCallError{fmt.Errorf("ai call exceeded %s (%v): %w", g.timeout, err, context.DeadlineExceeded)}
	}
	if err != nil {
		return result, usage, newSessionID, aiCallError{err}
	}
	return result, usage, newSessionID, nil
}

// ErrAICall marks an error of the AI call itself — the CLI, the provider or
// the network behind them failed, or the call ran out of time — as opposed to
// a reply that came back and could not be used. Every daemon AI call goes
// through WithCallTimeout, so errors.Is(err, ErrAICall) holds for every such
// failure; the history backfill retries those instead of counting a strike
// against the chunk (docs/features/history-backfill.md).
var ErrAICall = errors.New("ai call failed")

// aiCallError wraps an AI call failure so errors.Is sees ErrAICall without
// changing the message callers log.
type aiCallError struct{ err error }

func (e aiCallError) Error() string   { return e.err.Error() }
func (e aiCallError) Unwrap() []error { return []error{ErrAICall, e.err} }
