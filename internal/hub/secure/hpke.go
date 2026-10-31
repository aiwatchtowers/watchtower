package secure

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hpke"
	"fmt"
)

// The HPKE suite of the hello and keybox classes (SealedBox.swift, RFC 9180
// mode base): DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / ChaCha20-Poly1305.
const (
	hpkeKEMX25519  uint16 = 0x0020
	hpkeKDFSHA256  uint16 = 0x0001
	hpkeAEADChaCha uint16 = 0x0003
	// hpkeEncLen is the encapsulated key in front of the ciphertext; the
	// frame cap shrinks by it.
	hpkeEncLen = 32
)

// HelloInfo is "wt/hello/v1" ‖ hub_id ‖ link_nonce.
func HelloInfo(hub ID, linkNonce []byte) []byte {
	out := make([]byte, 0, 11+16+len(linkNonce))
	out = append(out, "wt/hello/v1"...)
	out = append(out, hub[:]...)
	return append(out, linkNonce...)
}

// KeyboxInfo is "wt/keybox/v1" ‖ hub_id ‖ device_id.
func KeyboxInfo(hub, device ID) []byte {
	out := make([]byte, 0, 12+32)
	out = append(out, "wt/keybox/v1"...)
	out = append(out, hub[:]...)
	return append(out, device[:]...)
}

func hpkeClass(c EnvelopeClass) bool { return c == ClassHello || c == ClassKeybox }

// hpkeSuite is the KDF and AEAD of the suite; the KEM follows from the key.
func hpkeSuite() (hpke.KDF, hpke.AEAD, error) {
	kdf, err := hpke.NewKDF(hpkeKDFSHA256)
	if err != nil {
		return nil, nil, fmt.Errorf("secure: hpke kdf: %w", err)
	}
	aead, err := hpke.NewAEAD(hpkeAEADChaCha)
	if err != nil {
		return nil, nil, fmt.Errorf("secure: hpke aead: %w", err)
	}
	return kdf, aead, nil
}

// sealHPKEBody is enc 32 ‖ HPKE ciphertext ‖ tag for one message (sequence 0).
func sealHPKEBody(to *ecdh.PublicKey, info, aad, plain []byte) ([]byte, error) {
	if to == nil {
		return nil, fmt.Errorf("secure: no hpke recipient")
	}
	pk, err := hpke.NewDHKEMPublicKey(to)
	if err != nil || pk.KEM().ID() != hpkeKEMX25519 {
		return nil, fmt.Errorf("secure: hpke recipient is not an X25519 key")
	}
	kdf, aead, err := hpkeSuite()
	if err != nil {
		return nil, err
	}
	enc, sender, err := hpke.NewSender(pk, kdf, aead, info)
	if err != nil {
		return nil, fmt.Errorf("secure: hpke sender: %w", err)
	}
	ct, err := sender.Seal(aad, plain)
	if err != nil {
		return nil, fmt.Errorf("secure: hpke seal: %w", err)
	}
	if len(enc) != hpkeEncLen {
		return nil, ErrLengthMismatch
	}
	return append(enc, ct...), nil
}

// openHPKEBody opens enc 32 ‖ ciphertext ‖ tag; every failure is
// ErrAuthenticationFailed (wrong key, wrong code nonce, moved record, flipped bit).
func openHPKEBody(recipient *ecdh.PrivateKey, info, aad, body []byte) ([]byte, error) {
	if recipient == nil || len(body) < hpkeEncLen+tagLen {
		return nil, ErrAuthenticationFailed
	}
	sk, err := hpke.NewDHKEMPrivateKey(recipient)
	if err != nil || sk.KEM().ID() != hpkeKEMX25519 {
		return nil, ErrAuthenticationFailed
	}
	kdf, aead, err := hpkeSuite()
	if err != nil {
		return nil, err
	}
	r, err := hpke.NewRecipient(body[:hpkeEncLen], sk, kdf, aead, info)
	if err != nil {
		return nil, ErrAuthenticationFailed
	}
	plain, err := r.Open(aad, body[hpkeEncLen:])
	if err != nil {
		return nil, ErrAuthenticationFailed
	}
	return plain, nil
}

// SealHPKE seals a hello or keybox (SealedBox.seal): always padded and signed,
// the frame capped at FrameCap(true) − 32, header nonce zeros, body =
// enc 32 ‖ ciphertext ‖ tag. ErrWrongClass for any other class,
// ErrSignatureRequired without a signer, ErrOversized when the frame cannot fit.
func SealHPKE(f InnerFrame, c EnvelopeClass, to *ecdh.PublicKey, info []byte, hub, sender ID, epoch uint32, seq uint64, ctx Context, signer ed25519.PrivateKey) ([]byte, error) {
	if !hpkeClass(c) {
		return nil, fmt.Errorf("%w: %d is not an HPKE class", ErrWrongClass, c)
	}
	if len(signer) != ed25519.PrivateKeySize {
		return nil, ErrSignatureRequired
	}
	padded, ok := PaddedLength(f.EncodedLength(), FrameCap(true)-hpkeEncLen)
	if !ok {
		return nil, ErrOversized
	}
	h := Header{Flags: FlagPadded | FlagSigned, Hub: hub, Sender: sender, Epoch: epoch, Seq: seq, Class: c,
		BodyLen: uint32(hpkeEncLen + padded + tagLen)}
	if f.Asset != nil {
		h.Flags |= FlagHasAsset
	}
	plain, err := f.Encode(padded)
	if err != nil {
		return nil, err
	}
	defer clear(plain)
	aad, err := ctx.aad(h)
	if err != nil {
		return nil, err
	}
	body, err := sealHPKEBody(to, info, aad, plain)
	if err != nil {
		return nil, err
	}
	e := envelope{header: h, body: body}
	e.signature = ed25519.Sign(signer, signatureMessage(aad, e.body))
	return e.encode(), nil
}

// OpenHPKE parses raw, checks its class is c, requires a signature on the
// wire, verifies it when verifier is set (a keybox requires one:
// ErrSignatureRequired), then opens with recipient. A hello is opened with a
// nil verifier: the device's key is inside the payload, so the link step
// verifies afterwards and checks device_id == DeviceID(signing key).
func OpenHPKE(raw []byte, c EnvelopeClass, recipient *ecdh.PrivateKey, info []byte, ctx Context, verifier ed25519.PublicKey) (Header, InnerFrame, error) {
	if !hpkeClass(c) {
		return Header{}, InnerFrame{}, fmt.Errorf("%w: %d is not an HPKE class", ErrWrongClass, c)
	}
	e, err := parseEnvelope(raw)
	if err != nil {
		return Header{}, InnerFrame{}, err
	}
	h := e.header
	if h.Class != c {
		return Header{}, InnerFrame{}, fmt.Errorf("%w: %d", ErrWrongClass, h.Class)
	}
	if h.Flags&FlagSigned == 0 || e.signature == nil {
		return Header{}, InnerFrame{}, ErrSignatureMissing
	}
	if c == ClassKeybox && verifier == nil {
		return Header{}, InnerFrame{}, ErrSignatureRequired
	}
	if verifier != nil {
		if err := verify(e, ctx, verifier); err != nil {
			return Header{}, InnerFrame{}, err
		}
	}
	if len(e.body) < hpkeEncLen+tagLen {
		return Header{}, InnerFrame{}, ErrLengthMismatch
	}
	aad, err := ctx.aad(h)
	if err != nil {
		return Header{}, InnerFrame{}, err
	}
	plain, err := openHPKEBody(recipient, info, aad, e.body)
	if err != nil {
		return Header{}, InnerFrame{}, err
	}
	defer clear(plain)
	f, err := ParseInnerFrame(plain)
	if err != nil {
		return Header{}, InnerFrame{}, err
	}
	if (h.Flags&FlagHasAsset != 0) != (f.Asset != nil) {
		return Header{}, InnerFrame{}, fmt.Errorf("%w: has-asset flag disagrees with the frame", ErrFrameMalformed)
	}
	return h, cloneFrame(f), nil
}

// cloneFrame copies the payload out of a plaintext buffer the caller zeroes.
func cloneFrame(f InnerFrame) InnerFrame {
	f.Payload = append([]byte(nil), f.Payload...)
	if f.Asset != nil {
		a := *f.Asset
		f.Asset = &a
	}
	return f
}
