//go:build darwin

package main

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Every query and attribute set below carries kSecUseDataProtectionKeychain =
// true. There is no code path that talks to the file (login) keychain.

static CFMutableDictionaryRef newDict(void) {
	return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
		&kCFTypeDictionaryValueCallBacks);
}

static CFDataRef dataFromCString(const char *s) {
	return CFDataCreate(NULL, (const UInt8 *)s, (CFIndex)strlen(s));
}

static CFStringRef stringFromCString(const char *s) {
	return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

static OSStatus statusFromError(CFErrorRef e) {
	if (e == NULL) {
		return errSecInternalComponent;
	}
	OSStatus s = (OSStatus)CFErrorGetCode(e);
	CFRelease(e);
	return s;
}

static OSStatus copyBytes(CFDataRef d, uint8_t **out, size_t *outLen) {
	CFIndex n = CFDataGetLength(d);
	*out = (uint8_t *)malloc((size_t)n);
	if (*out == NULL) {
		return errSecAllocate;
	}
	memcpy(*out, CFDataGetBytePtr(d), (size_t)n);
	*outLen = (size_t)n;
	return errSecSuccess;
}

static void setKeyQuery(CFMutableDictionaryRef q, CFDataRef tag) {
	CFDictionarySetValue(q, kSecClass, kSecClassKey);
	CFDictionarySetValue(q, kSecAttrApplicationTag, tag);
	CFDictionarySetValue(q, kSecUseDataProtectionKeychain, kCFBooleanTrue);
}

static void setPasswordQuery(CFMutableDictionaryRef q, CFStringRef service, CFStringRef account) {
	CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
	CFDictionarySetValue(q, kSecAttrService, service);
	if (account != NULL) {
		CFDictionarySetValue(q, kSecAttrAccount, account);
	}
	CFDictionarySetValue(q, kSecUseDataProtectionKeychain, kCFBooleanTrue);
}

// probe_copy_se_key: SecItemCopyMatching for the SE private key ref.
static OSStatus probe_copy_se_key(const char *tag, uintptr_t *out) {
	*out = 0;
	CFDataRef t = dataFromCString(tag);
	CFMutableDictionaryRef q = newDict();
	setKeyQuery(q, t);
	CFDictionarySetValue(q, kSecAttrKeyType, kSecAttrKeyTypeECSECPrimeRandom);
	CFDictionarySetValue(q, kSecAttrKeyClass, kSecAttrKeyClassPrivate);
	CFDictionarySetValue(q, kSecReturnRef, kCFBooleanTrue);
	CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
	CFTypeRef r = NULL;
	OSStatus s = SecItemCopyMatching(q, &r);
	CFRelease(q);
	CFRelease(t);
	if (s == errSecSuccess) {
		*out = (uintptr_t)r;
	}
	return s;
}

// probe_se_create: a permanent P-256 Secure Enclave key,
// AfterFirstUnlockThisDeviceOnly + privateKeyUsage (no user presence).
static OSStatus probe_se_create(const char *tag) {
	CFErrorRef e = NULL;
	SecAccessControlRef ac = SecAccessControlCreateWithFlags(NULL,
		kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
		kSecAccessControlPrivateKeyUsage, &e);
	if (ac == NULL) {
		return statusFromError(e);
	}
	CFDataRef t = dataFromCString(tag);
	int bits = 256;
	CFNumberRef size = CFNumberCreate(NULL, kCFNumberIntType, &bits);

	CFMutableDictionaryRef priv = newDict();
	CFDictionarySetValue(priv, kSecAttrIsPermanent, kCFBooleanTrue);
	CFDictionarySetValue(priv, kSecAttrApplicationTag, t);
	CFDictionarySetValue(priv, kSecAttrAccessControl, ac);

	CFMutableDictionaryRef attrs = newDict();
	CFDictionarySetValue(attrs, kSecAttrKeyType, kSecAttrKeyTypeECSECPrimeRandom);
	CFDictionarySetValue(attrs, kSecAttrKeySizeInBits, size);
	CFDictionarySetValue(attrs, kSecAttrTokenID, kSecAttrTokenIDSecureEnclave);
	CFDictionarySetValue(attrs, kSecPrivateKeyAttrs, priv);
	CFDictionarySetValue(attrs, kSecUseDataProtectionKeychain, kCFBooleanTrue);

	SecKeyRef k = SecKeyCreateRandomKey(attrs, &e);
	CFRelease(attrs);
	CFRelease(priv);
	CFRelease(size);
	CFRelease(t);
	CFRelease(ac);
	if (k == NULL) {
		return statusFromError(e);
	}
	CFRelease(k);
	return errSecSuccess;
}

static OSStatus probe_random(uint8_t *buf, size_t n) {
	return (OSStatus)SecRandomCopyBytes(kSecRandomDefault, n, buf);
}

static OSStatus probe_encrypt(uintptr_t privRef, const uint8_t *buf, size_t n,
	uint8_t **out, size_t *outLen) {
	SecKeyRef pub = SecKeyCopyPublicKey((SecKeyRef)privRef);
	if (pub == NULL) {
		return errSecInternalComponent;
	}
	CFDataRef plain = CFDataCreate(NULL, buf, (CFIndex)n);
	CFErrorRef e = NULL;
	CFDataRef ct = SecKeyCreateEncryptedData(pub,
		kSecKeyAlgorithmECIESEncryptionCofactorVariableIVX963SHA256AESGCM, plain, &e);
	CFRelease(plain);
	CFRelease(pub);
	if (ct == NULL) {
		return statusFromError(e);
	}
	OSStatus s = copyBytes(ct, out, outLen);
	CFRelease(ct);
	return s;
}

static OSStatus probe_decrypt(uintptr_t privRef, const uint8_t *buf, size_t n,
	uint8_t **out, size_t *outLen) {
	CFDataRef ct = CFDataCreate(NULL, buf, (CFIndex)n);
	CFErrorRef e = NULL;
	CFDataRef plain = SecKeyCreateDecryptedData((SecKeyRef)privRef,
		kSecKeyAlgorithmECIESEncryptionCofactorVariableIVX963SHA256AESGCM, ct, &e);
	CFRelease(ct);
	if (plain == NULL) {
		return statusFromError(e);
	}
	OSStatus s = copyBytes(plain, out, outLen);
	CFRelease(plain);
	return s;
}

// probe_add_wrapped: generic password, AfterFirstUnlockThisDeviceOnly,
// never synchronizable.
static OSStatus probe_add_wrapped(const char *service, const char *account,
	const uint8_t *buf, size_t n) {
	CFStringRef sv = stringFromCString(service);
	CFStringRef ac = stringFromCString(account);
	CFDataRef v = CFDataCreate(NULL, buf, (CFIndex)n);
	CFMutableDictionaryRef q = newDict();
	setPasswordQuery(q, sv, ac);
	CFDictionarySetValue(q, kSecValueData, v);
	CFDictionarySetValue(q, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
	CFDictionarySetValue(q, kSecAttrSynchronizable, kCFBooleanFalse);
	OSStatus s = SecItemAdd(q, NULL);
	CFRelease(q);
	CFRelease(v);
	CFRelease(ac);
	CFRelease(sv);
	return s;
}

static OSStatus probe_copy_wrapped(const char *service, const char *account,
	uint8_t **out, size_t *outLen) {
	CFStringRef sv = stringFromCString(service);
	CFStringRef ac = stringFromCString(account);
	CFMutableDictionaryRef q = newDict();
	setPasswordQuery(q, sv, ac);
	CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
	CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
	CFTypeRef r = NULL;
	OSStatus s = SecItemCopyMatching(q, &r);
	CFRelease(q);
	CFRelease(ac);
	CFRelease(sv);
	if (s != errSecSuccess) {
		return s;
	}
	s = copyBytes((CFDataRef)r, out, outLen);
	CFRelease(r);
	return s;
}

static OSStatus probe_delete_wrapped(const char *service) {
	CFStringRef sv = stringFromCString(service);
	CFMutableDictionaryRef q = newDict();
	setPasswordQuery(q, sv, NULL);
	OSStatus s = SecItemDelete(q);
	CFRelease(q);
	CFRelease(sv);
	return s;
}

static OSStatus probe_delete_se_key(const char *tag) {
	CFDataRef t = dataFromCString(tag);
	CFMutableDictionaryRef q = newDict();
	setKeyQuery(q, t);
	OSStatus s = SecItemDelete(q);
	CFRelease(q);
	CFRelease(t);
	return s;
}

static void probe_release(uintptr_t ref) {
	if (ref != 0) {
		CFRelease((CFTypeRef)ref);
	}
}

// probe_message: SecCopyErrorMessageString as a malloc'd UTF-8 string.
static char *probe_message(OSStatus s) {
	CFStringRef m = SecCopyErrorMessageString(s, NULL);
	if (m == NULL) {
		return NULL;
	}
	CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(m), kCFStringEncodingUTF8) + 1;
	char *buf = (char *)malloc((size_t)max);
	if (buf != NULL && !CFStringGetCString(m, buf, max, kCFStringEncodingUTF8)) {
		free(buf);
		buf = NULL;
	}
	CFRelease(m);
	return buf;
}
*/
import "C"

import (
	"unsafe"
)

// The probe's own item names: it never touches the real hub or db keys.
const (
	probeService = "com.watchtower.dbkey.probe"
	probeAccount = "probe"
	probeSETag   = "com.watchtower.dbkey.se.probe"
)

const (
	errSecSuccess        = 0
	errSecItemNotFound   = -25300
	errSecDuplicateItem  = -25299
	errSecInternalComp   = -26276
	errSecMissingEntitle = -34018
)

func osMessage(s int) string {
	m := C.probe_message(C.OSStatus(s))
	if m == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(m))
	return C.GoString(m)
}

func goBytes(p *C.uint8_t, n C.size_t) []byte {
	if p == nil {
		return nil
	}
	defer C.free(unsafe.Pointer(p))
	return C.GoBytes(unsafe.Pointer(p), C.int(n))
}

func withCString(s string, fn func(*C.char) C.OSStatus) int {
	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	return int(fn(cs))
}

func copySEKey() (uintptr, int) {
	var ref C.uintptr_t
	s := withCString(probeSETag, func(t *C.char) C.OSStatus { return C.probe_copy_se_key(t, &ref) })
	return uintptr(ref), s
}

func seCreate() int {
	return withCString(probeSETag, func(t *C.char) C.OSStatus { return C.probe_se_create(t) })
}

func randomBytes(n int) ([]byte, int) {
	buf := make([]byte, n)
	s := int(C.probe_random((*C.uint8_t)(unsafe.Pointer(&buf[0])), C.size_t(n)))
	return buf, s
}

func encrypt(key uintptr, plain []byte) ([]byte, int) {
	var out *C.uint8_t
	var n C.size_t
	s := int(C.probe_encrypt(C.uintptr_t(key), (*C.uint8_t)(unsafe.Pointer(&plain[0])), C.size_t(len(plain)), &out, &n))
	return goBytes(out, n), s
}

func decrypt(key uintptr, ct []byte) ([]byte, int) {
	if len(ct) == 0 {
		return nil, errSecInternalComp
	}
	var out *C.uint8_t
	var n C.size_t
	s := int(C.probe_decrypt(C.uintptr_t(key), (*C.uint8_t)(unsafe.Pointer(&ct[0])), C.size_t(len(ct)), &out, &n))
	return goBytes(out, n), s
}

func addWrapped(value []byte) int {
	sv := C.CString(probeService)
	ac := C.CString(probeAccount)
	defer C.free(unsafe.Pointer(sv))
	defer C.free(unsafe.Pointer(ac))
	return int(C.probe_add_wrapped(sv, ac, (*C.uint8_t)(unsafe.Pointer(&value[0])), C.size_t(len(value))))
}

func copyWrapped() ([]byte, int) {
	sv := C.CString(probeService)
	ac := C.CString(probeAccount)
	defer C.free(unsafe.Pointer(sv))
	defer C.free(unsafe.Pointer(ac))
	var out *C.uint8_t
	var n C.size_t
	s := int(C.probe_copy_wrapped(sv, ac, &out, &n))
	return goBytes(out, n), s
}

func deleteWrapped() int {
	return withCString(probeService, func(s *C.char) C.OSStatus { return C.probe_delete_wrapped(s) })
}

func deleteSEKey() int {
	return withCString(probeSETag, func(t *C.char) C.OSStatus { return C.probe_delete_se_key(t) })
}

func release(ref uintptr) { C.probe_release(C.uintptr_t(ref)) }
