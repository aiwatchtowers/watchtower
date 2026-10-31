package hub

// DefaultRelayOrigin is the build-time default relay origin of a live
// headless hub, set by the release builds through ldflags
// (-X watchtower/internal/hub.DefaultRelayOrigin=…): scripts/build-linux.sh
// from the repository variable RELAY_ORIGIN, scripts/build-app.sh from the
// build profile's WATCHTOWER_RELAY_ORIGIN_DEFAULT. Dev builds leave it empty.
// WATCHTOWER_RELAY_ORIGIN and config hub.relay_origin take precedence (Go hub
// phase 2 plan, Global Constraints "Relay origin").
var DefaultRelayOrigin string
