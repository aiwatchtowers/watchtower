//go:build darwin

package identity

/*
#cgo CFLAGS: -Wno-deprecated-declarations
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <stdlib.h>
#include <Security/Security.h>

// One generic-password item per (service, account). Every query refuses
// user interaction (kSecUseAuthenticationUIFail): the daemon must never
// block on a Keychain prompt, it gets errSecInteractionNotAllowed or
// errSecAuthFailed instead.
static CFMutableDictionaryRef wt_kc_query(const char *svc, const char *acct) {
	CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFStringRef s = CFStringCreateWithCString(NULL, svc, kCFStringEncodingUTF8);
	CFStringRef a = CFStringCreateWithCString(NULL, acct, kCFStringEncodingUTF8);
	CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
	CFDictionarySetValue(q, kSecAttrService, s);
	CFDictionarySetValue(q, kSecAttrAccount, a);
	CFDictionarySetValue(q, kSecAttrSynchronizable, kCFBooleanFalse);
	CFDictionarySetValue(q, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
	CFRelease(s);
	CFRelease(a);
	return q;
}

// wt_kc_put adds the item, or replaces its data when it exists.
static OSStatus wt_kc_put(const char *svc, const char *acct, const void *data, int n) {
	CFDataRef d = CFDataCreate(NULL, data, n);
	CFMutableDictionaryRef q = wt_kc_query(svc, acct);
	CFDictionarySetValue(q, kSecValueData, d);
	CFDictionarySetValue(q, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
	OSStatus st = SecItemAdd(q, NULL);
	CFRelease(q);
	if (st == errSecDuplicateItem) {
		CFMutableDictionaryRef m = wt_kc_query(svc, acct);
		CFMutableDictionaryRef u = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CFDictionarySetValue(u, kSecValueData, d);
		CFDictionarySetValue(u, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
		st = SecItemUpdate(m, u);
		CFRelease(u);
		CFRelease(m);
	}
	CFRelease(d);
	return st;
}

// wt_kc_get copies the item's data into buf (cap bytes); *n is its length.
// The CFData copy is overwritten before release.
static OSStatus wt_kc_get(const char *svc, const char *acct, void *buf, int cap, int *n) {
	CFMutableDictionaryRef q = wt_kc_query(svc, acct);
	CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
	CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
	CFTypeRef out = NULL;
	OSStatus st = SecItemCopyMatching(q, &out);
	CFRelease(q);
	*n = 0;
	if (st != errSecSuccess) {
		return st;
	}
	if (out == NULL || CFGetTypeID(out) != CFDataGetTypeID()) {
		if (out != NULL) CFRelease(out);
		return errSecDecode;
	}
	CFIndex len = CFDataGetLength((CFDataRef)out);
	if (len <= cap) {
		CFDataGetBytes((CFDataRef)out, CFRangeMake(0, len), buf);
	}
	*n = (int)len;
	CFRelease(out);
	return st;
}

static OSStatus wt_kc_delete(const char *svc, const char *acct) {
	CFMutableDictionaryRef q = wt_kc_query(svc, acct);
	OSStatus st = SecItemDelete(q);
	CFRelease(q);
	return st;
}

// wt_kc_accessible reports the item's kSecAttrAccessible: 1 =
// AfterFirstUnlockThisDeviceOnly, 0 = another class, -1 = not reported
// (the file-based login keychain keeps no such attribute).
static OSStatus wt_kc_accessible(const char *svc, const char *acct, int *res) {
	CFMutableDictionaryRef q = wt_kc_query(svc, acct);
	CFDictionarySetValue(q, kSecReturnAttributes, kCFBooleanTrue);
	CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
	CFTypeRef out = NULL;
	OSStatus st = SecItemCopyMatching(q, &out);
	CFRelease(q);
	*res = -1;
	if (st == errSecSuccess && out != NULL && CFGetTypeID(out) == CFDictionaryGetTypeID()) {
		CFTypeRef v = CFDictionaryGetValue((CFDictionaryRef)out, kSecAttrAccessible);
		if (v != NULL) {
			*res = CFEqual(v, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) ? 1 : 0;
		}
	}
	if (out != NULL) CFRelease(out);
	return st;
}
*/
import "C"

import (
	"errors"
	"unsafe"
)

const keychainAvailable = true

const (
	errSecSuccess      = 0
	errSecItemNotFound = -25300
)

// keychainCall runs one call with C copies of the service and account.
func keychainCall(service, account string, fn func(svc, acct *C.char) C.OSStatus) int32 {
	svc, acct := C.CString(service), C.CString(account)
	defer C.free(unsafe.Pointer(svc))
	defer C.free(unsafe.Pointer(acct))
	return int32(fn(svc, acct))
}

// keychainPut adds the item or replaces its data.
func keychainPut(service, account string, data []byte) error {
	if len(data) == 0 {
		return errors.New("identity: refusing to store an empty key")
	}
	st := keychainCall(service, account, func(svc, acct *C.char) C.OSStatus {
		return C.wt_kc_put(svc, acct, unsafe.Pointer(&data[0]), C.int(len(data)))
	})
	if st != errSecSuccess {
		return &KeychainError{Op: "save", Status: st}
	}
	return nil
}

// keychainGet reads exactly len(buf) bytes of the item into buf; found is
// false when the item does not exist. A different length is malformed.
func keychainGet(service, account string, buf []byte) (found bool, err error) {
	var n C.int
	st := keychainCall(service, account, func(svc, acct *C.char) C.OSStatus {
		return C.wt_kc_get(svc, acct, unsafe.Pointer(&buf[0]), C.int(len(buf)), &n)
	})
	switch {
	case st == errSecItemNotFound:
		return false, nil
	case st != errSecSuccess:
		return false, &KeychainError{Op: "load", Status: st}
	case int(n) != len(buf):
		clear(buf)
		return false, errMalformedKeychain
	}
	return true, nil
}

// keychainDelete removes the item; a missing item is not an error.
func keychainDelete(service, account string) error {
	st := keychainCall(service, account, func(svc, acct *C.char) C.OSStatus {
		return C.wt_kc_delete(svc, acct)
	})
	if st != errSecSuccess && st != errSecItemNotFound {
		return &KeychainError{Op: "delete", Status: st}
	}
	return nil
}

// keychainAccessible reports the item's accessibility class (test helper):
// 1 = AfterFirstUnlockThisDeviceOnly, 0 = another class, -1 = not reported.
func keychainAccessible(service, account string) (int, error) {
	var res C.int
	st := keychainCall(service, account, func(svc, acct *C.char) C.OSStatus {
		return C.wt_kc_accessible(svc, acct, &res)
	})
	if st != errSecSuccess {
		return 0, &KeychainError{Op: "load", Status: st}
	}
	return int(res), nil
}
