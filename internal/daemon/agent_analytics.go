package daemon

import (
	"context"
	"errors"
	"time"

	"watchtower/internal/agentlog"
)

// agentAnalyticsBudget bounds one cycle; a big first backfill normally ran
// already in `agents enable`, so this only catches up new lines.
const agentAnalyticsBudget = 30 * time.Second

// agentAnalyticsClaudeDir is a test seam for the Claude config directory.
var agentAnalyticsClaudeDir = agentlog.DefaultClaudeDir

// phaseAgentAnalytics keeps agent_log_* current for every workbench with
// agent_analytics = 1. Inert (no pipeline_runs row) when none is enabled —
// gated by the workbench column, not a config key (FEAT-01 note).
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
	d.trackedPipelineRun("agent-analytics", func() pipelineRunStats {
		var items int
		var errs []error
		per := agentAnalyticsBudget / time.Duration(len(ids))
		for _, id := range ids {
			res, err := agentlog.Scan(ctx, d.db, id, agentlog.Options{ClaudeDir: agentAnalyticsClaudeDir(), Budget: per})
			if err != nil {
				if isBenignShutdownErr(ctx, err) {
					break
				}
				d.logger.Printf("agent analytics: workbench %d: %v", id, err)
				errs = append(errs, err)
				continue
			}
			items += res.EventsWritten
			if res.Incomplete {
				d.logger.Printf("agent analytics: workbench %d: cycle budget reached, continuing next cycle", id)
			}
		}
		return pipelineRunStats{items: items, err: errors.Join(errs...)}
	})
}
