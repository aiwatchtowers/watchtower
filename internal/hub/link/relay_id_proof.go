package link

import (
	"crypto/ed25519"
	"encoding/base64"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

// relayIDProofDomain opens the message a phone's relay_auth key signs to
// name its relay id in its device record.
const relayIDProofDomain = "watchtower/v1/relay-id"

// RelayIDProofMessage is what a phone's relay_auth key signs to name its
// relay id to a hub (protocol §5.5, the Kit's RelayIDProof.message):
// "watchtower/v1/relay-id" ‖ 0x00 ‖ hub_id (16 bytes) ‖ device_id (16 bytes)
// ‖ relay_device_id (UTF-8). Binding the hub and the device keeps a
// signature from being replayed to another hub or for another phone.
func RelayIDProofMessage(hubID, deviceID secure.ID, relayDeviceID string) []byte {
	msg := make([]byte, 0, len(relayIDProofDomain)+1+2*len(hubID)+len(relayDeviceID))
	msg = append(msg, relayIDProofDomain...)
	msg = append(msg, 0)
	msg = append(msg, hubID[:]...)
	msg = append(msg, deviceID[:]...)
	return append(msg, relayDeviceID...)
}

// The classes an unproven relay id is logged by (never the id or the key).
const (
	relayIDIncomplete   = "incomplete"
	relayIDInvalid      = "invalid_id"
	relayIDBadKey       = "bad_key"
	relayIDKeyMismatch  = "key_mismatch"
	relayIDBadSignature = "bad_signature"
)

// VerifyRelayIDProof checks the relay identity a phone's device record
// names: all three fields present, a well-formed relay id that is the
// relay_auth key's own (identity.RelayDeviceID) and the key's signature over
// RelayIDProofMessage for this hub and device. ok is false, and the id empty,
// on anything less.
func VerifyRelayIDProof(hubID, deviceID secure.ID, p wire.DevicePayload) (relayID string, ok bool) {
	id, class := checkRelayIDProof(hubID, deviceID, p)
	return id, class == ""
}

// checkRelayIDProof is VerifyRelayIDProof with the class of a refusal ("" =
// proven).
func checkRelayIDProof(hubID, deviceID secure.ID, p wire.DevicePayload) (string, string) {
	if p.RelayDeviceID == "" || p.RelayAuthPub == "" || p.RelayIDSig == "" {
		return "", relayIDIncomplete
	}
	if !validRelayDeviceID(p.RelayDeviceID) {
		return "", relayIDInvalid
	}
	pub, err := keyBytes(p.RelayAuthPub)
	if err != nil {
		return "", relayIDBadKey
	}
	if identity.RelayDeviceID(pub) != p.RelayDeviceID {
		return "", relayIDKeyMismatch
	}
	sig, err := base64.RawURLEncoding.DecodeString(p.RelayIDSig)
	if err != nil || len(sig) != ed25519.SignatureSize ||
		!ed25519.Verify(pub, RelayIDProofMessage(hubID, deviceID, p.RelayDeviceID), sig) {
		return "", relayIDBadSignature
	}
	return p.RelayDeviceID, ""
}
