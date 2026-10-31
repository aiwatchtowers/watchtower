package wire

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"time"
)

// Link code constants (spec §12a; the Kit's `LinkPayload` at v3).
const (
	LinkPayloadVersion = 4
	LinkLifetime       = 600 * time.Second
	MaxMacNameLength   = 60
)

// Why a scanned URL is not a usable link code.
var (
	ErrNotALink     = errors.New("wire: not a watchtower link")
	ErrBadEncoding  = errors.New("wire: bad link encoding")
	ErrMissingField = errors.New("wire: link field missing")
	ErrNewerVersion = errors.New("wire: link written by a newer hub")
	ErrOlderVersion = errors.New("wire: link written by an older hub")
	ErrBadHubKey    = errors.New("wire: hub key is not 32 non-zero bytes of base64url")
)

// LinkPayload is the QR link code `watchtower://link?d=<base64url(JSON)>`.
// `container` and `owner_user` are optional in v4 (a headless host has
// neither); the CKShare URLs are absent for a hub without CloudKit.
type LinkPayload struct {
	V             int      `json:"v"`
	Container     string   `json:"container,omitempty"`
	HubID         string   `json:"hub_id"`
	MacName       string   `json:"mac_name"`
	OwnerUser     string   `json:"owner_user,omitempty"`
	Nonce         string   `json:"nonce"`
	Iat           int64    `json:"iat"`
	Exp           int64    `json:"exp"`
	DataShare     *string  `json:"data_share,omitempty"`
	RelayShare    *string  `json:"relay_share,omitempty"`
	HubSig        string   `json:"hub_sig"`
	HubKX         string   `json:"hub_kx"`
	Transport     string   `json:"transport,omitempty"`
	RelayDeviceID string   `json:"relay_device_id,omitempty"`
	RelayAuthPub  string   `json:"relay_auth_pub,omitempty"`
	Transports    []string `json:"transports,omitempty"`
}

// Keys the Kit's decoder reads (after the version) in its order: the two hub
// keys first, then the rest. A key that is absent or null is missing.
var restLinkKeys = []string{"hub_id", "mac_name", "nonce", "iat", "exp"}

// ClipMacName clips to MaxMacNameLength runes. The Kit clips grapheme
// clusters, so a name with combining marks can differ; hub names are plain
// host names (known gap).
func ClipMacName(s string) string {
	r := []rune(s)
	if len(r) > MaxMacNameLength {
		return string(r[:MaxMacNameLength])
	}
	return s
}

// URL renders the code.
func (p LinkPayload) URL() (string, error) {
	p.MacName = ClipMacName(p.MacName)
	b, err := MarshalUnescapedSlashes(p)
	if err != nil {
		return "", err
	}
	return "watchtower://link?d=" + base64.RawURLEncoding.EncodeToString(b), nil
}

// ParseLinkURL decodes a scanned URL. The version is probed first, so a newer
// code reads as ErrNewerVersion and an older one as ErrOlderVersion whatever
// its shape. Errors wrap the sentinels; ErrMissingField names the key.
func ParseLinkURL(s string) (LinkPayload, error) {
	var zero LinkPayload
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "watchtower" || u.Host != "link" {
		return zero, ErrNotALink
	}
	enc := u.Query().Get("d")
	raw, err := base64.RawURLEncoding.Strict().DecodeString(enc)
	if enc == "" || err != nil {
		return zero, ErrBadEncoding
	}
	var keys map[string]json.RawMessage
	if json.Unmarshal(raw, &keys) != nil {
		return zero, ErrBadEncoding
	}
	present := func(k string) bool {
		r, ok := keys[k]
		return ok && string(r) != "null"
	}
	if !present("v") {
		return zero, fmt.Errorf("%w: v", ErrMissingField)
	}
	var v int
	if json.Unmarshal(keys["v"], &v) != nil {
		return zero, ErrBadEncoding
	}
	if v > LinkPayloadVersion {
		return zero, ErrNewerVersion
	}
	if v < LinkPayloadVersion {
		return zero, ErrOlderVersion
	}
	// The Kit's order: both hub keys present, both valid, then the rest.
	for _, k := range []string{"hub_sig", "hub_kx"} {
		if !present(k) {
			return zero, fmt.Errorf("%w: %s", ErrMissingField, k)
		}
	}
	for _, k := range []string{"hub_sig", "hub_kx"} {
		var key string
		if json.Unmarshal(keys[k], &key) != nil {
			return zero, ErrBadEncoding
		}
		if !validHubKey(key) {
			return zero, ErrBadHubKey
		}
	}
	for _, k := range restLinkKeys {
		if !present(k) {
			return zero, fmt.Errorf("%w: %s", ErrMissingField, k)
		}
	}
	var p LinkPayload
	if json.Unmarshal(raw, &p) != nil {
		return zero, ErrBadEncoding
	}
	p.MacName = ClipMacName(p.MacName)
	return p, nil
}

func validHubKey(s string) bool {
	b, err := base64.RawURLEncoding.Strict().DecodeString(s)
	if err != nil || len(b) != 32 {
		return false
	}
	for _, c := range b {
		if c != 0 {
			return true
		}
	}
	return false
}
