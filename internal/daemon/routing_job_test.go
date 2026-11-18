package daemon

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/config"

	"github.com/stretchr/testify/require"
)

type routingMailProbe struct {
	seen    chan string
	release chan struct{}
}

func (p *routingMailProbe) Sync(ctx context.Context) (int, error) {
	p.seen <- config.RoutingSnapshot(ctx, nil).AI.Provider
	select {
	case <-p.release:
	case <-ctx.Done():
		return 0, ctx.Err()
	}
	p.seen <- config.RoutingSnapshot(ctx, nil).AI.Provider
	return 0, nil
}
func (*routingMailProbe) FetchRange(context.Context, time.Time, time.Time) (int, error) {
	return 0, nil
}
func (*routingMailProbe) AccountID() int64                 { return 1 }
func (*routingMailProbe) FirstSyncFrom() (time.Time, bool) { return time.Time{}, false }

func TestDaemonRoutingJobCapturesActualSyncBoundaryAndKeepsCheckpoint(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := newQuietDaemon(t)
	d.backfillCursor = 42
	var current atomic.Pointer[config.Config]
	old := &config.Config{}
	old.AI.Provider = "claude"
	next := &config.Config{}
	next.AI.Provider = "codex"
	current.Store(old)
	d.SetRoutingJob(func(ctx, fetchCtx context.Context) (context.Context, context.Context) {
		snapshot := current.Load()
		return config.WithRoutingSnapshot(ctx, snapshot), config.WithRoutingSnapshot(fetchCtx, snapshot)
	})
	probe := &routingMailProbe{seen: make(chan string, 4), release: make(chan struct{}, 2)}
	d.imapSyncers = []mailSyncer{probe}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first := d.startCycle(ctx, false)
	defer func() { cancel(); <-first.done }()
	require.Equal(t, "claude", <-probe.seen)
	current.Store(next)
	probe.release <- struct{}{}
	require.Equal(t, "claude", <-probe.seen, "a running fetch/job retains its original generation")
	<-first.done
	second := d.startCycle(ctx, false)
	defer func() { cancel(); <-second.done }()
	require.Equal(t, "codex", <-probe.seen)
	probe.release <- struct{}{}
	require.Equal(t, "codex", <-probe.seen)
	<-second.done
	require.EqualValues(t, 42, d.backfillCursor, "routing publication does not recreate checkpoint owners")
}

func TestDaemonRoutingWatchStopsWithSamePIDOwner(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := newQuietDaemon(t)
	d.config.Sync.PollInterval = time.Hour
	d.wakeCh = make(chan time.Duration)
	path := filepath.Join(t.TempDir(), "daemon.pid")
	d.SetPIDPath(path)
	ready := make(chan []byte, 1)
	observed := make(chan []byte, 1)
	apply := make(chan struct{})
	stopped := make(chan struct{})
	d.SetRoutingWatch(func(ctx context.Context) {
		defer close(stopped)
		data, _ := os.ReadFile(path)
		ready <- data
		for {
			select {
			case <-ctx.Done():
				return
			case <-apply:
				data, _ := os.ReadFile(path)
				observed <- data
			}
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- d.Run(ctx) }()
	defer func() { cancel(); <-stopped }()
	identity := <-ready
	require.NotEmpty(t, identity)
	apply <- struct{}{}
	require.Equal(t, identity, <-observed, "hot publication runs inside the same daemon PID/start identity")
	cancel()
	require.NoError(t, <-done)
	_, err := os.Stat(path)
	require.True(t, os.IsNotExist(err), "normal daemon cleanup still owns PID removal")
}
