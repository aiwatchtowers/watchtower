package daemon

import (
	"context"
	"errors"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/agentlogdb"
)

// agentAnalyticsBudget bounds one cycle, split across the enabled
// workbenches. The daemon is the importer (#849: `agents enable` no longer
// scans): a first backfill spreads over cycles, each resuming where the last
// stopped, then the phase only catches up new lines.
const agentAnalyticsBudget = 30 * time.Second

// agentAnalyticsClaudeDir is a test seam for the Claude config directory.
var agentAnalyticsClaudeDir = agentlog.DefaultClaudeDir

// phaseAgentAnalytics keeps agentlog.db current for every workbench with
// agent_analytics = 1. Inert (no pipeline_runs row) when none is enabled —
// gated by the workbench column, not a config key (FEAT-01 note) — and when
// agentlog.db did not open (logged once per daemon run). When the one-time
// move out of watchtower.db has not completed (the start's upgrade step
// failed), each cycle tries it again, as `agents scan` does, and scans once
// it succeeds; a failure skips the cycle (logged once per daemon run). Never
// a fallback to watchtower.db.
func (d *Daemon) phaseAgentAnalytics(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	ids, err := d.db.AgentAnalyticsWorkbenchIDs()
	if err != nil {
		d.logger.Printf("agent analytics: listing workbenches: %v", err)
		return
	}
	if len(ids) == 0 {
		return
	}
	if d.agentLog == nil {
		if d.agentLogSkipLogged.CompareAndSwap(false, true) {
			d.logger.Printf("agent analytics: agentlog.db is not open; skipped until the next start (%d workbench(es) enabled)", len(ids))
		}
		return
	}
	switch moved, err := d.agentLog.Moved(); {
	case err != nil:
		d.logger.Printf("agent analytics: %v; skipped", err)
		return
	case !moved:
		res, err := agentlogdb.MoveFromMain(ctx, d.db, d.agentLog, agentlogdb.MoveLockPath(d.agentLogPath))
		if err != nil {
			if d.agentLogMoveLogged.CompareAndSwap(false, true) {
				d.logger.Printf("%v (moving: %v); skipped, retried every cycle (%d workbench(es) enabled)", agentlogdb.ErrNotMoved, err, len(ids))
			}
			return
		}
		if res != nil {
			d.logger.Print(res)
		}
	}
	d.trackedPipelineRun("agent-analytics", func() pipelineRunStats {
		var items int
		var errs []error
		per := agentAnalyticsBudget / time.Duration(len(ids))
		for _, id := range ids {
			res, err := agentlog.Scan(ctx, d.db, d.agentLog, id, agentlog.Options{ClaudeDir: agentAnalyticsClaudeDir(), Budget: per})
			if err != nil {
				if isBenignShutdownErr(ctx, err) {
					break
				}
				d.logger.Printf("agent analytics: workbench %d: %v", id, err)
				errs = append(errs, err)
			}
			if res == nil { // a failed progress write still returns what the scan did
				continue
			}
			items += res.EventsWritten
			if res.FailedFiles > 0 {
				d.logger.Printf("agent analytics: workbench %d: %d file(s) failed, retrying next cycle; first: %v", id, res.FailedFiles, res.FirstFailure)
			}
			if res.Incomplete {
				d.logger.Printf("agent analytics: workbench %d: cycle budget reached, continuing next cycle", id)
			}
		}
		return pipelineRunStats{items: items, err: errors.Join(errs...)}
	})
}
