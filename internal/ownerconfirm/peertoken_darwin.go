//go:build darwin && cgo

package ownerconfirm

/*
#cgo LDFLAGS: -framework CoreFoundation -framework Security
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <bsm/libbsm.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

// wtReadToken copies the audit token of the process at the other end of fd
// now (LOCAL_PEERTOKEN) into out (32 bytes).
static int wtReadToken(int fd, void *out) {
	audit_token_t tok;
	socklen_t len = sizeof(tok);
	if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &tok, &len) != 0 || len != sizeof(tok)) {
		return 1;
	}
	memcpy(out, &tok, sizeof(tok));
	return 0;
}

// wtTokenCode is the running code the token names: its pid and pidversion,
// so a process that exec'd since the token was read matches no code. 2 =
// no such code.
static int wtTokenCode(const void *token, SecCodeRef *out, int32_t *status) {
	CFDataRef data = CFDataCreate(NULL, (const UInt8 *)token, sizeof(audit_token_t));
	if (data == NULL) {
		return 2;
	}
	const void *keys[] = { kSecGuestAttributeAudit };
	const void *vals[] = { data };
	CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 1,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFRelease(data);
	if (attrs == NULL) {
		return 2;
	}
	OSStatus st = SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, out);
	CFRelease(attrs);
	*status = st;
	return st == errSecSuccess ? 0 : 2;
}

// wtCheckToken validates the token's code against the requirement text req.
// 3 = a bad requirement, 4 = not satisfied.
static int wtCheckToken(const void *token, const char *req, int32_t *status) {
	SecCodeRef code = NULL;
	int r = wtTokenCode(token, &code, status);
	if (r != 0) {
		return r;
	}
	CFStringRef s = CFStringCreateWithCString(NULL, req, kCFStringEncodingUTF8);
	SecRequirementRef rq = NULL;
	OSStatus st = SecRequirementCreateWithString(s, kSecCSDefaultFlags, &rq);
	CFRelease(s);
	if (st != errSecSuccess) {
		CFRelease(code);
		*status = st;
		return 3;
	}
	st = SecCodeCheckValidity(code, kSecCSDefaultFlags, rq);
	CFRelease(rq);
	CFRelease(code);
	*status = st;
	return st == errSecSuccess ? 0 : 4;
}

// wtTokenPath writes the path of the token's (validly signed) code into buf.
// 5 = no path.
static int wtTokenPath(const void *token, char *buf, int max, int32_t *status) {
	SecCodeRef code = NULL;
	int r = wtTokenCode(token, &code, status);
	if (r != 0) {
		return r;
	}
	OSStatus st = SecCodeCheckValidity(code, kSecCSDefaultFlags, NULL);
	if (st != errSecSuccess) {
		CFRelease(code);
		*status = st;
		return 4;
	}
	CFURLRef url = NULL;
	st = SecCodeCopyPath((SecStaticCodeRef)code, kSecCSDefaultFlags, &url);
	CFRelease(code);
	if (st != errSecSuccess || url == NULL) {
		*status = st;
		return 5;
	}
	Boolean ok = CFURLGetFileSystemRepresentation(url, true, (UInt8 *)buf, max);
	CFRelease(url);
	return ok ? 0 : 5;
}
*/
import "C"

import (
	"errors"
	"fmt"
	"net"
	"unsafe"
)

// tokenStep names the C helpers' failures.
var tokenStep = map[C.int]string{
	1: "the peer's audit token is unreadable",
	2: "no running code matches the peer's audit token",
	3: "the requirement does not parse",
	4: "the peer does not satisfy the requirement",
	5: "the peer's executable path is unknown",
}

// ReadPeerToken is the audit token of the process at the other end of the
// unix connection c, read now.
func ReadPeerToken(c net.Conn) (PeerToken, error) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return PeerToken{}, errors.New("not a unix socket")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return PeerToken{}, fmt.Errorf("the socket: %w", err)
	}
	var t PeerToken
	var r C.int
	if err := raw.Control(func(fd uintptr) { r = C.wtReadToken(C.int(fd), unsafe.Pointer(&t[0])) }); err != nil {
		return PeerToken{}, fmt.Errorf("the socket: %w", err)
	}
	if r != 0 {
		return PeerToken{}, errors.New(tokenStep[r])
	}
	return t, nil
}

// checkToken validates the code t names against the requirement text req.
func checkToken(t PeerToken, req string) error {
	creq := C.CString(req)
	defer C.free(unsafe.Pointer(creq))
	var status C.int32_t
	if r := C.wtCheckToken(unsafe.Pointer(&t[0]), creq, &status); r != 0 {
		return fmt.Errorf("%s (OSStatus %d)", tokenStep[r], int32(status))
	}
	return nil
}

// tokenPath is the executable path of the (validly signed) code t names.
func tokenPath(t PeerToken) (string, error) {
	buf := make([]byte, 4096)
	var status C.int32_t
	if r := C.wtTokenPath(unsafe.Pointer(&t[0]), (*C.char)(unsafe.Pointer(&buf[0])), C.int(len(buf)), &status); r != 0 {
		return "", fmt.Errorf("%s (OSStatus %d)", tokenStep[r], int32(status))
	}
	return C.GoString((*C.char)(unsafe.Pointer(&buf[0]))), nil
}
