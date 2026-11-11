package wire

import "encoding/json"

// Action echo statuses (RC §5): final ones end an action, non-final ones are
// progress.
const (
	StatusPending   = "pending"
	StatusReceived  = "received"
	StatusHeld      = "held"
	StatusApplied   = "applied"
	StatusFailed    = "failed"
	StatusExpired   = "expired"
	StatusCancelled = "cancelled"
)

// Control record kinds (`c-<uuid>`).
const (
	ControlResendFrom     = "resend_from"
	ControlSkipTo         = "skip_to"
	ControlEpochAck       = "epoch_ack"
	ControlSwitch         = "transport_switch"
	ControlSwitched       = "transport_switched"
	ControlSwitchRejected = "transport_switch_rejected"
	ControlHubOnRelay     = "hub_on_relay"

	// SwitchedByEntitlement is transport_switched's by when the relay
	// entitlement lapsed rather than a phone asking.
	SwitchedByEntitlement = "entitlement_expired"
	// The transport_switch_rejected reasons: within the anti-flap window
	// (with retry_after_s); toward the relay from a phone the relay account
	// does not list as paying (owner decision pending, ask #941); the hub
	// could not record the request (with retry_after_s: ask again); a hub
	// that cannot switch (no second transport).
	SwitchTooSoon      = "too_soon"
	SwitchNotPaying    = "not_paying"
	SwitchUnavailable  = "unavailable"
	SwitchNotSupported = "not supported yet"
)

// Heartbeat flavors and sharing states.
const (
	FlavorDefault    = "default"
	FlavorCorp       = "corp"
	SharingAvailable = "available"
	SharingNone      = "none"
	SharingUnavail   = "unavailable"
)

// FlavorOf is the heartbeat flavor of a build flavor (the build profile's
// BUILD_FLAVOR, Desktop's WTBuildFlavor; HubIdentity.flavor): none or "dev"
// is the default build, any other is a corporate build.
func FlavorOf(buildFlavor string) string {
	if buildFlavor == "" || buildFlavor == "dev" {
		return FlavorDefault
	}
	return FlavorCorp
}

// ActionRequest is a phone action and, rewritten by the hub, its echo. The
// kind stays a string: an unknown kind is answered, not rejected on decode.
type ActionRequest struct {
	ID           string                     `json:"id"`
	Kind         string                     `json:"kind"`
	EntityID     *string                    `json:"entity_id,omitempty"`
	Params       map[string]json.RawMessage `json:"params"`
	CreatedAt    Time                       `json:"created_at"`
	Status       string                     `json:"status"`
	ErrorMessage *string                    `json:"error_message,omitempty"`
	DeviceID     *string                    `json:"device_id,omitempty"`
	HubID        *string                    `json:"hub_id,omitempty"`
	Reason       *string                    `json:"reason,omitempty"`
	Result       map[string]json.RawMessage `json:"result,omitempty"`
	// ActionSeq is the per-phone order number inside the sealed payload; nil
	// takes the legacy (unordered) path.
	ActionSeq *uint64 `json:"action_seq,omitempty"`
}

// Control is the sealed body of a control record `c-<uuid>` (relay design
// §4.2, sim rules 9-12; relay client spec §5). Fields by kind:
//
//	resend_from, skip_to           Seq
//	epoch_ack                      Epoch (NextKX: the phone's offered relay key)
//	transport_switch               Target (phone -> hub; Reason on entitlement_expired)
//	transport_switched             Target, Epoch, By, At, Keybox (the new epoch's sealed keybox)
//	transport_switch_rejected      Reason, RetryAfterS
//	hub_on_relay                   none
type Control struct {
	ID       string  `json:"id"`
	Kind     string  `json:"kind"`
	DeviceID *string `json:"device_id,omitempty"`
	HubID    *string `json:"hub_id,omitempty"`
	Seq      *uint64 `json:"seq,omitempty"`
	Epoch    *uint32 `json:"epoch,omitempty"`
	// Target is a transport: TransportRelay or TransportCloudKit.
	Target *string `json:"target,omitempty"`
	// By is the device id of the phone whose switch this answers, or
	// SwitchedByEntitlement.
	By *string `json:"by,omitempty"`
	At *Time   `json:"at,omitempty"`
	// Keybox, inside transport_switched, is the unpadded base64url of the
	// sealed keybox-<DEVICE_ID> envelope of the new epoch for that phone
	// (signed by hub_sig, sealed to its dev_kx: the bytes the data zone
	// would carry). A phone reads a value that is not a string as no keybox.
	Keybox *string `json:"keybox,omitempty"`
	Reason *string `json:"reason,omitempty"`
	// RetryAfterS is whole seconds (the relay proto's retry_after_s).
	RetryAfterS *uint32 `json:"retry_after_s,omitempty"`
	// NextKX, inside epoch_ack, is the phone's offered ephemeral X25519
	// public key for its next relay keys (relay client Phase 5), unpadded
	// base64url of 32 bytes. Absent from a phone that offers none; a hub that
	// predates it ignores the key.
	NextKX *string `json:"next_kx,omitempty"`
}

// Marker is the transport marker's payload for a transport_switched c
// (protocol §7.6, phone contract point 4): c without its keybox and
// device_id, the same for every phone.
func (c Control) Marker() Control {
	c.Keybox, c.DeviceID = nil, nil
	return c
}

// Transport marker record: plain kind "transport", id "marker", in a
// transport's data zone.
const (
	MarkerKind  = "transport"
	MarkerPlain = MarkerKind + "-marker"
)

// HeartbeatAccount is one read-only account row: label and status only.
type HeartbeatAccount struct {
	Kind   string `json:"kind"`
	Label  string `json:"label"`
	Status string `json:"status"`
}

// Heartbeat is the hub's liveness record (record name "heartbeat").
type Heartbeat struct {
	UpdatedAt     Time               `json:"updated_at"`
	AppVersion    string             `json:"app_version"`
	HubID         string             `json:"hub_id"`
	MacName       string             `json:"mac_name"`
	Flavor        string             `json:"flavor"`
	LastPublishAt *Time              `json:"last_publish_at,omitempty"`
	LastRelayAt   *Time              `json:"last_relay_at,omitempty"`
	RelayBacklog  int                `json:"relay_backlog"`
	Accounts      []HeartbeatAccount `json:"accounts"`
	EnabledAt     Time               `json:"enabled_at"`
	OwnerUser     string             `json:"owner_user"`
	Sharing       string             `json:"sharing"`
	// Capabilities is the host's switches (protocol §9); absent from an
	// older hub, which the phone reads as every capability on.
	Capabilities *HeartbeatCapabilities `json:"capabilities,omitempty"`
}

// HeartbeatCapabilities is the heartbeat's capabilities object. Recordings
// is "on" or "off"; an unknown value reads as not off.
type HeartbeatCapabilities struct {
	Recordings string `json:"recordings,omitempty"`
}

// RecordingsCapability is the capabilities object for the switch: "on" or
// "off". The phone offers recording unless it reads "off".
func RecordingsCapability(on bool) *HeartbeatCapabilities {
	if on {
		return &HeartbeatCapabilities{Recordings: "on"}
	}
	return &HeartbeatCapabilities{Recordings: "off"}
}

// DevicePayload is the phone's link record (the hello's plain device part).
// RelayDeviceID, RelayAuthPub and RelayIDSig are an upgraded phone's relay
// identity in its own device record (protocol §5.5): its hosted-relay
// device id, its relay_auth Ed25519 public key and that key's signature
// over link.RelayIDProofMessage, each unpadded base64url; the hub stores the
// id only when link.VerifyRelayIDProof accepts the three. Absent from older
// phones and from a phone with no relay identity.
type DevicePayload struct {
	DeviceID             string  `json:"device_id"`
	Name                 string  `json:"name"`
	Model                string  `json:"model"`
	AppVersion           string  `json:"app_version"`
	Scope                string  `json:"scope"`
	UserRecordName       string  `json:"user_record_name"`
	LinkNonce            *string `json:"link_nonce,omitempty"`
	Unlinked             *bool   `json:"unlinked,omitempty"`
	TypingRequested      bool    `json:"typing_requested"`
	StartSessions        bool    `json:"start_sessions"`
	PermissionsRequested *bool   `json:"permissions_requested,omitempty"`
	SeenAt               *Time   `json:"seen_at,omitempty"`
	UpdatedAt            Time    `json:"updated_at"`
	RelayDeviceID        string  `json:"relay_device_id,omitempty"`
	RelayAuthPub         string  `json:"relay_auth_pub,omitempty"`
	RelayIDSig           string  `json:"relay_id_sig,omitempty"`
	// WorkAlertsOff is the phone's "When work stops" switch being off (true or
	// absent, protocol §5.5): the hub sends this phone no relay alert.
	WorkAlertsOff *bool `json:"work_alerts_off,omitempty"`
}

// DeviceHello is the plain payload of a hello, sealed to the hub's key.
// RelayDeviceID is the phone's own hosted-relay device id (lower-case
// unpadded base32 of SHA-256 of its relay_auth key), sent by a phone linking
// over the hosted relay so the hub can name it in set_hub_readers; absent on
// the CloudKit route and from phones that predate it.
type DeviceHello struct {
	Device        DevicePayload `json:"device"`
	SigningKey    string        `json:"signing_key"`
	AgreementKey  string        `json:"agreement_key"`
	RelayDeviceID string        `json:"relay_device_id,omitempty"`
}

// KeyboxKeys are the epoch keys of a keybox, base64url of 32 bytes each.
type KeyboxKeys struct {
	Epoch            uint32  `json:"epoch"`
	DataKey          string  `json:"data_key"`
	AlertKey         string  `json:"alert_key"`
	MetaKey          string  `json:"meta_key"`
	PreviousEpoch    *uint32 `json:"previous_epoch,omitempty"`
	PreviousDataKey  *string `json:"previous_data_key,omitempty"`
	PreviousAlertKey *string `json:"previous_alert_key,omitempty"`
	// RelayKX names the ephemeral pair of this epoch's wt/relay/v2/ relay
	// keys; nil means the static wt/relay/v1/ keys (a phone with no offer, or
	// a hub that predates Phase 5).
	RelayKX *KeyboxRelayKX `json:"relay_kx,omitempty"`
	// PreviousRelayKX is RelayKX of PreviousEpoch.
	PreviousRelayKX *KeyboxRelayKX `json:"previous_relay_kx,omitempty"`
}

// KeyboxRelayKX is the ephemeral pair of one epoch's relay keys: the hub's
// drawn hub_eph public and the phone's offered dev_eph public it answers,
// unpadded base64url of 32 bytes each. The phone finds its private half by
// DevicePub.
type KeyboxRelayKX struct {
	HubPub    string `json:"hub_pub"`
	DevicePub string `json:"device_pub"`
}

// Keybox is the plain payload of a keybox: the grant plus, once the owner
// confirmed, the keys (a revoked keybox carries the grant only).
type Keybox struct {
	Grant DeviceGrant `json:"grant"`
	Keys  *KeyboxKeys `json:"keys,omitempty"`
}
