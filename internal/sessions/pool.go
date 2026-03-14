// Package sessions manages Claude CLI session pooling for efficient reuse.
package sessions

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// Worker represents a single reusable Claude session.
type Worker struct {
	SessionID string
	CreatedAt time.Time
}

// SessionPool manages a fixed number of reusable Claude sessions.
// Workers are distributed on-demand and must be returned after use.
type SessionPool struct {
	workers chan *Worker
	mu      sync.Mutex
	closed  bool
}

// NewSessionPool creates a pool with size workers.
// Each worker starts with an empty SessionID (created on first use).
func NewSessionPool(size int) *SessionPool {
	if size <= 0 {
		size = 1
	}
	workers := make(chan *Worker, size)
	for i := 0; i < size; i++ {
		workers <- &Worker{
			SessionID: "",
			CreatedAt: time.Now(),
		}
	}
	return &SessionPool{
		workers: workers,
	}
}

// Acquire waits for a free worker. Returns error if pool is closed.
func (p *SessionPool) Acquire(ctx context.Context) (*Worker, error) {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return nil, fmt.Errorf("session pool is closed")
	}
	p.mu.Unlock()

	select {
	case w := <-p.workers:
		return w, nil
	case <-ctx.Done():
		return nil, fmt.Errorf("acquire timeout: %w", ctx.Err())
	}
}

// Release returns a worker to the pool after use.
// Updates the worker's SessionID if a new one was obtained.
func (p *SessionPool) Release(w *Worker) {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.mu.Unlock()

	select {
	case p.workers <- w:
	default:
		// Channel full — should not happen, but prevent goroutine leak
	}
}

// Close closes the pool and stops accepting new acquire requests.
// Already-acquired workers must still be released.
func (p *SessionPool) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.closed {
		return
	}
	p.closed = true

	// Drain workers without blocking
	close(p.workers)
	for range p.workers {
		// Just drain
	}
}

// Size returns the pool capacity.
func (p *SessionPool) Size() int {
	return cap(p.workers)
}
