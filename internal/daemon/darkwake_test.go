package daemon

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

// Log lines of the dark wake gate.
const (
	logDarkWakeDefers = "dark wake (Power Nap), deferring the cycle until full wake"
	logFullWakeStarts = "full wake, starting the deferred cycle"
	logTriggerIdle    = "manual sync trigger received, syncing"
)

// setDarkWakeRecheck sets darkWakeRecheckInterval for one test. Call it
// before startLoop, so the loop has stopped before the cleanup restores it.
func setDarkWakeRecheck(t *testing.T, d time.Duration) {
	t.Helper()
	prev := darkWakeRecheckInterval
	darkWakeRecheckInterval = d
	t.Cleanup(func() { darkWakeRecheckInterval = prev })
}

// A daemon started in a dark wake defers its first cycle and starts it once
// the probe reports a full wake.
func TestRunLoop_DarkWakeDefersTheFirstCycleUntilFullWake(t *testing.T) {
	setDarkWakeRecheck(t, 10*time.Millisecond)
	h := startLoop(t, loopOpts{darkWake: true})

	h.logs.waitLog(t, logDarkWakeDefers, 1)
	requireNone(t, h.probe.started, 100*time.Millisecond, "a cycle in a dark wake")
	h.fullWake.Store(true)
	recv(t, h.probe.started, "the deferred cycle at full wake")
	h.stop(t)

	assert.Equal(t, 1, h.logs.count(logDarkWakeDefers), "the deferral is logged once, whatever the re-checks")
	assert.Equal(t, 1, h.logs.count(logFullWakeStarts))
}

// A poll tick in a dark wake starts no cycle; the ticks during the deferral
// collapse into one deferred cycle, started once the probe reports a full
// wake.
func TestRunLoop_DarkWakeDefersTicksIntoOneCycle(t *testing.T) {
	setDarkWakeRecheck(t, 10*time.Millisecond)
	h := startLoop(t, loopOpts{poll: 20 * time.Millisecond})

	recv(t, h.probe.started, "the initial cycle, in a full wake")
	h.fullWake.Store(false)
	h.logs.waitLog(t, logDarkWakeDefers, 1)
	// Several ticks pass while the Mac stays in the dark wake.
	requireNone(t, h.probe.started, 150*time.Millisecond, "a tick's cycle in a dark wake")
	h.fullWake.Store(true)
	recv(t, h.probe.started, "the deferred cycle at full wake")
	h.stop(t)

	assert.Equal(t, 1, h.logs.count(logDarkWakeDefers), "the ticks collapse into one deferral")
	assert.Equal(t, 1, h.logs.count(logFullWakeStarts), "one deferred cycle")
}

// Sync Now is never gated: in a dark wake it runs at once, and a cycle
// deferred before it is folded into it.
func TestRunLoop_TriggerInDarkWakeRunsAtOnce(t *testing.T) {
	setDarkWakeRecheck(t, 10*time.Millisecond)
	h := startLoop(t, loopOpts{darkWake: true})

	h.logs.waitLog(t, logDarkWakeDefers, 1)
	h.pressSyncNow(t, logTriggerIdle)
	recv(t, h.probe.started, "the triggered cycle in a dark wake")

	// The deferral is gone: a full wake now starts nothing more.
	h.fullWake.Store(true)
	requireNone(t, h.probe.started, 100*time.Millisecond, "the deferred cycle after the trigger ran it")
	h.stop(t)
	assert.Zero(t, h.logs.count(logFullWakeStarts))
}

// The end of the post-wake wait in a dark wake defers the cycle it would
// start; the full wake starts it.
func TestRunLoop_SettleEndInDarkWakeDefers(t *testing.T) {
	shortenWakeSettle(t)
	setDarkWakeRecheck(t, 10*time.Millisecond)
	h := startLoop(t, loopOpts{syncOnWake: true, blockFirst: true})

	recv(t, h.probe.started, "the initial cycle")
	h.probe.block.Store(false)
	h.fullWake.Store(false)
	h.wake <- 10 * time.Minute
	recv(t, h.probe.cancelled, "the sleep's cancellation")
	h.logs.waitLog(t, logSleptCycleEnds, 1)
	h.logs.waitLog(t, logDarkWakeDefers, 1)
	requireNone(t, h.probe.started, 100*time.Millisecond, "a cycle in a dark wake")
	h.fullWake.Store(true)
	recv(t, h.probe.started, "the deferred cycle at full wake")
	h.stop(t)

	assert.Zero(t, h.logs.count("syncing after wake"), "the delay's end started nothing")
	assert.Equal(t, 1, h.logs.count(logFullWakeStarts))
}

// A sleep during the deferral takes the post-wake wait; its end asks the
// probe again and keeps the cycle deferred in a dark wake — sync_on_wake off
// too, since a cycle is owed — without a second deferral line.
func TestRunLoop_SleepDuringDarkWakeDeferralTakesTheSettlePath(t *testing.T) {
	shortenWakeSettle(t)
	setDarkWakeRecheck(t, 10*time.Millisecond)
	h := startLoop(t, loopOpts{darkWake: true})

	h.logs.waitLog(t, logDarkWakeDefers, 1)
	h.wake <- 10 * time.Minute
	h.logs.waitLog(t, "sleep detected (slept ~10m0s), waiting", 1)
	requireNone(t, h.probe.started, 100*time.Millisecond, "a cycle in a dark wake after the delay")
	h.fullWake.Store(true)
	recv(t, h.probe.started, "the deferred cycle at full wake")
	h.stop(t)

	assert.Equal(t, 1, h.logs.count(logDarkWakeDefers), "still the one deferral")
}

// The deferred cycle survives the post-wake wait with sync_on_wake off: a
// full wake by the delay's end starts it there.
func TestRunLoop_DeferredCycleRunsAtSettleEndInFullWake(t *testing.T) {
	setWakeSettle(t, 50*time.Millisecond)
	setDarkWakeRecheck(t, time.Hour) // only the delay's end can start it
	h := startLoop(t, loopOpts{darkWake: true})

	h.logs.waitLog(t, logDarkWakeDefers, 1)
	h.wake <- 10 * time.Minute
	h.logs.waitLog(t, "sleep detected (slept ~10m0s), waiting", 1)
	h.fullWake.Store(true)
	recv(t, h.probe.started, "the deferred cycle at the delay's end")
	h.stop(t)

	assert.Equal(t, 1, h.logs.count("syncing after wake"))
}

// Shutdown while a cycle is deferred starts nothing and returns cleanly.
func TestRunLoop_ShutdownDuringDarkWakeDeferral(t *testing.T) {
	setDarkWakeRecheck(t, 10*time.Millisecond)
	h := startLoop(t, loopOpts{darkWake: true})

	h.logs.waitLog(t, logDarkWakeDefers, 1)
	h.stop(t)
	h.fullWake.Store(true)
	requireNone(t, h.probe.started, 100*time.Millisecond, "a cycle after shutdown")
	assert.Zero(t, h.logs.count(logFullWakeStarts))
	assert.Equal(t, 1, h.logs.count("shutting down"))
}

// The probe defaults to a full wake: New and SetFullWakeProbe(nil) gate
// nothing.
func TestSetFullWakeProbe_DefaultIsFullWake(t *testing.T) {
	d := New(nil)
	assert.True(t, d.inFullWake())
	d.SetFullWakeProbe(func() bool { return false })
	assert.False(t, d.inFullWake())
	d.SetFullWakeProbe(nil)
	assert.True(t, d.inFullWake())
	assert.True(t, (&Daemon{}).inFullWake(), "a Daemon built without New")
}
