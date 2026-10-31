package secure

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

// Zone is the AAD zone byte; these values never change.
type Zone uint8

// The two zones: the hub's DataZone and the mailbox ("relay") lane.
const (
	ZoneData  Zone = 1
	ZoneRelay Zone = 2
)

// Direction picks a relay key (RelayDirection).
type Direction string

// The two relay directions.
const (
	PhoneToHub Direction = "p2h"
	HubToPhone Direction = "h2p"
)

// ConfirmNonceLength is the bytes of the hub's SAS v2 confirm nonce.
const ConfirmNonceLength = 32

// RelayKey is HKDF-SHA256(ikm: X25519(own, peer), salt: linkNonce,
// info: "wt/relay/v1/" ‖ dir ‖ 0x00 ‖ hub(16) ‖ device(16) ‖ epoch u32 BE), 32 bytes.
func RelayKey(own *ecdh.PrivateKey, peer *ecdh.PublicKey, linkNonce []byte, hub, device ID, epoch uint32, dir Direction) ([]byte, error) {
	shared, err := own.ECDH(peer)
	if err != nil {
		return nil, fmt.Errorf("secure: relay key agreement: %w", err)
	}
	defer clear(shared)
	info := make([]byte, 0, 16+len(dir)+1+32+4)
	info = append(info, "wt/relay/v1/"...)
	info = append(info, dir...)
	info = append(info, 0)
	info = append(info, hub[:]...)
	info = append(info, device[:]...)
	info = binary.BigEndian.AppendUint32(info, epoch)
	key, err := hkdf.Key(sha256.New, shared, linkNonce, string(info), 32)
	if err != nil {
		return nil, fmt.Errorf("secure: relay key derivation: %w", err)
	}
	return key, nil
}

// RecordName is base32lower(HMAC-SHA256(metaKey, "wt/name/v1" ‖ zone u8 ‖
// kind_len u8 ‖ kind ‖ id)[0..<16]), 26 characters. A kind above 255 bytes
// is clamped, as in the Kit.
func RecordName(metaKey []byte, z Zone, kind, id string) string {
	kindBytes := []byte(kind)
	if len(kindBytes) > 255 {
		kindBytes = kindBytes[:255]
	}
	mac := hmac.New(sha256.New, metaKey)
	mac.Write([]byte("wt/name/v1"))
	mac.Write([]byte{byte(z), byte(len(kindBytes))})
	mac.Write(kindBytes)
	mac.Write([]byte(id))
	return base32Lower(mac.Sum(nil)[:16])
}

// DeviceID is the UUID of SHA-256("wt/device-id/v1" ‖ dev_sig_pub)[0..<16] (D7).
func DeviceID(sigPub ed25519.PublicKey) ID {
	h := sha256.New()
	h.Write([]byte("wt/device-id/v1"))
	h.Write(sigPub)
	var id ID
	copy(id[:], h.Sum(nil))
	return id
}

// LinkCodeTag tells which link code a waiting keybox answers (SAS v2):
// base64url of SHA-256("wt/link-code/v1" ‖ linkNonce)[0..<16].
func LinkCodeTag(linkNonce []byte) string {
	h := sha256.New()
	h.Write([]byte("wt/link-code/v1"))
	h.Write(linkNonce)
	return base64URL(h.Sum(nil)[:16])
}

// SAS is the four-digit pairing code (SAS v2): T = SHA-256("wt/sas/v2" ‖ hub ‖
// linkNonce ‖ hub_sig_pub ‖ hub_kx_pub ‖ dev_sig_pub ‖ dev_kx_pub ‖ confirmNonce);
// okm = HKDF-SHA256(ikm: T, salt: linkNonce, info: "wt/sas/v2", 4 bytes);
// UInt32(big-endian okm) % 10 000, zero-padded.
func SAS(hub ID, linkNonce []byte, hubSig ed25519.PublicKey, hubKX *ecdh.PublicKey, devSig ed25519.PublicKey, devKX *ecdh.PublicKey, confirmNonce []byte) string {
	h := sha256.New()
	h.Write([]byte("wt/sas/v2"))
	h.Write(hub[:])
	h.Write(linkNonce)
	h.Write(hubSig)
	h.Write(hubKX.Bytes())
	h.Write(devSig)
	h.Write(devKX.Bytes())
	h.Write(confirmNonce)
	digest := h.Sum(nil)
	defer clear(digest)
	// HKDF over SHA-256 with a 4-byte output cannot fail.
	okm, _ := hkdf.Key(sha256.New, digest, linkNonce, "wt/sas/v2", 4)
	return fmt.Sprintf("%04d", binary.BigEndian.Uint32(okm)%10000)
}
