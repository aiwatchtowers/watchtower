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
func WithCallTimeout(inner Generator, d time.Duration) Generator {
	return &timeoutGenerator{inner: inner, timeout: d}
}

// Generate implements Generator.
func (g *timeoutGenerator) Generate(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, string, error) {
	ctx, cancel := context.WithTimeout(ctx, g.timeout)
	defer cancel()

	result, usage, newSessionID, err := g.inner.Generate(ctx, systemPrompt, userMessage, sessionID)
	if err != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return "", nil, "", fmt.Errorf("ai call exceeded %s", g.timeout)
	}
	return result, usage, newSessionID, err
}
