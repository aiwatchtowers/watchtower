// Package cloudkit is the hub's CloudKit transport on a desktop host (go hub
// spec §6.2): a client of WatchtowerCloudBridge.app, the signed Swift helper
// that alone may reach the owner's iCloud. The client speaks the bridge
// protocol (bridge.proto) over <hub dir>/bridge.sock and implements
// transport.Transport, transport.SharedMailbox and transport.Shares; the
// Supervisor launches the helper and restarts it with a backoff.
//
// The socket carries sealed envelopes and metadata only — the same bytes the
// bridge hands CloudKit. Assets cross as paths under the hub dir, never as
// bytes, and CloudKit change tags never cross: the bridge numbers them
// (tag_seq) and its change feeds (cursors), and both stay opaque here, as on
// memfake's CloudKit kind — a record's RecordSeq is compared for equality
// only and never with a Changes cursor.
package cloudkit

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"google.golang.org/protobuf/proto"
)

// SocketName is the bridge socket's file name in the hub dir.
const SocketName = "bridge.sock"

// MaxFrame is the largest protobuf message one frame carries.
const MaxFrame = 4 << 20

// ProtocolVersion is the bridge protocol version the client speaks.
const ProtocolVersion = 1

// ErrFrameTooLarge is a frame longer than MaxFrame.
var ErrFrameTooLarge = errors.New("cloudkit: frame too large")

var marshal = proto.MarshalOptions{Deterministic: true}

// EncodeFrame is m's frame: a u32 big-endian length, then m's bytes.
func EncodeFrame(m proto.Message) ([]byte, error) {
	n := marshal.Size(m)
	if n > MaxFrame {
		return nil, ErrFrameTooLarge
	}
	b := make([]byte, 4, 4+n)
	binary.BigEndian.PutUint32(b, uint32(n))
	b, err := marshal.MarshalAppend(b, m)
	if err != nil {
		return nil, fmt.Errorf("cloudkit: encode frame: %w", err)
	}
	return b, nil
}

// ReadFrame reads one frame from r into m and returns its message bytes.
func ReadFrame(r io.Reader, m proto.Message) ([]byte, error) {
	var head [4]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(head[:])
	if n > MaxFrame {
		return nil, ErrFrameTooLarge
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		return nil, err
	}
	if err := proto.Unmarshal(b, m); err != nil {
		return nil, fmt.Errorf("cloudkit: decode frame: %w", err)
	}
	return b, nil
}
