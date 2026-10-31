package platform

import (
	"testing"
	"time"
)

// awayFrom is OwnerAwayPolicy.isAway, plus "no readable console session".
func TestAwayFromThePolicy(t *testing.T) {
	present := consoleInputs{hasSession: true, onConsole: true, idle: 10 * time.Second}
	cases := []struct {
		name string
		edit func(*consoleInputs)
		away bool
	}{
		{"at the Mac", func(*consoleInputs) {}, false},
		{"screen locked", func(c *consoleInputs) { c.screenLocked = true }, true},
		{"displays asleep", func(c *consoleInputs) { c.displaysAsleep = true }, true},
		{"idle just under 3 min", func(c *consoleInputs) { c.idle = IdleThreshold - time.Millisecond }, false},
		{"idle 3 min", func(c *consoleInputs) { c.idle = IdleThreshold }, true},
		{"session switched away", func(c *consoleInputs) { c.onConsole = false }, true},
		{"no console session", func(c *consoleInputs) { *c = consoleInputs{} }, true},
	}
	for _, c := range cases {
		in := present
		c.edit(&in)
		if got := awayFrom(in); got != c.away {
			t.Errorf("%s: away = %v, want %v", c.name, got, c.away)
		}
	}
	if IdleThreshold != 180*time.Second {
		t.Errorf("IdleThreshold = %v", IdleThreshold)
	}
}
