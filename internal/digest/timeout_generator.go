package digest

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os/exec"
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
// CALLER's context expired (daemon shutdown, a shorter caller deadline) keeps
// its message: it is not our cap that fired, and saying so would send the
// reader looking for a 10-minute hang that never happened. A transport-level
// failure (see ErrAICall) also matches ErrAICall; its message is unchanged.
func (g *timeoutGenerator) Generate(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, string, error) {
	parent := ctx
	ctx, cancel := context.WithTimeout(parent, g.timeout)
	defer cancel()

	result, usage, newSessionID, err := g.inner.Generate(ctx, systemPrompt, userMessage, sessionID)
	if err != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) && parent.Err() == nil {
		return "", nil, "", WithCause(fmt.Errorf("ai call exceeded %s (%v): %w", g.timeout, err, context.DeadlineExceeded), ErrAICall)
	}
	if err != nil && aiTransportFailure(err) {
		return result, usage, newSessionID, WithCause(err, ErrAICall)
	}
	return result, usage, newSessionID, err
}

// ErrAICall marks a transport-level failure of an AI call: the call timed
// out, its process could not start or was killed, or the network to the
// provider failed. The history backfill retries those instead of counting a
// strike against the chunk (docs/features/history-backfill.md). A reply that
// came back — an error envelope (any subtype, error_max_turns included), an
// empty result, output the parser cannot read, a non-zero exit with a message
// — is about the request, not the transport, and does not match.
var ErrAICall = errors.New("ai call failed")

// aiTransportFailure reports the failures ErrAICall stands for.
func aiTransportFailure(err error) bool {
	var execErr *exec.Error
	var pathErr *fs.PathError
	var exitErr *exec.ExitError
	var netErr net.Error
	return errors.Is(err, context.DeadlineExceeded) ||
		errors.Is(err, exec.ErrNotFound) ||
		errors.As(err, &execErr) || errors.As(err, &pathErr) ||
		(errors.As(err, &exitErr) && !exitErr.Exited()) || // killed by a signal
		errors.As(err, &netErr)
}

// WithCause returns an error with err's message that also matches cause in
// errors.Is and errors.As, so a generator can keep its readable message and
// still expose the exec error behind it.
func WithCause(err, cause error) error { return causeError{err, cause} }

type causeError struct{ err, cause error }

func (e causeError) Error() string   { return e.err.Error() }
func (e causeError) Unwrap() []error { return []error{e.err, e.cause} }
