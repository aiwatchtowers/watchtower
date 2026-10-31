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
)

// Heartbeat flavors and sharing states.
const (
	FlavorDefault    = "default"
	FlavorCorp       = "corp"
	SharingAvailable = "available"
	SharingNone      = "none"
	SharingUnavail   = "unavailable"
)

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
//	epoch_ack                      Epoch
//	transport_switch               Target (phone -> hub; Reason on entitlement_expired)
//	transport_switched             Target, Epoch, By, At, Keybox (the new epoch's keybox)
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
	// By is the device id of the phone whose switch this answers.
	By *string `json:"by,omitempty"`
	At *Time   `json:"at,omitempty"`
	// Keybox carries the new epoch's keys inside transport_switched.
	Keybox *Keybox `json:"keybox,omitempty"`
	Reason *string `json:"reason,omitempty"`
	// RetryAfterS is whole seconds (the relay proto's retry_after_s).
	RetryAfterS *uint32 `json:"retry_after_s,omitempty"`
}

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

// Recording switch values on the wire.
const (
	CapabilityOn  = "on"
	CapabilityOff = "off"
)

// RecordingsCapability is the capabilities object for the switch.
func RecordingsCapability(on bool) *HeartbeatCapabilities {
	if on {
		return &HeartbeatCapabilities{Recordings: CapabilityOn}
	}
	return &HeartbeatCapabilities{Recordings: CapabilityOff}
}

// RecordingsOffered is the phone's reading: recording is offered unless the
// heartbeat says "off" (absent, unknown values and keys read as on).
func (h Heartbeat) RecordingsOffered() bool {
	return h.Capabilities == nil || h.Capabilities.Recordings != CapabilityOff
}

// DevicePayload is the phone's link record (the hello's plain device part).
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
}

// Keybox is the plain payload of a keybox: the grant plus, once the owner
// confirmed, the keys (a revoked keybox carries the grant only).
type Keybox struct {
	Grant DeviceGrant `json:"grant"`
	Keys  *KeyboxKeys `json:"keys,omitempty"`
}
