package caldav

import (
	"strings"
	"testing"
)

// Basic auth carries the password on every request: a remote CalDAV server
// must be https; plain http is only for a loopback host.
func TestDialCalDAVRefusesBasicAuthOverRemoteHTTP(t *testing.T) {
	_, err := DialCalDAV("http://dav.example.com/", "u", "p")
	if err == nil || !strings.Contains(err.Error(), "must use https") {
		t.Fatalf("DialCalDAV(http remote) err = %v, want an https refusal", err)
	}
	for _, u := range []string{"https://dav.example.com/", "http://127.0.0.1:8080/", "http://localhost/dav/"} {
		if _, err := DialCalDAV(u, "u", "p"); err != nil {
			t.Errorf("DialCalDAV(%q) = %v, want nil", u, err)
		}
	}
}
