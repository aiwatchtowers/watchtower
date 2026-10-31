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

// Control is the sealed body of a control record. Provisional: the field set
// follows the relay client spec §5 and may grow with the actions package.
type Control struct {
	ID         string  `json:"id"`
	Kind       string  `json:"kind"`
	DeviceID   *string `json:"device_id,omitempty"`
	HubID      *string `json:"hub_id,omitempty"`
	Seq        *uint64 `json:"seq,omitempty"`
	Epoch      *uint32 `json:"epoch,omitempty"`
	Reason     *string `json:"reason,omitempty"`
	RetryAfter *int    `json:"retry_after,omitempty"`
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
type DeviceHello struct {
	Device       DevicePayload `json:"device"`
	SigningKey   string        `json:"signing_key"`
	AgreementKey string        `json:"agreement_key"`
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
