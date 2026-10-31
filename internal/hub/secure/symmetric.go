package secure

import (
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"slices"

	"golang.org/x/crypto/chacha20poly1305"
)

const tagLen = 16

func symmetricClass(c EnvelopeClass) bool {
	return c == ClassData || c == ClassAlert || c == ClassRelayToHub || c == ClassRelayToPhone
}

// FrameCap is the largest padded frame: MaxEnvelopeBytes − 68 − 16 − (signed ? 64 : 0).
func FrameCap(signed bool) int {
	n := MaxEnvelopeBytes - HeaderLen - tagLen
	if signed {
		n -= signatureLen
	}
	return n
}

// signatureMessage is "wt/sig/v1" ‖ aad ‖ body.
func signatureMessage(aad, body []byte) []byte {
	out := make([]byte, 0, 9+len(aad)+len(body))
	out = append(out, "wt/sig/v1"...)
	out = append(out, aad...)
	return append(out, body...)
}

// SealSymmetric pads f to its bucket, seals it with ChaCha20-Poly1305 under
// key with the AAD of ctx, and signs it when signer is set. nonce nil draws a
// random one; a given nonce must be 12 bytes (vectors only).
func SealSymmetric(f InnerFrame, c EnvelopeClass, key []byte, hub, sender ID, epoch uint32, seq uint64, ctx Context, signer ed25519.PrivateKey, nonce []byte) ([]byte, error) {
	if !symmetricClass(c) {
		return nil, fmt.Errorf("%w: %d is not symmetric", ErrWrongClass, c)
	}
	signed := signer != nil
	padded, ok := PaddedLength(f.EncodedLength(), FrameCap(signed))
	if !ok {
		return nil, ErrOversized
	}
	h := Header{Flags: FlagPadded, Hub: hub, Sender: sender, Epoch: epoch, Seq: seq, Class: c, BodyLen: uint32(padded + tagLen)}
	if signed {
		h.Flags |= FlagSigned
	}
	if f.Asset != nil {
		h.Flags |= FlagHasAsset
	}
	switch {
	case nonce == nil:
		if _, err := rand.Read(h.Nonce[:]); err != nil {
			return nil, fmt.Errorf("secure: nonce: %w", err)
		}
	case len(nonce) == nonceLen:
		h.Nonce = [12]byte(nonce)
	default:
		return nil, ErrLengthMismatch
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
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, fmt.Errorf("secure: seal key: %w", err)
	}
	e := envelope{header: h, body: aead.Seal(nil, h.Nonce[:], plain, aad)}
	if signed {
		e.signature = ed25519.Sign(signer, signatureMessage(aad, e.body))
	}
	return e.encode(), nil
}

// OpenSymmetric parses raw, checks its class is one of accepting, verifies the
// signature when verifier is set (data and alert require one: the AEAD key
// alone is not authorship, spec §2.2), resolves the key from the header, opens
// and parses the frame. An error from key surfaces as itself; every AEAD
// failure is ErrAuthenticationFailed. The key is the caller's: it is neither
// kept nor zeroed here.
func OpenSymmetric(raw []byte, accepting []EnvelopeClass, ctx Context, verifier ed25519.PublicKey, key func(Header) ([]byte, error)) (Header, InnerFrame, error) {
	e, err := parseEnvelope(raw)
	if err != nil {
		return Header{}, InnerFrame{}, err
	}
	h := e.header
	if !slices.Contains(accepting, h.Class) || !symmetricClass(h.Class) {
		return Header{}, InnerFrame{}, fmt.Errorf("%w: %d", ErrWrongClass, h.Class)
	}
	if (h.Class == ClassData || h.Class == ClassAlert) && verifier == nil {
		return Header{}, InnerFrame{}, ErrSignatureRequired
	}
	aad, err := ctx.aad(h)
	if err != nil {
		return Header{}, InnerFrame{}, err
	}
	if verifier != nil {
		if err := verify(e, aad, verifier); err != nil {
			return Header{}, InnerFrame{}, err
		}
	}
	if len(e.body) < tagLen {
		return Header{}, InnerFrame{}, ErrLengthMismatch
	}
	// Resolved outside the AEAD: an unknown epoch or locked store surfaces as itself.
	k, err := key(h)
	if err != nil {
		return Header{}, InnerFrame{}, fmt.Errorf("secure: envelope key: %w", err)
	}
	aead, err := chacha20poly1305.New(k)
	if err != nil {
		return Header{}, InnerFrame{}, ErrAuthenticationFailed
	}
	plain, err := aead.Open(nil, h.Nonce[:], e.body, aad)
	if err != nil {
		return Header{}, InnerFrame{}, ErrAuthenticationFailed
	}
	f, err := ParseInnerFrame(plain)
	if err != nil {
		return Header{}, InnerFrame{}, err
	}
	if (h.Flags&FlagHasAsset != 0) != (f.Asset != nil) {
		return Header{}, InnerFrame{}, fmt.Errorf("%w: has-asset flag disagrees with the frame", ErrFrameMalformed)
	}
	return h, f, nil
}

// verify checks the signature only (no secret key).
func verify(e envelope, aad []byte, pub ed25519.PublicKey) error {
	if e.header.Flags&FlagSigned == 0 || e.signature == nil {
		return ErrSignatureMissing
	}
	if len(pub) != ed25519.PublicKeySize || !ed25519.Verify(pub, signatureMessage(aad, e.body), e.signature) {
		return ErrSignatureInvalid
	}
	return nil
}
