// Package feed publishes the dashboard's social-wall feed index (feed_items)
// from source tables. Pure SQL, zero AI calls (DASH-06); additive and
// state-preserving (DASH-05). See docs/inventory/dashboard.md.
package feed

import (
	"errors"
	"fmt"
	"log"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// Pipeline mirrors source tables into the feed_items index each daemon cycle.
type Pipeline struct {
	db     *db.DB
	cfg    *config.Config
	logger *log.Logger
}

func New(database *db.DB, cfg *config.Config, logger *log.Logger) *Pipeline {
	if logger == nil {
		logger = log.Default()
	}
	return &Pipeline{db: database, cfg: cfg, logger: logger}
}

// Publish upserts feed items for every source. Best-effort per source: one
// failing source is logged and reported but never blocks the others, and no
// failure here may affect the inbox pipeline or its watermarks (DASH-06).
// Returns the number of rows inserted/updated and the joined source errors.
func (p *Pipeline) Publish(now time.Time) (int, error) {
	cutoff, err := p.db.GetFeedBootstrapCutoff()
	if err != nil {
		return 0, fmt.Errorf("feed bootstrap cutoff: %w", err)
	}
	nowTS := now.UTC().Format("2006-01-02T15:04:05Z")
	windowEnd := now.UTC().
		Add(time.Duration(p.cfg.Feed.MeetingLeadMinutes) * time.Minute).
		Format("2006-01-02T15:04:05Z")

	total := 0
	var errs []error
	run := func(name string, fn func() (int, error)) {
		n, err := fn()
		if err != nil {
			p.logger.Printf("feed: %s publish failed: %v", name, err)
			errs = append(errs, fmt.Errorf("%s: %w", name, err))
			return
		}
		total += n
	}
	run("situation", p.db.PublishSituationFeedItems)
	run("meeting", func() (int, error) { return p.db.PublishMeetingFeedItems(nowTS, windowEnd) })
	run("briefing", func() (int, error) { return p.db.PublishBriefingFeedItems(cutoff) })
	run("meeting_recap", func() (int, error) { return p.db.PublishRecapFeedItems(cutoff) })
	run("day_plan", func() (int, error) { return p.db.PublishDayPlanFeedItems(cutoff) })
	return total, errors.Join(errs...)
}
