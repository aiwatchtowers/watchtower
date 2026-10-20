package daemon

import (
	"context"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeSleepClock is a sleepClock a test moves by hand: awake time advances
// both clocks, a sleep only the wall clock.
type fakeSleepClock struct {
	mu    gosync.Mutex
	wall  time.Time
	mono  time.Duration
	reads chan struct{} // one send per read, after it
}

func (c *fakeSleepClock) read() (time.Time, time.Duration) {
	c.mu.Lock()
	wall, mono := c.wall, c.mono
	c.mu.Unlock()
	c.reads <- struct{}{}
	return wall, mono
}

func (c *fakeSleepClock) awake(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.wall = c.wall.Add(d)
	c.mono += d
}

func (c *fakeSleepClock) sleep(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.wall = c.wall.Add(d)
}

// wakeWatch is a watcher over a fake clock and a hand-driven tick.
type wakeWatch struct {
	clock *fakeSleepClock
	ticks chan time.Time
	ch    <-chan time.Duration
}

func startWakeWatch(t *testing.T) *wakeWatch {
	t.Helper()
	clock := &fakeSleepClock{wall: time.Now().Round(0), reads: make(chan struct{}, 8)}
	ticks := make(chan time.Time)
	ch := watchWake(t.Context(), ticks, clock.read)
	<-clock.reads // the baseline
	return &wakeWatch{clock: clock, ticks: ticks, ch: ch}
}

// check runs one watcher check and reports what it sent, if anything. A
// second, fencing check follows: the watcher takes its tick only after the
// first check's send, and the test waits for its clock read, so no check is
// still running when the test moves the clock next.
func (w *wakeWatch) check() (time.Duration, bool) {
	for range 2 {
		w.ticks <- time.Time{}
		<-w.clock.reads
	}
	select {
	case gap := <-w.ch:
		return gap, true
	default:
		return 0, false
	}
}

func TestWatchWake_FiresOnWallClockJump(t *testing.T) {
	w := startWakeWatch(t)
	clock := w.clock

	clock.awake(wakeCheckInterval)
	clock.sleep(33 * time.Minute)
	gap, fired := w.check()
	require.True(t, fired, "a wall clock 33 minutes ahead of the monotonic one is a sleep")
	assert.Equal(t, 33*time.Minute, gap)
}

// A Power Nap gives the process a couple of seconds between sleeps: the gap
// accumulated before the first check after them is still reported.
func TestWatchWake_FiresAcrossDarkWakes(t *testing.T) {
	w := startWakeWatch(t)
	clock := w.clock

	for range 3 {
		clock.sleep(10 * time.Minute)
		clock.awake(time.Second)
	}
	gap, fired := w.check()
	require.True(t, fired)
	assert.Equal(t, 30*time.Minute, gap)
}

func TestWatchWake_NoFireWithoutJump(t *testing.T) {
	w := startWakeWatch(t)
	clock := w.clock

	for range 5 {
		clock.awake(wakeCheckInterval)
		_, fired := w.check()
		assert.False(t, fired, "awake time alone is not a sleep")
	}
	clock.awake(wakeCheckInterval)
	clock.sleep(sleepGapThreshold - time.Second)
	_, fired := w.check()
	assert.False(t, fired, "a gap under the threshold is jitter, not a sleep")

	clock.mu.Lock()
	clock.wall = clock.wall.Add(-time.Hour) // the clock set back by hand
	clock.mu.Unlock()
	_, fired = w.check()
	assert.False(t, fired, "a wall clock set back never reads as a sleep")
}

// The watcher fires once per sleep: the check after the reported one sees no
// new gap.
func TestWatchWake_FiresOncePerSleep(t *testing.T) {
	w := startWakeWatch(t)
	clock := w.clock

	clock.sleep(time.Hour)
	_, fired := w.check()
	require.True(t, fired)
	clock.awake(wakeCheckInterval)
	_, fired = w.check()
	assert.False(t, fired)
}

func TestWatchWake_ClosesOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := WatchWake(ctx)
	cancel()

	select {
	case _, ok := <-ch:
		assert.False(t, ok, "no wake without a sleep, only the close")
	case <-time.After(2 * time.Second):
		t.Fatal("wake channel was not closed after context cancellation")
	}
}

// The real clock's wall reading carries no monotonic reading: with one, the
// watcher's wall subtraction would use the monotonic clock, which stops in
// sleep, and the detector would never fire. Its monotonic side advances.
func TestSystemSleepClock_WallIsStrippedMonoAdvances(t *testing.T) {
	clock := systemSleepClock()
	wall, mono := clock()
	assert.NotContains(t, wall.String(), "m=", "the wall reading must carry no monotonic reading")
	assert.Equal(t, wall.Round(0), wall)

	time.Sleep(time.Millisecond)
	_, later := clock()
	assert.Greater(t, later, mono, "the monotonic reading advances")
}
