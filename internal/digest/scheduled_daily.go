package digest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/fsutil"
)

// PreflightRollups checks the actual scheduled period primitive's strong tier.
func (p *Pipeline) PreflightRollups(ctx context.Context) error {
	return Preflight(WithSource(ctx, "digest.daily"), p.generator)
}

type dailyWindow struct{ DayUnix int64 }

// The daemon schedules only daily rollups. Weekly trends and one-off period
// summaries retain their existing cadence and never acquire this descriptor.
func (p *Pipeline) runScheduledDaily(ctx context.Context) error {
	day := utcDayStart(time.Now())
	if !p.DeferredSchedule || !RoutingEnabled(p.generator) {
		return p.runDailyRollupForDate(ctx, day)
	}
	path := filepath.Join(p.cfg.WorkspaceDir(), "digest_pending_daily.json")
	data, err := os.ReadFile(path)
	if err == nil {
		var pending dailyWindow
		if err := json.Unmarshal(data, &pending); err != nil {
			return fmt.Errorf("reading pending daily window: %w", err)
		}
		if pending.DayUnix <= 0 || pending.DayUnix%86400 != 0 {
			return fmt.Errorf("invalid pending daily window")
		}
		day = time.Unix(pending.DayUnix, 0).UTC()
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("reading pending daily window: %w", err)
	} else {
		data, err = json.Marshal(dailyWindow{DayUnix: day.Unix()})
		if err == nil {
			err = fsutil.WriteFileAtomic(path, data, 0o600)
		}
		if err != nil {
			return fmt.Errorf("saving pending daily window: %w", err)
		}
	}
	if err := p.runDailyRollupForDate(ctx, day); err != nil {
		return err
	}
	// The daily row itself is the durable completion stamp. A crash before
	// removal reopens this date and dailyRollupNeeded skips its committed row.
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("clearing pending daily window: %w", err)
	}
	return nil
}
