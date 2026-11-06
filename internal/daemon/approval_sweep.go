package daemon

import (
	"context"
	"time"

	"watchtower/internal/automations/builtin"
)

// phaseApprovalSweep redraws the Needs approval folder when its artifacts
// drifted from the open approvals (builtin.SweepApprovals): a reminder that
// came due — REMIND-01 has no flip a hook could see —, an approval whose
// hook could not enqueue, a closed or deleted one. It reads only (never a
// reminder or an action) and fires at most once a cycle; a read or enqueue
// error is logged and the cycle goes on.
func (d *Daemon) phaseApprovalSweep(ctx context.Context) {
	if d.db == nil {
		return
	}
	fired, err := builtin.SweepApprovals(ctx, d.db, time.Now(), d.wakeAutomationExecutor)
	switch {
	case err != nil:
		d.logger.Printf("approval sweep: %v", err)
	case fired:
		d.logger.Printf("approval sweep: the Needs approval folder drifted; a run is queued")
	}
}
