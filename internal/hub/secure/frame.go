package secure

import (
	"encoding/binary"
	"fmt"
	"math"
	"unicode/utf8"
)

const innerFrameVersion = 1

// InnerFrame is the encrypted plaintext (D1): inner_ver u8 (1) | kind_len u8 |
// kind | id_len u16 | id | notify_len u8 | notify | asset_flag u8 |
// [AssetDescriptor 101] | payload_len u32 | payload | zero padding.
// An empty NotifyLevel is the Kit's nil.
type InnerFrame struct {
	Kind, ID, NotifyLevel string
	Asset                 *AssetDescriptor
	Payload               []byte
}

// EncodedLength is the unpadded length.
func (f InnerFrame) EncodedLength() int {
	n := 1 + 1 + len(f.Kind) + 2 + len(f.ID) + 1 + len(f.NotifyLevel) + 1 + 4 + len(f.Payload)
	if f.Asset != nil {
		n += AssetDescriptorLen
	}
	return n
}

// Encode zero-pads the frame to paddedTo bytes: ErrOversized when paddedTo is
// below EncodedLength, ErrFrameMalformed when a field exceeds its length prefix.
func (f InnerFrame) Encode(paddedTo int) ([]byte, error) {
	if len(f.Kind) > math.MaxUint8 || len(f.ID) > math.MaxUint16 || len(f.NotifyLevel) > math.MaxUint8 ||
		uint64(len(f.Payload)) > math.MaxUint32 {
		return nil, ErrFrameMalformed
	}
	if paddedTo < f.EncodedLength() {
		return nil, ErrOversized
	}
	out := make([]byte, 0, paddedTo)
	out = append(out, innerFrameVersion, byte(len(f.Kind)))
	out = append(out, f.Kind...)
	out = binary.BigEndian.AppendUint16(out, uint16(len(f.ID)))
	out = append(out, f.ID...)
	out = append(out, byte(len(f.NotifyLevel)))
	out = append(out, f.NotifyLevel...)
	if f.Asset != nil {
		out = append(out, 1)
		out = append(out, f.Asset.Encode()...)
	} else {
		out = append(out, 0)
	}
	out = binary.BigEndian.AppendUint32(out, uint32(len(f.Payload)))
	out = append(out, f.Payload...)
	return out[:paddedTo], nil
}

// ParseInnerFrame ignores trailing zeros only: any non-zero byte after the
// payload, a bad prefix or invalid UTF-8 is ErrFrameMalformed.
func ParseInnerFrame(b []byte) (InnerFrame, error) {
	c := cursor{b: b}
	var f InnerFrame
	if v := c.byte(); v != innerFrameVersion {
		return f, ErrFrameMalformed
	}
	f.Kind = c.text(int(c.byte()))
	f.ID = c.text(int(c.uint16()))
	f.NotifyLevel = c.text(int(c.byte()))
	switch c.byte() {
	case 0:
	case 1:
		raw := c.take(AssetDescriptorLen)
		if c.bad {
			break
		}
		d, err := ParseAssetDescriptor(raw)
		if err != nil {
			return InnerFrame{}, fmt.Errorf("%w: asset descriptor", ErrFrameMalformed)
		}
		f.Asset = &d
	default:
		return InnerFrame{}, ErrFrameMalformed
	}
	f.Payload = c.take(int(c.uint32()))
	if c.bad {
		return InnerFrame{}, ErrFrameMalformed
	}
	for _, z := range b[c.pos:] {
		if z != 0 {
			return InnerFrame{}, ErrFrameMalformed
		}
	}
	return f, nil
}

// cursor is a bounds-checked reader; after the first short read every read
// returns zero values and bad stays set.
type cursor struct {
	b   []byte
	pos int
	bad bool
}

func (c *cursor) take(n int) []byte {
	if c.bad || n < 0 || n > len(c.b)-c.pos {
		c.bad = true
		return nil
	}
	out := c.b[c.pos : c.pos+n : c.pos+n]
	c.pos += n
	return out
}

func (c *cursor) byte() byte {
	if b := c.take(1); b != nil {
		return b[0]
	}
	return 0
}

func (c *cursor) uint16() uint16 {
	if b := c.take(2); b != nil {
		return binary.BigEndian.Uint16(b)
	}
	return 0
}

func (c *cursor) uint32() uint32 {
	if b := c.take(4); b != nil {
		return binary.BigEndian.Uint32(b)
	}
	return 0
}

func (c *cursor) text(n int) string {
	b := c.take(n)
	if !utf8.Valid(b) {
		c.bad = true
		return ""
	}
	return string(b)
}
