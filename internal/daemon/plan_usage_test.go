package daemon

import (
	"context"
	"log"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/config"

	"github.com/stretchr/testify/assert"
)

type fakePlanRunner struct{ started, stopped chan struct{} }

func (f *fakePlanRunner) Run(ctx context.Context) error {
	close(f.started)
	<-ctx.Done()
	close(f.stopped)
	return nil
}

func newPlanUsageTestDaemon(t *testing.T, enabled bool) *Daemon {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	var syncCount atomic.Int32
	orch, _ := newTestOrchestrator(t, &syncCount)
	cfg := &config.Config{
		Sync:      config.SyncConfig{PollInterval: 10 * time.Second},
		PlanUsage: config.PlanUsageConfig{Enabled: enabled},
	}
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-daemon] ", 0))
	return d
}

func TestStartPlanUsage_RunsAndStops(t *testing.T) {
	d := newPlanUsageTestDaemon(t, true)
	r := &fakePlanRunner{started: make(chan struct{}), stopped: make(chan struct{})}
	d.SetPlanUsage(r, func() error { t.Error("disable called while on"); return nil })
	stop := d.startPlanUsage(context.Background())
	<-r.started
	stop()
	<-r.stopped
}

func TestStartPlanUsage_OffMarksDisabled(t *testing.T) {
	d := newPlanUsageTestDaemon(t, false)
	called := false
	d.SetPlanUsage(&fakePlanRunner{started: make(chan struct{}), stopped: make(chan struct{})}, func() error { called = true; return nil })
	d.startPlanUsage(context.Background())()
	assert.True(t, called)
}
