package daemon

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strconv"
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
			stats.items += st.Written + st.Relabelled
			if st.Written+st.Unlabelled+st.Skipped+st.Relabelled > 0 || st.Incomplete {
				d.logger.Printf("watchman learn: workbench %d: %d written, %d labelled, %d unlabelled, %d unreadable, %d relabelled, incomplete=%v",
					wb, st.Written, st.Labelled, st.Unlabelled, st.Skipped, st.Relabelled, st.Incomplete)
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

const (
	// watchmanProfileInterval is how often the profiles and the sleep window
	// are rebuilt (spec §8.3, §8.4: weekly).
	watchmanProfileInterval = 7 * 24 * time.Hour
	// watchmanProfileRetryAfter is how long a failed rebuild waits before the
	// next try, so a failing model is not called every cycle.
	watchmanProfileRetryAfter = 24 * time.Hour
)

func (d *Daemon) lastWatchmanProfilePath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_watchman_profile.txt")
}

func (d *Daemon) lastWatchmanProfileFailedPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_watchman_profile_failed.txt")
}

// writeWatchmanStamp writes now as unix seconds to path; a failure is logged.
func (d *Daemon) writeWatchmanStamp(path string, now time.Time) {
	if err := os.WriteFile(path, []byte(strconv.FormatInt(now.Unix(), 10)), 0o600); err != nil {
		d.logger.Printf("watchman: failed to save stamp %s: %v", filepath.Base(path), err)
	}
}

// phaseWatchmanProfile rebuilds, once a week, every Watchman workbench's
// category profiles (one strong-tier call per category with enough
// precedents; pinned entries are never replaced) and its learned sleep
// window (spec §8.3, §8.4). Like phaseCoach: the stamp files
// last_watchman_profile.txt (success) and last_watchman_profile_failed.txt
// (retry a day later) are read each cycle, there is no catch-up, and a cycle
// cancelled mid-run writes neither. Logs carry ids and counts, never text.
func (d *Daemon) phaseWatchmanProfile(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	now := time.Now()
	if last := readUnixStamp(d.lastWatchmanProfilePath()); !last.IsZero() && now.Sub(last) < watchmanProfileInterval {
		return
	}
	if failed := readUnixStamp(d.lastWatchmanProfileFailedPath()); !failed.IsZero() && now.Sub(failed) < watchmanProfileRetryAfter {
		return
	}
	ids, err := d.db.WatchmanWorkbenches()
	if err != nil {
		d.logger.Printf("watchman profile: %v", err)
		return
	}
	if len(ids) == 0 {
		return
	}
	d.trackedPipelineRun("watchman-profile", func() pipelineRunStats {
		gen := d.watchmanGenerator(ctx)
		store := prompts.New(d.db, nil)
		var agentLog *sql.DB
		if d.agentLog != nil {
			agentLog = d.agentLog.DB
		}
		var errs []error
		for _, wb := range ids {
			if err := watchman.BuildProfiles(ctx, d.db, wb, gen, store, now); err != nil {
				d.logger.Printf("watchman profile: workbench %d: %v", wb, err) // errors carry no precedent text
				errs = append(errs, err)
			}
			if _, err := watchman.UpdateSleepWindow(ctx, d.db, agentLog, wb, now, time.Local); err != nil {
				d.logger.Printf("watchman profile: workbench %d: sleep window: %v", wb, err)
				errs = append(errs, err)
			}
		}
		err := errors.Join(errs...)
		if ctx.Err() != nil { // cancelled mid-run (sleep/wake): retried next cycle
			return pipelineRunStats{items: len(ids), err: err}
		}
		if err != nil {
			d.writeWatchmanStamp(d.lastWatchmanProfileFailedPath(), now)
			d.logger.Printf("watchman profile: retried tomorrow")
			return pipelineRunStats{items: len(ids), err: err}
		}
		d.writeWatchmanStamp(d.lastWatchmanProfilePath(), now)
		if err := os.Remove(d.lastWatchmanProfileFailedPath()); err != nil && !os.IsNotExist(err) {
			d.logger.Printf("watchman profile: failed to clear the failure stamp: %v", err)
		}
		return pipelineRunStats{items: len(ids)}
	})
}

// watchmanBacktestRetryAfter is how long after launching a backtest child
// the daemon waits before launching one for the same workbench again when no
// success stamp came back (the child failed or is still running).
const watchmanBacktestRetryAfter = 24 * time.Hour

// SetWatchmanBacktestLaunch wires the launcher of a detached
// `watchtower watchman backtest --workbench N` child (cmd.LaunchWatchmanBacktest);
// nil = the weekly backtest is off.
func (d *Daemon) SetWatchmanBacktestLaunch(f func(workbenchID int64) error) {
	d.watchmanBacktestLaunch = f
}

func (d *Daemon) watchmanBacktestLaunchedPath(workbenchID int64) string {
	return filepath.Join(d.config.WorkspaceDir(), "last_watchman_backtest_launched_"+strconv.FormatInt(workbenchID, 10)+".txt")
}

// phaseWatchmanBacktest starts, once a week per Watchman workbench, its
// backtest (spec §9) — never in-process: about 240 strong-tier calls do not
// belong in the sync cycle. It launches a detached child for at most one due
// workbench per cycle (the child's lock is workspace-wide) and does not wait.
// A workbench is due when its success stamp (watchman.BacktestStampPath,
// written by the child on a finished run, a manual run included) is a week
// old or missing and no launch was tried for it in the last day. A workbench
// still learning (learned_through unset) or still relabelling earlier
// precedents (spec §9.1) is not due: a backtest over part of its history, or
// over unflagged rows, would measure the wrong thing. Nothing is launched while a
// backtest holds the lock.
func (d *Daemon) phaseWatchmanBacktest(ctx context.Context) {
	if d.db == nil || d.watchmanBacktestLaunch == nil || ctx.Err() != nil {
		return
	}
	dir := d.config.WorkspaceDir()
	if watchman.Locked(watchman.LockPath(dir)) {
		return
	}
	ids, err := d.db.WatchmanWorkbenches()
	if err != nil {
		d.logger.Printf("watchman backtest: %v", err)
		return
	}
	now := time.Now()
	for _, wb := range ids {
		st, err := d.db.WatchmanWorkbench(wb)
		if err != nil {
			d.logger.Printf("watchman backtest: workbench %d: %v", wb, err)
			continue
		}
		if st == nil || st.LearnedThrough == nil {
			continue
		}
		pending, err := d.db.WatchmanFlagsPending(wb)
		if err != nil {
			d.logger.Printf("watchman backtest: workbench %d: %v", wb, err)
			continue
		}
		if pending > 0 {
			continue
		}
		if last := readUnixStamp(watchman.BacktestStampPath(dir, wb)); !last.IsZero() && now.Sub(last) < watchmanProfileInterval {
			continue
		}
		if launched := readUnixStamp(d.watchmanBacktestLaunchedPath(wb)); !launched.IsZero() && now.Sub(launched) < watchmanBacktestRetryAfter {
			continue
		}
		// Stamped either way: a launch that fails is tried (and logged) once a day.
		d.writeWatchmanStamp(d.watchmanBacktestLaunchedPath(wb), now)
		if err := d.watchmanBacktestLaunch(wb); err != nil {
			d.logger.Printf("watchman backtest: workbench %d: launching: %v", wb, err)
			return
		}
		d.logger.Printf("watchman backtest: workbench %d: started in the background", wb)
		return // one per cycle: the lock is workspace-wide
	}
}
