// Package powerstate answers one question for the daemon: is this Mac fully
// awake, or is it in a dark wake?
//
// A dark wake (DarkWake, used by Power Nap and maintenance wakes) brings the
// CPU, network and disk up for a few seconds while the lid is closed or the
// Mac sleeps, with no graphics. Network cycles started then are cut off when
// the Mac goes back to sleep, so the daemon skips them.
//
// The power state comes from the IORegistry: IOPMrootDomain's "System
// Capabilities" property, a number in the public IOPM.h layout
// (kIOPMSystemCapabilityCPU = 0x01, kIOPMSystemCapabilityGraphics = 0x02,
// Audio 0x04, Network 0x08, AOT 0x10). The CPU bit without the graphics bit is
// a dark wake; both set is a full wake. The property's key name is not
// declared in a public header, but it is read through public API only
// (IOServiceGetMatchingService + IORegistryEntryCreateCFProperty), so a macOS
// that drops or renames it makes the read fail, and FullWake fails open.
// IOKit's IOPMConnectionGetSystemCapabilities was rejected: it is declared
// only in Apple's private IOPMLibPrivate.h, and linking a private export means
// a macOS that removes it stops the whole binary from loading, not just this
// check.
//
// The graphics bit is the system's graphics capability, not the display: a
// display that has gone to sleep on its own (display sleep, screen saver) is
// expected to leave the system in full wake, as display sleep is not system
// sleep in the power management model. That expectation follows from the
// model; it has not been measured by this package's tests.
//
// FullWake fails open: no reader installed (tests, non-darwin, cgo off), a
// read error, or an unreadable state all answer true, so a wrong answer can
// only cost a skipped guard, never a stopped daemon.
package powerstate

import (
	"sync"
)

// Capability bits in the public IOPM.h layout; reader_darwin.go checks at
// compile time that they equal kIOPMSystemCapabilityCPU and
// kIOPMSystemCapabilityGraphics.
const (
	capCPU      uint32 = 0x01
	capGraphics uint32 = 0x02
)

var (
	mu sync.RWMutex
	// reader returns the system capability bits. nil until main calls
	// UseSystemReader, so a test binary never reads the real state.
	reader func() (uint32, error)
)

// Read returns the raw capability bits, the verdict and the read error. With
// no reader installed it is (0, true, nil); on a read error it is
// (0, true, err) — the verdict always fails open, so a caller may log err and
// still act on full.
func Read() (caps uint32, full bool, err error) {
	mu.RLock()
	r := reader
	mu.RUnlock()
	if r == nil {
		return 0, true, nil
	}
	caps, err = r()
	if err != nil {
		return 0, true, err
	}
	return caps, fullWakeFrom(caps), nil
}

// Probe is Read without the error: the shape of the daemon's and the
// automations' full-wake probes, whose dark/full transition log lines carry
// caps (as 0x%02x).
func Probe() (caps uint32, full bool) {
	caps, full, _ = Read()
	return caps, full
}

// FullWake reports whether the Mac is fully awake. It is false only when the
// installed reader reports a dark wake; every other case is true (fail open).
func FullWake() bool {
	_, full := Probe()
	return full
}

// fullWakeFrom decides from capability bits: the CPU bit without the
// graphics bit is a dark wake; anything else — full wake, or a value without
// the CPU bit that cannot describe a running process — reads as awake.
func fullWakeFrom(caps uint32) bool {
	if caps&capCPU == 0 {
		return true
	}
	return caps&capGraphics != 0
}

func setReader(r func() (uint32, error)) {
	mu.Lock()
	reader = r
	mu.Unlock()
}

// setReaderForTesting installs r (nil = no reader) and returns a restore that
// puts the previous reader back.
func setReaderForTesting(r func() (caps uint32, err error)) (restore func()) {
	mu.RLock()
	old := reader
	mu.RUnlock()
	setReader(r)
	return func() { setReader(old) }
}
