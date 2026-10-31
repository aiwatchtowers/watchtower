package hubtest_test

import (
	"encoding/hex"
	"testing"

	"watchtower/internal/hub/transport/relay/client"
)

// The vouch clientDataHash a phone attests a hub with is the relay's shared
// vector (relay docs/watchtower-client-requirements.md, bcca870):
// SHA256("relay/v1/vouch" ‖ nonce ‖ hub_device_id ‖ auth_pub ‖ server_origin).
// Phone.Vouch sends no assertion (dev or exempt), but the Kit phone must
// produce these bytes.
func TestVouchClientDataHashVector(t *testing.T) {
	got := hex.EncodeToString(client.VouchClientDataHash([]byte{1, 2}, "h", []byte{3}, "https://r"))
	if want := "ecdda44ae74bd86e122f2edd43708cf2b8012cc194f78ed5728052e5c109956d"; got != want {
		t.Fatalf("vouch clientDataHash %s, want %s", got, want)
	}
}
