// Package netsec holds the transport rule for credentials: a secret (a
// password, a token, an auth header) never crosses the network in cleartext.
// Plain http, or IMAP without TLS, is allowed only to a loopback host — a
// server on the owner's own machine is a legitimate setup, and it is what a
// test's local server looks like.
package netsec

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
)

// LoopbackHosts names the hosts the rule exempts, for error messages.
const LoopbackHosts = "localhost, 127.0.0.1, ::1"

// ErrCleartext is what every refusal of this package wraps, so a caller can
// tell "stopped because the secret would travel in cleartext" from any
// other failure.
var ErrCleartext = errors.New("a secret would be sent unencrypted")

// StatusPrefix starts a row error (an account's or a connection's) that
// records an ErrCleartext refusal; the Desktop keys its "Stopped syncing"
// row on it (Swift `CleartextRefusal.statusPrefix`).
const StatusPrefix = "transport: "

// StatusMessage is err as a row's error text: StatusPrefix first when err is
// an ErrCleartext refusal.
func StatusMessage(err error) string {
	if errors.Is(err, ErrCleartext) {
		return StatusPrefix + err.Error()
	}
	return err.Error()
}

// allowsCleartext is the one place the exemption lives: a loopback host.
func allowsCleartext(host string) bool { return IsLoopbackHost(host) }

// IsLoopbackHost reports whether h (a hostname without port; IPv6 brackets
// allowed) names the local machine: "localhost" or a loopback IP literal.
func IsLoopbackHost(h string) bool {
	h = strings.TrimSuffix(strings.TrimPrefix(h, "["), "]")
	if strings.EqualFold(h, "localhost") {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// RequireSecureURL refuses rawURL when it is plain http to a host other than
// loopback: what (e.g. "a connection with headers") carries a secret, which
// would travel in cleartext. Any other scheme is left to the caller.
func RequireSecureURL(rawURL, what string) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("parsing URL: %w", err)
	}
	if !strings.EqualFold(u.Scheme, "http") || allowsCleartext(u.Hostname()) {
		return nil
	}
	return fmt.Errorf("%w: %s sends a secret, so %s must use https: plain http would carry it in cleartext "+
		"(http is allowed only for a loopback host: %s)", ErrCleartext, what, u.Redacted(), LoopbackHosts)
}

// RequireTLS refuses a connection to host without TLS: what (e.g. "IMAP
// security \"none\"") would send a password in cleartext.
func RequireTLS(host, what string) error {
	if allowsCleartext(host) {
		return nil
	}
	return fmt.Errorf("%w: %s would send the password to %s in cleartext; use TLS "+
		"(no TLS is allowed only for a loopback host: %s)", ErrCleartext, what, host, LoopbackHosts)
}

// SecretRedirect is an http.Client CheckRedirect for a client that sends a
// secret on every request (basic auth): a hop is refused when it would carry
// the secret in cleartext (RequireSecureURL — a downgrade to plain http) or
// to another host. Go's default 10-hop cap is kept (a CheckRedirect replaces
// it).
func SecretRedirect(what string) func(*http.Request, []*http.Request) error {
	return func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return fmt.Errorf("stopped after %d redirects", len(via))
		}
		if err := RequireSecureURL(req.URL.String(), what); err != nil {
			return fmt.Errorf("redirect refused: %w", err)
		}
		if from := via[0].URL; !strings.EqualFold(req.URL.Hostname(), from.Hostname()) {
			return fmt.Errorf("redirect refused: %s sends a secret, so it does not follow %s to another host (%s)",
				what, from.Hostname(), req.URL.Hostname())
		}
		return nil
	}
}
