// Package sessionhost holds the building blocks of the workbench session
// host: the wire frame codec, the output ring buffer and the DEC private mode
// tracker used to replay terminal state to a re-attaching client.
package sessionhost

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// MaxPayload is the largest frame payload the codec accepts.
const MaxPayload = 1 << 20

// ErrFrameTooLarge is returned when a frame payload exceeds MaxPayload.
var ErrFrameTooLarge = errors.New("sessionhost: frame payload too large")

// FrameType is the one-byte frame discriminator. Client-to-host types have the
// high bit clear, host-to-client replies have it set.
type FrameType byte

// Frame types.
const (
	Hello    FrameType = 0x01
	HelloOK  FrameType = 0x81
	Launch   FrameType = 0x02
	Launched FrameType = 0x82
	Attach   FrameType = 0x03
	Attached FrameType = 0x83
	Input    FrameType = 0x04
	Resize   FrameType = 0x05
	Output   FrameType = 0x84
	Exit     FrameType = 0x85
	List     FrameType = 0x06
	Listed   FrameType = 0x86
	Forget   FrameType = 0x07
	Forgot   FrameType = 0x87
	Error    FrameType = 0x8F
)

// LaunchReq starts a session for a terminal row.
type LaunchReq struct {
	Row        int64    `json:"row"`
	Run        string   `json:"run"`
	Executable string   `json:"executable"`
	Args       []string `json:"args"`
	Env        []string `json:"env"`
	Cwd        string   `json:"cwd"`
	Cols       uint16   `json:"cols"`
	Rows       uint16   `json:"rows"`
}

// AttachReq attaches a client to a running session.
type AttachReq struct {
	Row int64  `json:"row"`
	Run string `json:"run"`
}

// SessionInfo describes one hosted session.
type SessionInfo struct {
	Row         int64  `json:"row"`
	Run         string `json:"run"`
	Pid         int    `json:"pid"`
	StartedAtMs int64  `json:"started_at_ms"`
	Exited      bool   `json:"exited"`
	Code        *int   `json:"code"`
}

// ListResp is the payload of a Listed frame.
type ListResp struct {
	Sessions []SessionInfo `json:"sessions"`
}

// ResizeReq is the payload of a Resize frame.
type ResizeReq struct {
	Cols uint16 `json:"cols"`
	Rows uint16 `json:"rows"`
}

// ExitMsg is the payload of an Exit frame; Code is nil when the process was
// killed by a signal.
type ExitMsg struct {
	Code *int `json:"code"`
}

// WriteFrame writes one frame: type, big-endian uint32 length, payload.
func WriteFrame(w io.Writer, t FrameType, payload []byte) error {
	if len(payload) > MaxPayload {
		return ErrFrameTooLarge
	}
	buf := make([]byte, 5+len(payload))
	buf[0] = byte(t)
	binary.BigEndian.PutUint32(buf[1:5], uint32(len(payload))) //nolint:gosec // bounded by MaxPayload above
	copy(buf[5:], payload)
	if _, err := w.Write(buf); err != nil {
		return fmt.Errorf("write frame: %w", err)
	}
	return nil
}

// ReadFrame reads one frame. It returns io.EOF only when the stream ends on a
// frame boundary.
func ReadFrame(r io.Reader) (FrameType, []byte, error) {
	var hdr [5]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		if errors.Is(err, io.EOF) {
			return 0, nil, io.EOF
		}
		return 0, nil, fmt.Errorf("read frame header: %w", err)
	}
	n := binary.BigEndian.Uint32(hdr[1:5])
	if n > MaxPayload {
		return 0, nil, ErrFrameTooLarge
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, fmt.Errorf("read frame payload: %w", err)
	}
	return FrameType(hdr[0]), payload, nil
}
