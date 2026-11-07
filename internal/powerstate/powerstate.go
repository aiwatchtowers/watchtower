// Package powerstate answers one question for the daemon: is this Mac fully
// awake, or is it in a dark wake?
//
// A dark wake (DarkWake, used by Power Nap and maintenance wakes) brings the
// CPU, network and disk up for a few seconds while the lid is closed or the
// Mac sleeps, with no graphics. Network cycles started then are cut off when
// the Mac goes back to sleep, so the daemon skips them.
//
// Power management reports the system's state as capability bits. Apple's own
// IOPMGetCapabilitiesDescription (IOKit) names a state "FullWake" when both the
// CPU and the video bits are set and "DarkWake" when the CPU bit is set
// without the video bit; this package uses the same rule. The video bit is
// the system's graphics capability, not the display: a display that has gone
// to sleep on its own (display sleep, screen saver) is expected to leave the
// system in full wake, as display sleep is not system sleep in the power
// management model. That expectation follows from the model; it has not been
// measured by this package's tests.
//
// FullWake fails open: no reader installed (tests, non-darwin, cgo off), a
// read error, or an unreadable state all answer true, so a wrong answer can
// only cost a skipped guard, never a stopped daemon.
package powerstate

import (
	"errors"
	"sync"
)

// Capability bits as power management reports them. The values match the
// public IOPM.h enum (kIOPMSystemCapabilityCPU = 0x01,
// kIOPMSystemCapabilityGraphics = 0x02) and the bits that
// IOPMConnectionGetSystemCapabilities returns (cpu = 0x1, vid = 0x2 in
// IOPMGetCapabilitiesDescription's output).
const (
	capCPU   uint32 = 0x01
	capVideo uint32 = 0x02
)

// errNoCPU marks a capability read without the CPU bit: a running process
// always has the CPU, so such a value is not a real state.
var errNoCPU = errors.New("powerstate: capabilities without the CPU bit")

var (
	mu sync.RWMutex
	// reader returns the system capability bits. nil until main calls
	// UseSystemReader, so a test binary never reads the real state.
	reader func() (uint32, error)
)

// FullWake reports whether the Mac is fully awake. It is false only when the
// installed reader reports a dark wake; every other case is true (fail open).
func FullWake() bool {
	mu.RLock()
	r := reader
	mu.RUnlock()
	if r == nil {
		return true
	}
	caps, err := r()
	if err != nil {
		return true
	}
	return fullWakeFrom(caps)
}

// fullWakeFrom decides from capability bits: the CPU bit without the video
// bit is a dark wake; anything else — full wake, or a value without the CPU
// bit that cannot describe a running process — reads as awake.
func fullWakeFrom(caps uint32) bool {
	if caps&capCPU == 0 {
		return true
	}
	return caps&capVideo != 0
}

func setReader(r func() (uint32, error)) {
	mu.Lock()
	reader = r
	mu.Unlock()
}

// SetReaderForTesting is for tests only: it installs r (nil = no reader) and
// returns a restore that puts the previous reader back. Production code never
// calls it.
func SetReaderForTesting(r func() (caps uint32, err error)) (restore func()) {
	mu.RLock()
	old := reader
	mu.RUnlock()
	setReader(r)
	return func() { setReader(old) }
}
