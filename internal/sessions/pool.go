// Package sessions manages concurrency limiting for Claude CLI calls.
package sessions

import (
	"context"
	"fmt"
	"sync"
)

// Worker represents a slot in the concurrency pool.
type Worker struct{}

// SessionPool admits calls through one shared limit, including calls retaining
// an older routing snapshot. Reducing the limit never cancels existing calls.
type SessionPool struct {
	mu           sync.Mutex
	size, active int
	closed       bool
	changed      chan struct{}
}

func NewSessionPool(size int) *SessionPool {
	return &SessionPool{size: max(size, 1), changed: make(chan struct{})}
}

func (p *SessionPool) notify() { close(p.changed); p.changed = make(chan struct{}) }

// Acquire waits for admission or cancellation. Close wakes all waiters.
func (p *SessionPool) Acquire(ctx context.Context) (*Worker, error) {
	for {
		p.mu.Lock()
		if p.closed {
			p.mu.Unlock()
			return nil, fmt.Errorf("session pool is closed")
		}
		if err := ctx.Err(); err != nil {
			p.mu.Unlock()
			return nil, fmt.Errorf("acquire timeout: %w", err)
		}
		if p.active < p.size {
			p.active++
			p.mu.Unlock()
			return &Worker{}, nil
		}
		changed := p.changed
		p.mu.Unlock()
		select {
		case <-changed:
		case <-ctx.Done():
			return nil, fmt.Errorf("acquire timeout: %w", ctx.Err())
		}
	}
}

// Release returns an admitted worker, including after Close or Resize.
func (p *SessionPool) Release(_ *Worker) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.active > 0 {
		p.active--
		p.notify()
	}
}

// Resize changes admission for future calls across every generation.
func (p *SessionPool) Resize(size int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.size = max(size, 1)
	p.notify()
}

func (p *SessionPool) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.closed {
		p.closed = true
		p.notify()
	}
}

func (p *SessionPool) Size() int { p.mu.Lock(); defer p.mu.Unlock(); return p.size }
