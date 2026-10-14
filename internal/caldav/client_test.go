package caldav

import (
	"errors"
	"net/http"
	"strings"
	"testing"

	"watchtower/internal/netsec"
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

// A redirect never carries the basic-auth password in cleartext: a same-host
// https → http hop and a hop to another host are refused; an https hop on
// the same host (and a loopback http one) is followed.
func TestCalDAVClientRefusesInsecureRedirects(t *testing.T) {
	check := newHTTPClient().CheckRedirect
	hop := func(from, to string) error {
		prev, err := http.NewRequest(http.MethodGet, from, nil)
		if err != nil {
			t.Fatal(err)
		}
		next, err := http.NewRequest(http.MethodGet, to, nil)
		if err != nil {
			t.Fatal(err)
		}
		return check(next, []*http.Request{prev})
	}
	if err := hop("https://dav.example.com/a", "http://dav.example.com/b"); !errors.Is(err, netsec.ErrCleartext) {
		t.Errorf("https → http same host: err = %v, want a cleartext refusal", err)
	}
	if err := hop("https://dav.example.com/a", "https://evil.example.net/b"); err == nil {
		t.Error("a redirect to another host was followed")
	}
	for _, ok := range [][2]string{
		{"https://dav.example.com/a", "https://dav.example.com/b"},
		{"http://127.0.0.1:8080/a", "http://127.0.0.1:8080/b"},
	} {
		if err := hop(ok[0], ok[1]); err != nil {
			t.Errorf("%s → %s: %v", ok[0], ok[1], err)
		}
	}
}
