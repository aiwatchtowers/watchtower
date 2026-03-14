package sessions

import (
	"context"
	"testing"
	"time"
)

func TestNewSessionPool(t *testing.T) {
	p := NewSessionPool(5)
	if p.Size() != 5 {
		t.Errorf("expected size 5, got %d", p.Size())
	}
	p.Close()
}

func TestSessionPoolAcquireRelease(t *testing.T) {
	p := NewSessionPool(2)
	defer p.Close()

	ctx := context.Background()

	// Acquire first worker
	w1, err := p.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire 1 failed: %v", err)
	}
	if w1 == nil {
		t.Fatal("worker 1 is nil")
	}

	// Acquire second worker
	w2, err := p.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire 2 failed: %v", err)
	}
	if w2 == nil {
		t.Fatal("worker 2 is nil")
	}

	// Acquire with timeout (should block)
	ctx2, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	_, err = p.Acquire(ctx2)
	if err == nil {
		t.Fatal("expected timeout error")
	}

	// Release and retry
	p.Release(w1)
	w1b, err := p.Acquire(context.Background())
	if err != nil {
		t.Fatalf("acquire after release failed: %v", err)
	}
	if w1b == nil {
		t.Fatal("released worker is nil")
	}

	p.Release(w2)
	p.Release(w1b)
}

func TestSessionPoolClose(t *testing.T) {
	p := NewSessionPool(1)

	ctx := context.Background()
	w, err := p.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire failed: %v", err)
	}

	p.Close()

	// Should reject new acquires
	_, err = p.Acquire(context.Background())
	if err == nil {
		t.Fatal("expected error after close")
	}

	// Release should be safe (no panic)
	p.Release(w)
}

func TestSessionPoolSessionIDUpdate(t *testing.T) {
	p := NewSessionPool(1)
	defer p.Close()

	ctx := context.Background()
	w, _ := p.Acquire(ctx)

	if w.SessionID != "" {
		t.Errorf("initial SessionID should be empty, got %q", w.SessionID)
	}

	// Simulate updating SessionID after a Claude call
	w.SessionID = "test-session-123"
	p.Release(w)

	// Acquire again — should have same SessionID
	w2, _ := p.Acquire(ctx)
	if w2.SessionID != "test-session-123" {
		t.Errorf("expected SessionID to persist, got %q", w2.SessionID)
	}

	p.Release(w2)
}

func TestSessionPoolConcurrency(t *testing.T) {
	p := NewSessionPool(3)
	defer p.Close()

	const workers = 10
	const iterations = 5

	done := make(chan struct{})

	for i := 0; i < workers; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			ctx := context.Background()
			for j := 0; j < iterations; j++ {
				w, err := p.Acquire(ctx)
				if err != nil {
					t.Errorf("acquire failed: %v", err)
					return
				}
				// Simulate work
				time.Sleep(1 * time.Millisecond)
				w.SessionID = "concurrent-session"
				p.Release(w)
			}
		}()
	}

	for i := 0; i < workers; i++ {
		<-done
	}
}

func TestSessionPoolZeroSize(t *testing.T) {
	p := NewSessionPool(0)
	defer p.Close()

	if p.Size() != 1 {
		t.Errorf("expected minimum size 1, got %d", p.Size())
	}
}
