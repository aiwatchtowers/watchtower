//go:build darwin && cgo

package policy

/*
#cgo LDFLAGS: -framework CoreFoundation
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>

static void wtReleaseString(CFStringRef s) { CFRelease(s); }

static Boolean wtIsForced(CFStringRef key, CFStringRef domain) {
	return CFPreferencesAppValueIsForced(key, domain);
}
static CFTypeRef wtCopyValue(CFStringRef key, CFStringRef domain) {
	return CFPreferencesCopyAppValue(key, domain);
}
static CFTypeID wtTypeID(CFTypeRef v) { return CFGetTypeID(v); }
static Boolean wtBool(CFTypeRef v) { return CFBooleanGetValue((CFBooleanRef)v); }
static Boolean wtIsFloat(CFTypeRef v) { return CFNumberIsFloatType((CFNumberRef)v); }
static Boolean wtInt64(CFTypeRef v, int64_t *out) {
	return CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, out);
}
static Boolean wtFloat64(CFTypeRef v, double *out) {
	return CFNumberGetValue((CFNumberRef)v, kCFNumberFloat64Type, out);
}
static CFIndex wtStringLength(CFTypeRef v) { return CFStringGetLength((CFStringRef)v); }
static CFIndex wtStringBytes(CFTypeRef v, CFIndex n, UInt8 *buf, CFIndex max) {
	CFIndex used = 0;
	CFStringGetBytes((CFStringRef)v, CFRangeMake(0, n), kCFStringEncodingUTF8, 0, false, buf, max, &used);
	return used;
}
static CFIndex wtArrayCount(CFTypeRef v) { return CFArrayGetCount((CFArrayRef)v); }
static CFTypeRef wtArrayAt(CFTypeRef v, CFIndex i) { return CFArrayGetValueAtIndex((CFArrayRef)v, i); }
static CFIndex wtDictCount(CFTypeRef v) { return CFDictionaryGetCount((CFDictionaryRef)v); }
static void wtDictEntries(CFTypeRef v, CFTypeRef *keys, CFTypeRef *values) {
	CFDictionaryGetKeysAndValues((CFDictionaryRef)v, (const void **)keys, (const void **)values);
}
static CFStringRef wtString(const char *s) {
	return CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
}
*/
import "C"

import (
	"testing"
	"unsafe"
)

func init() {
	// A test binary never reads this Mac's managed preferences: tests set the
	// policy through SetReaderForTesting / policytest.Set.
	if testing.Testing() {
		return
	}
	reader = func() map[string]any {
		return readForced(Domain, append(append([]string{}, Keys...), ReservedKeys...))
	}
}

// unsupported stands for a value of a CF type the policy never uses (data,
// date, …); Normalize reads it as a wrong type.
type unsupported struct{}

// readForced returns the forced values of keys in domain. A value the person
// wrote with `defaults write` is not forced and is left out (POLICY-01).
func readForced(domain string, keys []string) map[string]any {
	cdomain := cfString(domain)
	if cdomain == 0 {
		return map[string]any{}
	}
	defer C.wtReleaseString(cdomain)
	C.CFPreferencesAppSynchronize(cdomain)

	out := map[string]any{}
	for _, k := range keys {
		ckey := cfString(k)
		if ckey == 0 {
			continue
		}
		if C.wtIsForced(ckey, cdomain) != 0 {
			if v := C.wtCopyValue(ckey, cdomain); v != 0 {
				out[k] = fromCF(v)
				C.CFRelease(v)
			}
		}
		C.wtReleaseString(ckey)
	}
	return out
}

// cfString creates a CFString the caller releases; 0 on failure.
func cfString(s string) C.CFStringRef {
	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	return C.wtString(cs)
}

// fromCF converts a property-list value without taking ownership of it.
// CFBoolean is checked by type id, so a boolean never reads as the number 1
// and a number never reads as a boolean.
func fromCF(v C.CFTypeRef) any {
	switch C.wtTypeID(v) {
	case C.CFBooleanGetTypeID():
		return C.wtBool(v) != 0
	case C.CFNumberGetTypeID():
		if C.wtIsFloat(v) != 0 {
			var f C.double
			if C.wtFloat64(v, &f) != 0 {
				return float64(f)
			}
			return unsupported{}
		}
		var i C.int64_t
		if C.wtInt64(v, &i) != 0 {
			return int64(i)
		}
		return unsupported{}
	case C.CFStringGetTypeID():
		return goString(v)
	case C.CFArrayGetTypeID():
		n := int(C.wtArrayCount(v))
		arr := make([]any, 0, n)
		for i := range n {
			arr = append(arr, fromCF(C.wtArrayAt(v, C.CFIndex(i))))
		}
		return arr
	case C.CFDictionaryGetTypeID():
		n := int(C.wtDictCount(v))
		m := make(map[string]any, n)
		if n == 0 {
			return m
		}
		keys := make([]C.CFTypeRef, n)
		values := make([]C.CFTypeRef, n)
		C.wtDictEntries(v, &keys[0], &values[0])
		for i := range n {
			k := keys[i]
			if C.wtTypeID(k) != C.CFStringGetTypeID() {
				continue
			}
			m[goString(k)] = fromCF(values[i])
		}
		return m
	}
	return unsupported{}
}

func goString(v C.CFTypeRef) string {
	n := C.wtStringLength(v)
	if n == 0 {
		return ""
	}
	maxBytes := C.CFStringGetMaximumSizeForEncoding(n, C.kCFStringEncodingUTF8)
	buf := make([]byte, int(maxBytes))
	used := C.wtStringBytes(v, n, (*C.UInt8)(unsafe.Pointer(&buf[0])), maxBytes)
	return string(buf[:int(used)])
}
