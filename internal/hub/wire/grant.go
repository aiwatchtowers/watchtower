package wire

import "encoding/json"

// Transports a hub announces in `device_grant.transports` and a link code.
const (
	TransportRelay    = "relay"
	TransportCloudKit = "cloudkit"
)

// Device scopes.
const (
	ScopePrivate = "private"
	ScopeShared  = "shared"
)

// Link refusals (`device_grant.link_refused`).
const (
	RefusedUsedCode        = "used_code"
	RefusedExpiredCode     = "expired_code"
	RefusedUnknownCode     = "unknown_code"
	RefusedNotConfirmed    = "not_confirmed"
	RefusedTooManyRequests = "too_many_requests"
)

// DeviceGrant is the hub's `device_grant` slice for one phone (spec §12a).
// A nil pointer is an absent key; unknown keys are ignored on decode.
type DeviceGrant struct {
	DeviceID             string  `json:"device_id"`
	HubID                string  `json:"hub_id"`
	Name                 string  `json:"name"`
	Scope                string  `json:"scope"`
	Linked               bool    `json:"linked"`
	LinkRefused          *string `json:"link_refused,omitempty"`
	LinkedAt             *Time   `json:"linked_at,omitempty"`
	TypingAllowed        bool    `json:"typing_allowed"`
	StartSessionsAllowed bool    `json:"start_sessions_allowed"`
	StartSessionsGranted *bool   `json:"start_sessions_granted,omitempty"`
	// PermissionsAllowed is true or absent: false is never written, so older
	// peers' bytes stay as they were.
	PermissionsAllowed   *bool    `json:"permissions_allowed,omitempty"`
	DecidedAt            *Time    `json:"decided_at,omitempty"`
	AwaitingConfirmation *bool    `json:"awaiting_confirmation,omitempty"`
	ConfirmNonce         *string  `json:"confirm_nonce,omitempty"`
	LinkCodeTag          *string  `json:"link_code_tag,omitempty"`
	Revoked              *bool    `json:"revoked,omitempty"`
	OrderedActions       *int     `json:"ordered_actions,omitempty"`
	Transports           []string `json:"transports,omitempty"`
	RelayDeviceID        string   `json:"relay_device_id,omitempty"`
	RelayAuthPub         string   `json:"relay_auth_pub,omitempty"`
}

// MarshalJSON drops a false PermissionsAllowed.
func (g DeviceGrant) MarshalJSON() ([]byte, error) {
	type plain DeviceGrant
	if g.PermissionsAllowed != nil && !*g.PermissionsAllowed {
		g.PermissionsAllowed = nil
	}
	return json.Marshal(plain(g))
}
