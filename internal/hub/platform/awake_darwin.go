package platform

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <stdlib.h>

// wt_hold takes a "prevent idle system sleep" assertion named reason; the
// IOReturn, with the assertion's id in *id on success.
static int wt_hold(const char *reason, unsigned int *id) {
	CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, reason, kCFStringEncodingUTF8);
	if (name == NULL) return -1;
	IOPMAssertionID aid = 0;
	IOReturn r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertionLevelOn, name, &aid);
	CFRelease(name);
	*id = aid;
	return r;
}

static void wt_release(unsigned int id) { IOPMAssertionRelease(id); }
*/
import "C"

import (
	"errors"
	"fmt"
	"sync"
	"unsafe"
)

// ErrAwakeRefused is a keep-awake assertion the system refused.
var ErrAwakeRefused = errors.New("platform: keep-awake assertion refused")

// NewAwake on darwin takes IOPMAssertionCreateWithName assertions of kind
// PreventUserIdleSystemSleep (MacAwakeAssertion's IOKitPower).
func NewAwake() Awake { return darwinAwake{} }

type darwinAwake struct{}

func (darwinAwake) Hold(reason string) (func(), error) {
	cs := C.CString(reason)
	defer C.free(unsafe.Pointer(cs))
	var id C.uint
	if r := C.wt_hold(cs, &id); r != 0 {
		return nil, fmt.Errorf("%w: IOReturn %d", ErrAwakeRefused, int(r))
	}
	var once sync.Once
	return func() { once.Do(func() { C.wt_release(id) }) }, nil
}
