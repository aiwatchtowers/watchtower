package hub

import (
	"errors"
	"net/url"
	"os"
	"strings"

	"watchtower/internal/config"
)

// RelayOrigin is a live hub's relay origin: WATCHTOWER_RELAY_ORIGIN when
// set, else config hub.relay_origin (`config set` overrides the build's
// default), else DefaultRelayOrigin; "" when none is set (the hub stays
// off, reason no_relay_origin). The value is not checked here
// (CheckRelayOrigin).
func RelayOrigin(cfg *config.Config) string {
	if v := os.Getenv(EnvRelayOrigin); v != "" {
		return v
	}
	if cfg != nil && cfg.Hub.RelayOrigin != "" {
		return cfg.Hub.RelayOrigin
	}
	return DefaultRelayOrigin
}

// ErrBadRelayOrigin is a relay origin that is not https://host[:port] (or
// http:// on a loopback host).
var ErrBadRelayOrigin = errors.New("the relay origin must be https://host[:port] with no path, query or fragment (http:// only for 127.0.0.1, localhost or [::1])")

// CheckRelayOrigin accepts https://host[:port] with no user, path, query or
// fragment, and http:// only for 127.0.0.1, localhost and [::1].
func CheckRelayOrigin(origin string) error {
	u, err := url.Parse(origin)
	if err != nil || u.Hostname() == "" || u.User != nil ||
		u.Path != "" || u.RawQuery != "" || u.ForceQuery || strings.Contains(origin, "#") {
		return ErrBadRelayOrigin
	}
	// url.Parse refuses a port that is not a number, but takes an empty one
	// ("https://relay.example.com:").
	if strings.HasSuffix(u.Host, ":") {
		return ErrBadRelayOrigin
	}
	switch u.Scheme {
	case "https":
		return nil
	case "http":
		if h := u.Hostname(); h == "127.0.0.1" || h == "localhost" || h == "::1" {
			return nil
		}
	}
	return ErrBadRelayOrigin
}
