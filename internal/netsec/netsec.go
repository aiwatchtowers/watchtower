// Package netsec holds the transport rule for credentials: a secret (a
// password, a token, an auth header) never crosses the network in cleartext.
// Plain http, or IMAP without TLS, is allowed only to a loopback host — a
// server on the owner's own machine is a legitimate setup, and it is what a
// test's local server looks like.
package netsec

import (
	"fmt"
	"net"
	"net/url"
	"strings"
)

// LoopbackHosts names the hosts the rule exempts, for error messages.
const LoopbackHosts = "localhost, 127.0.0.1, ::1"

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
	if !strings.EqualFold(u.Scheme, "http") || IsLoopbackHost(u.Hostname()) {
		return nil
	}
	return fmt.Errorf("%s sends a secret, so %s must use https: plain http would carry it in cleartext "+
		"(http is allowed only for a loopback host: %s)", what, u.Redacted(), LoopbackHosts)
}
