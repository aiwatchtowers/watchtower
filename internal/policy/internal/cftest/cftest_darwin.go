//go:build darwin && cgo

package cftest

/*
#cgo LDFLAGS: -framework CoreFoundation
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>

static CFStringRef ctString(const char *s) {
	return CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
}
static void ctReleaseString(CFStringRef s) { CFRelease(s); }
static void ctRelease(CFTypeRef v) { CFRelease(v); }
static CFTypeRef ctBool(Boolean b) { return CFRetain(b ? kCFBooleanTrue : kCFBooleanFalse); }
static CFTypeRef ctInt64(int64_t i) { return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &i); }
static CFTypeRef ctFloat64(double f) { return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &f); }
static CFTypeRef ctData(const UInt8 *b, CFIndex n) { return CFDataCreate(kCFAllocatorDefault, b, n); }
static CFTypeRef ctStringAsType(CFStringRef s) { return (CFTypeRef)s; }
static CFMutableArrayRef ctArray(void) { return CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks); }
static void ctArrayAppend(CFMutableArrayRef a, CFTypeRef v) { CFArrayAppendValue(a, v); }
static CFTypeRef ctArrayAsType(CFMutableArrayRef a) { return (CFTypeRef)a; }
static CFMutableDictionaryRef ctDict(void) {
	return CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
static void ctDictSet(CFMutableDictionaryRef d, CFStringRef k, CFTypeRef v) { CFDictionarySetValue(d, k, v); }
static CFTypeRef ctDictAsType(CFMutableDictionaryRef d) { return (CFTypeRef)d; }
static void ctSetValue(CFStringRef key, CFTypeRef value, CFStringRef domain) {
	CFPreferencesSetAppValue(key, value, domain);
	CFPreferencesAppSynchronize(domain);
}
*/
import "C"

import "unsafe"

// SetAppValue writes (v != nil) or removes (v == nil) the user, not forced,
// value of key in domain and synchronizes, the way `defaults write` does. A
// domain that is an absolute path writes <domain>.plist, which keeps tests
// out of ~/Library/Preferences. v is bool, int64, float64, string, []byte
// (CFData), []any or map[string]any.
func SetAppValue(domain, key string, v any) {
	cdomain, ckey := cfString(domain), cfString(key)
	defer C.ctReleaseString(cdomain)
	defer C.ctReleaseString(ckey)
	var cv C.CFTypeRef
	if v != nil {
		cv = toCF(v)
		if cv != 0 {
			defer C.ctRelease(cv)
		}
	}
	C.ctSetValue(ckey, cv, cdomain)
}

func cfString(s string) C.CFStringRef {
	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	return C.ctString(cs)
}

// toCF builds an owned CF value; 0 for an unsupported Go type.
func toCF(v any) C.CFTypeRef {
	switch x := v.(type) {
	case bool:
		var b C.Boolean
		if x {
			b = 1
		}
		return C.ctBool(b)
	case int64:
		return C.ctInt64(C.int64_t(x))
	case float64:
		return C.ctFloat64(C.double(x))
	case string:
		return C.ctStringAsType(cfString(x))
	case []byte:
		if len(x) == 0 {
			return C.ctData(nil, 0)
		}
		return C.ctData((*C.UInt8)(unsafe.Pointer(&x[0])), C.CFIndex(len(x)))
	case []any:
		a := C.ctArray()
		for _, e := range x {
			if ce := toCF(e); ce != 0 {
				C.ctArrayAppend(a, ce)
				C.ctRelease(ce)
			}
		}
		return C.ctArrayAsType(a)
	case map[string]any:
		d := C.ctDict()
		for k, e := range x {
			ck, ce := cfString(k), toCF(e)
			if ck != 0 && ce != 0 {
				C.ctDictSet(d, ck, ce)
			}
			if ck != 0 {
				C.ctReleaseString(ck)
			}
			if ce != 0 {
				C.ctRelease(ce)
			}
		}
		return C.ctDictAsType(d)
	}
	return 0
}
