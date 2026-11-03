package guide

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
)

// Only scheduled Run uses this descriptor; explicit RunForWindow and optional
// reduce/team work do not acquire durable jobs. It contains no source content.
type peopleWindow struct {
	From      float64
	To        float64
	StartedAt time.Time
}

func (p *Pipeline) Preflight(ctx context.Context) error {
	return digest.Preflight(digest.WithSource(ctx, "people.batch"), p.generator)
}
func (p *Pipeline) windowPath() string {
	return filepath.Join(p.cfg.WorkspaceDir(), "people_pending_window.json")
}
func (p *Pipeline) scheduledWindow(claim bool) (float64, float64, time.Time, error) {
	from, to := p.currentWindow()
	now := time.Now()
	if !p.DeferredSchedule || !digest.RoutingEnabled(p.generator) || p.ForceRegenerate {
		return from, to, now, nil
	}
	data, err := os.ReadFile(p.windowPath())
	if err == nil {
		var w peopleWindow
		if err := json.Unmarshal(data, &w); err != nil {
			return 0, 0, time.Time{}, fmt.Errorf("reading pending people window: %w", err)
		}
		if w.From >= w.To || w.StartedAt.IsZero() {
			return 0, 0, time.Time{}, fmt.Errorf("invalid pending people window")
		}
		return w.From, w.To, w.StartedAt, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return 0, 0, time.Time{}, fmt.Errorf("reading pending people window: %w", err)
	}
	if claim {
		data, err = json.Marshal(peopleWindow{from, to, now})
		if err == nil {
			err = fsutil.WriteFileAtomic(p.windowPath(), data, 0o600)
		}
		if err != nil {
			return 0, 0, time.Time{}, fmt.Errorf("saving pending people window: %w", err)
		}
	}
	return from, to, now, nil
}
func (p *Pipeline) runScheduledWindow(ctx context.Context) (int, error) {
	from, to, started, err := p.scheduledWindow(true)
	if err != nil {
		return 0, err
	}
	p.RunStartedAt = time.Time{}
	if p.DeferredSchedule && digest.RoutingEnabled(p.generator) && !p.ForceRegenerate {
		p.RunStartedAt = started
	}
	return p.RunForWindow(ctx, from, to)
}

// AcknowledgeWindow is called only after the daemon durably writes its success
// stamp, or discards a window with no eligible input. A crash before
// acknowledgement reopens the same covered window.
func (p *Pipeline) AcknowledgeWindow() error {
	if !p.DeferredSchedule || !digest.RoutingEnabled(p.generator) || p.ForceRegenerate {
		return nil
	}
	if err := os.Remove(p.windowPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("clearing pending people window: %w", err)
	}
	return nil
}
