package secure

import (
	"encoding/binary"
	"fmt"
	"math"
)

// EnvelopeClass says how the body is sealed and by whom it is signed.
type EnvelopeClass uint16

// The six classes (Envelope.swift).
const (
	ClassData         EnvelopeClass = 1 // AEAD K_data[e], signed by hub_sig
	ClassAlert        EnvelopeClass = 2 // AEAD K_alert[e], signed by hub_sig
	ClassKeybox       EnvelopeClass = 3 // HPKE to dev_kx, signed by hub_sig
	ClassHello        EnvelopeClass = 4 // HPKE to hub_kx, signed by dev_sig
	ClassRelayToHub   EnvelopeClass = 5 // AEAD K_relay p2h[e]
	ClassRelayToPhone EnvelopeClass = 6 // AEAD K_relay h2p[e]
)

// Header flag bits.
const (
	FlagSigned   uint8 = 1
	FlagHasAsset uint8 = 2
	FlagPadded   uint8 = 4
	knownFlags         = FlagSigned | FlagHasAsset | FlagPadded
)

// Envelope sizes.
const (
	HeaderLen        = 68
	MaxEnvelopeBytes = 900_000
	signatureLen     = 64
	nonceLen         = 12
	envelopeVersion  = 1
	envelopeSuite1   = 1
)

var envelopeMagic = [3]byte{'W', 'T', 'E'}

// Header is the 68-byte envelope header: "WTE" | ver | suite | flags |
// hub 16 | sender 16 | epoch u32 | seq u64 | nonce 12 | class u16 | body_len u32.
// The nonce is zeros for the HPKE classes.
type Header struct {
	Flags       uint8
	Hub, Sender ID
	Epoch       uint32
	Seq         uint64
	Nonce       [12]byte
	Class       EnvelopeClass
	BodyLen     uint32
}

func (h Header) encode() []byte {
	out := make([]byte, 0, HeaderLen)
	out = append(out, envelopeMagic[:]...)
	out = append(out, envelopeVersion, envelopeSuite1, h.Flags)
	out = append(out, h.Hub[:]...)
	out = append(out, h.Sender[:]...)
	out = binary.BigEndian.AppendUint32(out, h.Epoch)
	out = binary.BigEndian.AppendUint64(out, h.Seq)
	out = append(out, h.Nonce[:]...)
	out = binary.BigEndian.AppendUint16(out, uint16(h.Class))
	out = binary.BigEndian.AppendUint32(out, h.BodyLen)
	return out
}

// parseHeader is strict: wrong magic, unknown version, suite, class and flag
// bits are refused.
func parseHeader(b []byte) (Header, error) {
	var h Header
	if len(b) < HeaderLen {
		return h, ErrTooShort
	}
	if [3]byte(b[:3]) != envelopeMagic {
		return h, ErrBadMagic
	}
	if b[3] != envelopeVersion {
		return h, fmt.Errorf("%w: %d", ErrUnsupportedVersion, b[3])
	}
	if b[4] != envelopeSuite1 {
		return h, fmt.Errorf("%w: %d", ErrUnsupportedSuite, b[4])
	}
	if b[5]&^knownFlags != 0 {
		return h, fmt.Errorf("%w: unknown flag bits", ErrFrameMalformed)
	}
	h.Flags = b[5]
	h.Hub = ID(b[6:22])
	h.Sender = ID(b[22:38])
	h.Epoch = binary.BigEndian.Uint32(b[38:42])
	h.Seq = binary.BigEndian.Uint64(b[42:50])
	h.Nonce = [12]byte(b[50:62])
	h.Class = EnvelopeClass(binary.BigEndian.Uint16(b[62:64]))
	if h.Class < ClassData || h.Class > ClassRelayToPhone {
		return Header{}, fmt.Errorf("%w: %d", ErrUnknownClass, h.Class)
	}
	h.BodyLen = binary.BigEndian.Uint32(b[64:68])
	return h, nil
}

// Context is the out-of-band AAD (spec §2.4): the zone and the wire record
// name the envelope belongs to.
type Context struct {
	Zone     Zone
	WireName string
}

// aad is header ‖ zone u8 ‖ name_len u16 ‖ name; ErrFrameMalformed for a name
// above 65 535 bytes.
func (c Context) aad(h Header) ([]byte, error) {
	if len(c.WireName) > math.MaxUint16 {
		return nil, fmt.Errorf("%w: wire name too long", ErrFrameMalformed)
	}
	out := make([]byte, 0, HeaderLen+3+len(c.WireName))
	out = append(out, h.encode()...)
	out = append(out, byte(c.Zone))
	out = binary.BigEndian.AppendUint16(out, uint16(len(c.WireName)))
	return append(out, c.WireName...), nil
}

// envelope is a parsed wire envelope; body is ciphertext ‖ tag (AEAD) or
// enc 32 ‖ ciphertext ‖ tag (HPKE); signature is set when the header is signed.
type envelope struct {
	header    Header
	body      []byte
	signature []byte
}

func (e envelope) encode() []byte {
	out := make([]byte, 0, HeaderLen+len(e.body)+len(e.signature))
	out = append(out, e.header.encode()...)
	out = append(out, e.body...)
	return append(out, e.signature...)
}

// parseEnvelope refuses an envelope above MaxEnvelopeBytes, a bad header and
// any length mismatch.
func parseEnvelope(b []byte) (envelope, error) {
	if len(b) > MaxEnvelopeBytes {
		return envelope{}, ErrOversized
	}
	h, err := parseHeader(b)
	if err != nil {
		return envelope{}, err
	}
	sigLen := 0
	if h.Flags&FlagSigned != 0 {
		sigLen = signatureLen
	}
	bodyEnd := HeaderLen + int(h.BodyLen)
	if len(b) != bodyEnd+sigLen {
		return envelope{}, ErrLengthMismatch
	}
	e := envelope{header: h, body: b[HeaderLen:bodyEnd:bodyEnd]}
	if sigLen != 0 {
		e.signature = b[bodyEnd:]
	}
	return e, nil
}
