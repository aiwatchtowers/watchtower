package automationstest

import (
	"context"
	"sync"

	"watchtower/internal/digest"
)

// FakeCall is one Generate call a FakeGenerator received.
type FakeCall struct {
	SystemPrompt, UserMessage, SessionID string
}

// FakeGenerator is a digest.Generator that records its calls. Call i replies
// Replies[i] with Usage[i]; past the end of a slice it repeats the slice's
// last element (an empty reply and nil usage when the slice is empty).
type FakeGenerator struct {
	Replies []string
	Usage   []digest.Usage
	Calls   []FakeCall

	mu sync.Mutex
}

var _ digest.Generator = (*FakeGenerator)(nil)

// Generate records the call and returns the scripted reply.
func (g *FakeGenerator) Generate(_ context.Context, systemPrompt, userMessage, sessionID string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	i := len(g.Calls)
	g.Calls = append(g.Calls, FakeCall{SystemPrompt: systemPrompt, UserMessage: userMessage, SessionID: sessionID})
	var reply string
	if n := len(g.Replies); n > 0 {
		reply = g.Replies[min(i, n-1)]
	}
	var usage *digest.Usage
	if n := len(g.Usage); n > 0 {
		u := g.Usage[min(i, n-1)]
		usage = &u
	}
	return reply, usage, sessionID, nil
}

// CallCount returns how many Generate calls the fake received.
func (g *FakeGenerator) CallCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.Calls)
}
