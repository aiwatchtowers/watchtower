package daemon

import "context"

// PlanUsageRunner is the Claude plan limits poller (internal/planusage).
type PlanUsageRunner interface {
	Run(ctx context.Context) error
}

// SetPlanUsage attaches the poller and the "feature is off" writer.
func (d *Daemon) SetPlanUsage(r PlanUsageRunner, disable func() error) {
	d.planUsage, d.planUsageDisable = r, disable
}

// startPlanUsage runs the poller beside the sync loop when plan_usage.enabled
// is on, and only while sync is not paused (runUnlessPaused); off, it records
// the disabled state once so the Desktop says so.
func (d *Daemon) startPlanUsage(ctx context.Context) (stop func()) {
	if d.planUsage == nil {
		return func() {}
	}
	if !d.config.PlanUsage.Enabled {
		if err := d.planUsageDisable(); err != nil {
			d.logger.Printf("plan usage: marking disabled: %v", err)
		}
		d.logger.Println("plan usage: disabled (plan_usage.enabled=false), poller not started")
		return func() {}
	}
	runCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		d.runUnlessPaused(runCtx, "plan usage: poller", d.planUsage.Run)
	}()
	return func() {
		cancel()
		<-done
	}
}
