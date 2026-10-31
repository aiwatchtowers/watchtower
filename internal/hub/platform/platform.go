// Package platform holds the hub's Mac-only inputs (spec §9 "Mac-only
// inputs"): whether the owner is away from the Mac (the work alerts push
// only then; workbench-remote spec §5.1) and the keep-awake power assertion
// (the Swift MacAwakeAssertion). Both are read and taken through cgo on
// darwin; on linux there is no console to sit at, so the owner is always
// away, and there is no keep-awake.
package platform

import "time"

// IdleThreshold is how long the console may go without input before the
// owner reads as away (OwnerAwayPolicy.idleThreshold).
const IdleThreshold = 180 * time.Second

// AwakeReason is the keep-awake assertion's name (MacAwakeAssertion.reason).
const AwakeReason = "Watchtower: a session is running and your iPhone is connected"

// Away reports whether the owner is away from the Mac.
type Away interface{ Away() (bool, error) }

// Awake takes a "prevent idle system sleep" assertion; release ends it (a
// second call does nothing).
type Awake interface {
	Hold(reason string) (release func(), err error)
}

// consoleInputs is what owner-away is decided from (OwnerAwayCenter.Inputs).
// hasSession is false when the console session could not be read at all.
type consoleInputs struct {
	hasSession     bool
	screenLocked   bool
	onConsole      bool
	displaysAsleep bool
	idle           time.Duration
}

// awayFrom is OwnerAwayPolicy.isAway: the screen is locked, the displays
// sleep, the console had no input for IdleThreshold, or the console user
// session is not active. No readable console session at all (a process
// outside the owner's login session) counts as away: nobody sits at it.
func awayFrom(in consoleInputs) bool {
	return !in.hasSession || in.screenLocked || in.displaysAsleep || in.idle >= IdleThreshold || !in.onConsole
}
