//go:build darwin && cgo

package powerstate

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPM.h>

// wtSystemCapabilities reads IOPMrootDomain's "System Capabilities" registry
// property. It returns 0 when it is not 1: the service or the property is
// missing, or the value is not a 32-bit number. Every IOKit and CF object it
// obtains is released.
static int wtSystemCapabilities(uint32_t *out) {
	io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
	if (root == IO_OBJECT_NULL) {
		return 0;
	}
	CFTypeRef v = IORegistryEntryCreateCFProperty(root, CFSTR("System Capabilities"), kCFAllocatorDefault, 0);
	IOObjectRelease(root);
	if (v == NULL) {
		return 0;
	}
	int ok = 0;
	if (CFGetTypeID(v) == CFNumberGetTypeID()) {
		int64_t n = 0;
		if (CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &n) && n >= 0 && n <= UINT32_MAX) {
			*out = (uint32_t)n;
			ok = 1;
		}
	}
	CFRelease(v);
	return ok;
}
*/
import "C"

import "errors"

// The Go constants fullWakeFrom uses must equal the IOPM.h header constants:
// each array type below has a negative length (a compile error) if they
// differ in either direction.
var (
	_ [capCPU - uint32(C.kIOPMSystemCapabilityCPU)]struct{}
	_ [uint32(C.kIOPMSystemCapabilityCPU) - capCPU]struct{}
	_ [capGraphics - uint32(C.kIOPMSystemCapabilityGraphics)]struct{}
	_ [uint32(C.kIOPMSystemCapabilityGraphics) - capGraphics]struct{}
)

var errUnreadable = errors.New("powerstate: IOPMrootDomain System Capabilities unreadable")

// UseSystemReader makes FullWake read this Mac's power state from the
// IORegistry. main calls it once at startup; a test binary never does, so
// tests see the fail-open default or what setReaderForTesting installs.
func UseSystemReader() {
	setReader(readSystem)
}

// readSystem returns the current system capabilities. An unreadable
// property, or a value without the CPU bit (0 included), is an error, so
// FullWake fails open on it.
func readSystem() (uint32, error) {
	var caps C.uint32_t
	if C.wtSystemCapabilities(&caps) == 0 {
		return 0, errUnreadable
	}
	if uint32(caps)&capCPU == 0 {
		return uint32(caps), errNoCPU
	}
	return uint32(caps), nil
}
