package netsec

import (
	"errors"
	"strings"
	"testing"
)

func TestIsLoopbackHost(t *testing.T) {
	for h, want := range map[string]bool{
		"localhost": true, "LOCALHOST": true, "127.0.0.1": true, "127.1.2.3": true, "::1": true, "[::1]": true,
		"example.com": false, "10.0.0.1": false, "localhost.example.com": false, "": false, "0.0.0.0": false,
	} {
		if got := IsLoopbackHost(h); got != want {
			t.Errorf("IsLoopbackHost(%q) = %v, want %v", h, got, want)
		}
	}
}

func TestRequireSecureURL(t *testing.T) {
	allowed := []string{
		"https://mcp.example.com/mcp",
		"http://127.0.0.1:8080/mcp",
		"http://localhost/mcp",
		"http://[::1]:9000/",
		"HTTPS://mcp.example.com/",
	}
	for _, u := range allowed {
		if err := RequireSecureURL(u, "a connection with headers"); err != nil {
			t.Errorf("RequireSecureURL(%q) = %v, want nil", u, err)
		}
	}
	refused := []string{
		"http://mcp.example.com/mcp",
		"HTTP://mcp.example.com/",
		"http://10.0.0.5:8080/",
		"http://user:pw@dav.example.com/",
	}
	for _, u := range refused {
		err := RequireSecureURL(u, "a connection with headers")
		if err == nil {
			t.Errorf("RequireSecureURL(%q) = nil, want a refusal", u)
			continue
		}
		msg := err.Error()
		if !strings.Contains(msg, "must use https") || !strings.Contains(msg, "loopback") {
			t.Errorf("RequireSecureURL(%q) message %q does not say why", u, msg)
		}
		if strings.Contains(msg, ":pw@") {
			t.Errorf("RequireSecureURL(%q) message leaks the URL password: %q", u, msg)
		}
	}
}

func TestRequireTLSAndStatusMessage(t *testing.T) {
	if err := RequireTLS("127.0.0.1", "x"); err != nil {
		t.Errorf("loopback refused: %v", err)
	}
	err := RequireTLS("imap.example.com", `security "none"`)
	if !errors.Is(err, ErrCleartext) {
		t.Fatalf("RequireTLS(remote) = %v, want ErrCleartext", err)
	}
	if got := StatusMessage(err); !strings.HasPrefix(got, StatusPrefix) {
		t.Errorf("StatusMessage(cleartext) = %q, want the %q prefix", got, StatusPrefix)
	}
	if !errors.Is(RequireSecureURL("http://mcp.example.com/", "x"), ErrCleartext) {
		t.Error("RequireSecureURL's refusal does not wrap ErrCleartext")
	}
	if got := StatusMessage(errors.New("auth failed")); got != "auth failed" {
		t.Errorf("StatusMessage(other) = %q, want the bare message", got)
	}
}
