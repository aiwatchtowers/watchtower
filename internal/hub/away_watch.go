package hub

import (
	"context"
	"time"

	"watchtower/internal/hub/platform"
)

// awayEvery is how often the hub reads whether the owner left the Mac.
const awayEvery = 3 * time.Second

// awayWatch nudges the work alerts when the owner leaves the Mac (the Swift
// FastLane's owner-away hook, workbench-remote spec §5.2): a stop left
// unresolved then pushes at once instead of on the next full diff. Coming
// back nudges nothing. platform.Away has no change notification, so it is
// read every awayEvery, only while a phone is linked; the first read after
// a start (or after a phone is linked) only learns the state.
type awayWatch struct {
	away   platform.Away
	active func() bool
	nudge  func()

	primed, was bool
}

// check reads the owner's state once and nudges on a change to away. A
// failed read changes nothing.
func (a *awayWatch) check() {
	if !a.active() {
		a.primed = false
		return
	}
	away, err := a.away.Away()
	if err != nil {
		return
	}
	if a.primed && away && !a.was {
		a.nudge()
	}
	a.primed, a.was = true, away
}

// run checks every awayEvery until ctx ends.
func (a *awayWatch) run(ctx context.Context) {
	t := time.NewTicker(awayEvery)
	defer t.Stop()
	for {
		a.check()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
