package digest

import (
	"context"
	"crypto/rand"
	"encoding/hex"
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

type dailyWindow struct {
	DayUnix   int64
	AttemptID string
}

// The daemon schedules only daily rollups. Weekly trends and one-off period
// summaries retain their existing cadence and never acquire this descriptor.
func (p *Pipeline) runScheduledDaily(ctx context.Context) error {
	day := utcDayStart(time.Now())
	if !p.DeferredSchedule || !RoutingEnabled(p.generator) {
		return p.runDailyRollupForDate(ctx, day)
	}
	path := filepath.Join(p.cfg.WorkspaceDir(), "digest_pending_daily.json")
	data, err := os.ReadFile(path)
	var pending dailyWindow
	if err == nil {
		if err := json.Unmarshal(data, &pending); err != nil {
			return fmt.Errorf("reading pending daily window: %w", err)
		}
		_, tokenErr := hex.DecodeString(pending.AttemptID)
		if pending.DayUnix <= 0 || pending.DayUnix%86400 != 0 || len(pending.AttemptID) != 32 || tokenErr != nil {
			return fmt.Errorf("invalid pending daily window")
		}
		day = time.Unix(pending.DayUnix, 0).UTC()
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("reading pending daily window: %w", err)
	} else {
		var token [16]byte
		if _, err := rand.Read(token[:]); err != nil {
			return fmt.Errorf("creating daily attempt identity: %w", err)
		}
		pending = dailyWindow{DayUnix: day.Unix(), AttemptID: hex.EncodeToString(token[:])}
		data, err = json.Marshal(pending)
		if err == nil {
			err = fsutil.WriteFileAtomic(path, data, 0o600)
		}
		if err != nil {
			return fmt.Errorf("saving pending daily window: %w", err)
		}
	}
	completed, err := p.db.DailyDigestAttemptCompleted(float64(day.Unix()), float64(day.Add(24*time.Hour-time.Second).Unix()), pending.AttemptID)
	if err != nil {
		return err
	}
	if !completed {
		p.dailyAttemptID = pending.AttemptID
		defer func() { p.dailyAttemptID = "" }()
		if err := p.runDailyRollupForDate(ctx, day); err != nil {
			return err
		}
	}
	// The row carries an atomic completion token for this claim. Source rows
	// arriving after that commit belong to a fresh ordinary claim, even when
	// they would make dailyRollupNeeded true for the retained descriptor.
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("clearing pending daily window: %w", err)
	}
	return nil
}
