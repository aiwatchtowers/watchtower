package platform

/*
#cgo LDFLAGS: -framework CoreGraphics -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

// wt_bool reads a CFBoolean or CFNumber value; dflt when absent or of
// another type (Swift's `as? Bool ?? dflt` over the bridged value).
static int wt_bool(CFDictionaryRef d, CFStringRef key, int dflt) {
	CFTypeRef v = CFDictionaryGetValue(d, key);
	if (v == NULL) return dflt;
	if (CFGetTypeID(v) == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
	if (CFGetTypeID(v) == CFNumberGetTypeID()) {
		int n = 0;
		if (CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n)) return n != 0;
	}
	return dflt;
}

// wt_console reads the console session: 0 when it cannot be read.
static int wt_console(int *locked, int *onConsole) {
	CFDictionaryRef d = CGSessionCopyCurrentDictionary();
	if (d == NULL) return 0;
	*locked = wt_bool(d, CFSTR("CGSSessionScreenIsLocked"), 0);
	*onConsole = wt_bool(d, CFSTR("kCGSSessionOnConsoleKey"), 1);
	CFRelease(d);
	return 1;
}

static double wt_idle_seconds(void) {
	return CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
}

static int wt_displays_asleep(void) { return CGDisplayIsAsleep(CGMainDisplayID()) != 0; }
*/
import "C"

import (
	"log"
	"sync"
	"time"
)

// NewAway on darwin reads the console the way OwnerAwayCenter does: the
// screen lock and the console flag of CGSessionCopyCurrentDictionary, the
// seconds since any input (CGEventSourceSecondsSinceLastEventType over the
// combined session state) and the main display's sleep. None needs a
// permission.
func NewAway() Away { return darwinAway{read: readConsole} }

type darwinAway struct{ read func() consoleInputs }

func (a darwinAway) Away() (bool, error) { return awayFrom(a.read()), nil }

// noSessionOnce logs the first unreadable console session (no values).
var noSessionOnce sync.Once

func readConsole() consoleInputs {
	var locked, onConsole C.int
	if C.wt_console(&locked, &onConsole) == 0 {
		noSessionOnce.Do(func() {
			log.Printf("hub: no console session readable: the owner reads as away")
		})
		return consoleInputs{}
	}
	idle := float64(C.wt_idle_seconds())
	return consoleInputs{
		hasSession:     true,
		screenLocked:   locked != 0,
		onConsole:      onConsole != 0,
		displaysAsleep: C.wt_displays_asleep() != 0,
		idle:           time.Duration(idle * float64(time.Second)),
	}
}
