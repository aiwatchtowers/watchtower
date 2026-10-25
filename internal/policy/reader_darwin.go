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

import "unsafe"

// UseSystemReader makes every later policy read come from this Mac's managed
// preferences. main calls it once at startup; a test binary never does, so
// tests read the empty default or what policytest.Set gives them.
func UseSystemReader() {
	setReader(func() map[string]any {
		return readForced(Domain, allKeys(), nil)
	})
}

// allKeys is every key the reader asks for: the v1 keys, then the reserved.
func allKeys() []string {
	return append(append([]string{}, Keys...), ReservedKeys...)
}

// unsupported stands for a value the policy cannot read: a CF type it never
// uses (data, date, …), or a forced key whose value could not be copied.
// Normalize reads it as a wrong type (fail closed).
type unsupported struct{}

// readForced returns the values of keys in domain that are forced: by
// CoreFoundation over the domain string it allocates once (isForced nil,
// production), or by isForced (the positive-path test's seam). A value the
// person wrote with `defaults write` is not forced and is left out
// (POLICY-01). Anything that cannot be read — the domain or key string not
// allocated, a forced value copied as NULL — reads as unsupported{}, never as
// absent.
func readForced(domain string, keys []string, isForced func(domain, key string) bool) map[string]any {
	out := map[string]any{}
	cdomain := cfString(domain)
	if cdomain == 0 {
		for _, k := range keys {
			out[k] = unsupported{}
		}
		return out
	}
	defer C.wtReleaseString(cdomain)
	C.CFPreferencesAppSynchronize(cdomain)

	for _, k := range keys {
		var forced bool
		if isForced != nil {
			forced = isForced(domain, k)
		} else {
			forced = keyForced(cdomain, k)
		}
		if forced {
			out[k] = copyValue(cdomain, k)
		}
	}
	return out
}

// copyValue copies and converts key's value; unsupported{} when it cannot.
func copyValue(cdomain C.CFStringRef, key string) any {
	ckey := cfString(key)
	if ckey == 0 {
		return unsupported{}
	}
	defer C.wtReleaseString(ckey)
	v := C.wtCopyValue(ckey, cdomain)
	if v == 0 {
		return unsupported{}
	}
	defer C.CFRelease(v)
	return fromCF(v)
}

// keyForced asks CoreFoundation whether key is forced in cdomain. A key
// string that cannot be allocated answers true, so the key is then read and
// fails closed as unsupported{}.
func keyForced(cdomain C.CFStringRef, key string) bool {
	ckey := cfString(key)
	if ckey == 0 {
		return true
	}
	defer C.wtReleaseString(ckey)
	return C.wtIsForced(ckey, cdomain) != 0
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
