//go:build darwin && cgo

package powerstate

/*
#cgo LDFLAGS: -framework IOKit
#include <stdint.h>

// IOPMConnectionGetSystemCapabilities is exported by IOKit.framework (listed
// in the SDK's IOKit.tbd) but declared only in Apple's private
// IOPMLibPrivate.h, not in the public SDK headers, so it is declared here.
// Its result is an IOPMCapabilityBits value (uint32_t).
extern uint32_t IOPMConnectionGetSystemCapabilities(void);
*/
import "C"

// UseSystemReader makes FullWake read this Mac's power state through IOKit.
// main calls it once at startup; a test binary never does, so tests see the
// fail-open default or what SetReaderForTesting installs.
func UseSystemReader() {
	setReader(readSystem)
}

// readSystem returns the current system capabilities. A value without the
// CPU bit (0 included) is an error, so FullWake fails open on it.
func readSystem() (uint32, error) {
	caps := uint32(C.IOPMConnectionGetSystemCapabilities())
	if caps&capCPU == 0 {
		return caps, errNoCPU
	}
	return caps, nil
}
