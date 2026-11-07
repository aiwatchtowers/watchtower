//go:build darwin && cgo

package powerstate

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPM.h>

// wtSystemCapabilities reads IOPMrootDomain's "System Capabilities" registry
// property into *out and returns WT_CAPS_OK, or the reason it could not:
// WT_CAPS_NO_SERVICE, WT_CAPS_NO_PROPERTY or WT_CAPS_NOT_NUMBER (the value is
// not a number in the 32-bit unsigned range). Every IOKit and CF object it
// obtains is released.
enum {
	WT_CAPS_OK = 0,
	WT_CAPS_NO_SERVICE = 1,
	WT_CAPS_NO_PROPERTY = 2,
	WT_CAPS_NOT_NUMBER = 3,
};

static int wtSystemCapabilities(uint32_t *out) {
	io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
	if (root == IO_OBJECT_NULL) {
		return WT_CAPS_NO_SERVICE;
	}
	CFTypeRef v = IORegistryEntryCreateCFProperty(root, CFSTR("System Capabilities"), kCFAllocatorDefault, 0);
	IOObjectRelease(root);
	if (v == NULL) {
		return WT_CAPS_NO_PROPERTY;
	}
	int rc = WT_CAPS_NOT_NUMBER;
	if (CFGetTypeID(v) == CFNumberGetTypeID()) {
		int64_t n = 0;
		if (CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &n) && n >= 0 && n <= UINT32_MAX) {
			*out = (uint32_t)n;
			rc = WT_CAPS_OK;
		}
	}
	CFRelease(v);
	return rc;
}
*/
import "C"

import (
	"errors"
	"fmt"
)

// The reasons a read of the System Capabilities property fails; each is the
// whole text of the error, so Read's one log line names it.
var (
	errNoService  = errors.New("no IOPMrootDomain service")
	errNoProperty = errors.New("no System Capabilities property")
	errNotNumber  = errors.New("not a 32-bit number")
)

// The Go constants fullWakeFrom uses must equal the IOPM.h header constants:
// each array type below has a negative length (a compile error) if they
// differ in either direction.
var (
	_ [capCPU - uint32(C.kIOPMSystemCapabilityCPU)]struct{}
	_ [uint32(C.kIOPMSystemCapabilityCPU) - capCPU]struct{}
	_ [capGraphics - uint32(C.kIOPMSystemCapabilityGraphics)]struct{}
	_ [uint32(C.kIOPMSystemCapabilityGraphics) - capGraphics]struct{}
)

// UseSystemReader makes FullWake read this Mac's power state from the
// IORegistry. main calls it once at startup; a test binary never does, so
// tests see the fail-open default or what setReaderForTesting installs.
func UseSystemReader() {
	setReader(readSystem)
}

// readSystem returns the current system capabilities. An unreadable
// property is an error naming the reason (readError), so Read fails open on
// it and logs it once; a value without the CPU bit (0 included) is left to
// fullWakeFrom, which reads it as awake.
func readSystem() (uint32, error) {
	var caps C.uint32_t
	if rc := C.wtSystemCapabilities(&caps); rc != C.WT_CAPS_OK {
		return 0, readError(int(rc))
	}
	return uint32(caps), nil
}

// wtSystemCapabilities' failure codes, for readError.
const (
	codeNoService  = int(C.WT_CAPS_NO_SERVICE)
	codeNoProperty = int(C.WT_CAPS_NO_PROPERTY)
	codeNotNumber  = int(C.WT_CAPS_NOT_NUMBER)
)

// readError maps a wtSystemCapabilities failure code to its error.
func readError(rc int) error {
	switch rc {
	case codeNoService:
		return errNoService
	case codeNoProperty:
		return errNoProperty
	case codeNotNumber:
		return errNotNumber
	}
	return fmt.Errorf("unknown read failure %d", rc)
}
