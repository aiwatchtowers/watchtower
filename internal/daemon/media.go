package daemon

import (
	"context"
	"time"

	"watchtower/internal/planusage"
)

// mediaCycleBudget bounds one cycle's media pass (checked before each new
// item; a started item finishes).
const mediaCycleBudget = 2 * time.Minute

// phaseMediaDescribe describes the cycle's new images and summarizes its new
// links (internal/media). Part of Knowledge search: off = no fetch, no model
// call, no row and no pipeline_runs row. Near the Claude plan limit the pass
// makes no call and fetches nothing this cycle. Errors are logged only: the
// knowledge index runs next whatever happened here. A cycle with nothing to
// work writes no pipeline_runs row.
func (d *Daemon) phaseMediaDescribe(ctx context.Context) {
	if !d.config.Knowledge.Enabled || d.mediaPipe == nil || d.db == nil || ctx.Err() != nil {
		return
	}
	st, err := d.db.GetPlanUsageStatus()
	if err != nil {
		d.logger.Printf("media: plan usage status: %v", err) // unreadable: does not block
	} else if planusage.NearLimit(st) {
		d.logger.Printf("media: Claude plan limit near, skipped this cycle")
		return
	}
	pending, err := d.mediaPipe.HasPending(ctx)
	if err != nil {
		d.logger.Printf("media: %v", err)
		return
	}
	if !pending {
		return // idle cycle: no pipeline_runs row
	}
	d.trackedPipelineRun("media-describe", func() pipelineRunStats {
		st, err := d.mediaPipe.Run(ctx, mediaCycleBudget)
		if err != nil && !isBenignShutdownErr(ctx, err) {
			d.logger.Printf("media: %v", err)
		}
		if st.Incomplete {
			d.logger.Printf("media: cycle budget reached (%d described, %d copied), continuing next cycle", st.Described, st.Copied)
		}
		return pipelineRunStats{items: st.Described + st.Copied, inTok: st.InTok, outTok: st.OutTok, cost: st.Cost}
	})
}
