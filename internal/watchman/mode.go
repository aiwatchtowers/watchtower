package watchman

import "time"

// TwinMode is what the twin may do now (spec 2026-11-16-watchman-design §2).
// It is never stored: whoever needs it computes it with Mode.
type TwinMode string

const (
	// ModeOff: nothing acts; Watchman still learns from the owner.
	ModeOff TwinMode = "off"
	// ModeSleep: the twin decides everything not behind a hard limit and
	// never asks anyone.
	ModeSleep TwinMode = "sleep"
	// ModeAway is reserved for phase 3 (the relay phone); phase 2 never
	// returns it.
	ModeAway TwinMode = "away"
)

// ModeInputs are what the mode is computed from. Phase 2 (D47) has only the
// arming; phase 3 adds the away state, presence, the sleep window and the
// relay phone of spec §2.
type ModeInputs struct {
	Armed   bool
	ArmedAt time.Time
}

// Mode is the twin's mode and since when it holds. Phase 2 (D47, arming is
// the delegation): armed → Sleep since ArmedAt, whatever the owner's
// presence; not armed → Off (since is zero). Pure: it reads nothing.
func Mode(_ time.Time, in ModeInputs) (TwinMode, time.Time) {
	if in.Armed {
		return ModeSleep, in.ArmedAt
	}
	return ModeOff, time.Time{}
}
