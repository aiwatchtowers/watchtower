package secure

import (
	"encoding/base32"
	"encoding/base64"
	"strings"
)

// base32Lower is RFC 4648 §6, lowercase, no padding (WireBytes.base32).
func base32Lower(b []byte) string {
	return strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b))
}

// base64URL is RFC 4648 §5 without padding (WireBytes.base64URL).
func base64URL(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }
