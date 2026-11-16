package daemon

import (
	"context"
	"errors"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/instructions"
	"watchtower/internal/prompts"
	"watchtower/internal/watchman"
)

// watchmanLearnBudget is the time one cycle's learning may take, shared by
// every Watchman workbench; the cursors carry the rest to the next cycle.
const watchmanLearnBudget = 5 * time.Minute

// Seams tests replace.
var (
	// watchmanGeneratorFactory builds the labeller's generator: the coach's
	// stdin-only factory (the owner's text never goes on argv, CHAT-04); the
	// tier is digest.TierForSource("watchman.label"), light.
	watchmanGeneratorFactory = func(cfg *config.Config) digest.Generator { return coachGeneratorFactory(cfg) }
	watchmanGit              = watchman.ExecGit
	watchmanFeedReader       = func(ctx context.Context, d *Daemon) instructions.FeedReader {
		return instructions.NewFeedReader(ctx, d.db, coachSessionDirs())
	}
)

// phaseWatchmanLearn continues learning on each workbench Watchman is on for
// (spec 2026-11-16-watchman-design §8): the database sources, the owner's
// turns where Agent analytics is on (turned off later, that source stays
// empty), and the folder's git history. Mechanical except the light-tier
// labels. Logs carry ids and counts, never text.
func (d *Daemon) phaseWatchmanLearn(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	ids, err := d.db.WatchmanWorkbenches()
	if err != nil {
		d.logger.Printf("watchman learn: %v", err)
		return
	}
	if len(ids) == 0 {
		return
	}
	d.trackedPipelineRun("watchman-learn", func() pipelineRunStats {
		start := time.Now()
		labeler := watchman.NewLLMLabeler(d.watchmanGenerator(ctx), prompts.New(d.db, nil))
		var stats pipelineRunStats
		var errs []error
		for _, wb := range ids {
			left := watchmanLearnBudget - time.Since(start)
			if left <= 0 {
				d.logger.Printf("watchman learn: cycle budget reached, continuing next cycle")
				break
			}
			sources := watchman.DBSources()
			analytics, err := d.db.WorkbenchAgentAnalytics(wb)
			if err != nil {
				d.logger.Printf("watchman learn: workbench %d: %v", wb, err)
			}
			if analytics {
				sources = append(sources, watchman.TurnSource(watchmanFeedReader(ctx, d)))
			}
			sources = append(sources, watchman.GitSource(watchmanGit))
			st, err := watchman.Learn(ctx, d.db, wb, watchman.LearnOptions{Budget: left, Sources: sources, Labeler: labeler})
			stats.items += st.Written
			if st.Written+st.Unlabelled+st.Skipped > 0 || st.Incomplete {
				d.logger.Printf("watchman learn: workbench %d: %d written, %d labelled, %d unlabelled, %d unreadable, incomplete=%v",
					wb, st.Written, st.Labelled, st.Unlabelled, st.Skipped, st.Incomplete)
			}
			if err != nil {
				if isBenignShutdownErr(ctx, err) {
					// The cursors move only with their batch: the next cycle
					// resumes cleanly (the phaseKnowledgeIndex precedent).
					d.logger.Printf("watchman learn: stopped by shutdown")
					break
				}
				d.logger.Printf("watchman learn: workbench %d: %v", wb, err) // source errors are fingerprinted (FILES-01)
				errs = append(errs, err)
			}
		}
		stats.err = errors.Join(errs...)
		return stats
	})
}

// watchmanGenerator shares the worker pool with the rest of the cycle, like
// coachGenerator.
func (d *Daemon) watchmanGenerator(ctx context.Context) digest.Generator {
	gen := watchmanGeneratorFactory(config.RoutingSnapshot(ctx, d.config))
	if d.aiWorkerPool != nil {
		gen = digest.WithCallTimeout(digest.NewPooledGenerator(gen, d.aiWorkerPool), digest.DaemonAICallTimeout)
	}
	return gen
}
