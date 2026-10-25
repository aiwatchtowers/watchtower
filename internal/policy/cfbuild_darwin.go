//go:build darwin && cgo

package policy

// Test support for reader_darwin_test.go: cgo is not allowed in _test.go
// files, so the CF value builders the tests need live here. Nothing outside
// the tests calls them.

/*
#include <CoreFoundation/CoreFoundation.h>

static CFTypeRef wtNewBool(Boolean b) { return CFRetain(b ? kCFBooleanTrue : kCFBooleanFalse); }
static CFTypeRef wtNewInt64(int64_t i) { return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &i); }
static CFTypeRef wtNewFloat64(double f) { return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &f); }
static CFTypeRef wtNewData(const UInt8 *b, CFIndex n) { return CFDataCreate(kCFAllocatorDefault, b, n); }
static CFMutableArrayRef wtNewArray(void) { return CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks); }
static void wtArrayAppend(CFMutableArrayRef a, CFTypeRef v) { CFArrayAppendValue(a, v); }
static CFMutableDictionaryRef wtNewDict(void) {
	return CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
static void wtDictSet(CFMutableDictionaryRef d, CFStringRef k, CFTypeRef v) { CFDictionarySetValue(d, k, v); }
static void wtRelease(CFTypeRef v) { CFRelease(v); }
static void wtTReleaseString(CFStringRef s) { CFRelease(s); }
static void wtTSetValue(CFStringRef key, CFTypeRef value, CFStringRef domain) {
	CFPreferencesSetAppValue(key, value, domain);
}
static CFTypeRef wtTCopyValue(CFStringRef key, CFStringRef domain) {
	return CFPreferencesCopyAppValue(key, domain);
}
static CFTypeRef wtStringAsType(CFStringRef s) { return (CFTypeRef)s; }
static CFTypeRef wtArrayAsType(CFMutableArrayRef a) { return (CFTypeRef)a; }
static CFTypeRef wtDictAsType(CFMutableDictionaryRef d) { return (CFTypeRef)d; }
*/
import "C"

import "unsafe"

// toCF builds an owned CF property-list value from a Go value: bool, int64,
// float64, string, []byte (CFData), []any, map[string]any. 0 for anything
// else.
func toCF(v any) C.CFTypeRef {
	switch x := v.(type) {
	case bool:
		var b C.Boolean
		if x {
			b = 1
		}
		return C.wtNewBool(b)
	case int64:
		return C.wtNewInt64(C.int64_t(x))
	case float64:
		return C.wtNewFloat64(C.double(x))
	case string:
		return C.wtStringAsType(cfString(x))
	case []byte:
		if len(x) == 0 {
			return C.wtNewData(nil, 0)
		}
		return C.wtNewData((*C.UInt8)(unsafe.Pointer(&x[0])), C.CFIndex(len(x)))
	case []any:
		a := C.wtNewArray()
		for _, e := range x {
			if ce := toCF(e); ce != 0 {
				C.wtArrayAppend(a, ce)
				C.wtRelease(ce)
			}
		}
		return C.wtArrayAsType(a)
	case map[string]any:
		d := C.wtNewDict()
		for k, e := range x {
			ck, ce := cfString(k), toCF(e)
			if ck != 0 && ce != 0 {
				C.wtDictSet(d, ck, ce)
			}
			if ck != 0 {
				C.wtTReleaseString(ck)
			}
			if ce != 0 {
				C.wtRelease(ce)
			}
		}
		return C.wtDictAsType(d)
	}
	return 0
}

// roundTripCF converts v to CF and back through fromCF.
func roundTripCF(v any) any {
	cv := toCF(v)
	if cv == 0 {
		return nil
	}
	defer C.wtRelease(cv)
	return fromCF(cv)
}

// setAppValue writes (v != nil) or removes (v == nil) a user, not forced,
// value of key in domain and synchronizes, as `defaults write` would.
func setAppValue(domain, key string, v any) {
	cdomain, ckey := cfString(domain), cfString(key)
	defer C.wtTReleaseString(cdomain)
	defer C.wtTReleaseString(ckey)
	var cv C.CFTypeRef
	if v != nil {
		cv = toCF(v)
		defer C.wtRelease(cv)
	}
	C.wtTSetValue(ckey, cv, cdomain)
	C.CFPreferencesAppSynchronize(cdomain)
}

// copyAppValue reads key from domain, forced or not.
func copyAppValue(domain, key string) any {
	cdomain, ckey := cfString(domain), cfString(key)
	defer C.wtTReleaseString(cdomain)
	defer C.wtTReleaseString(ckey)
	C.CFPreferencesAppSynchronize(cdomain)
	v := C.wtTCopyValue(ckey, cdomain)
	if v == 0 {
		return nil
	}
	defer C.wtRelease(v)
	return fromCF(v)
}
