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

// Protocol v2 frame types. InputTo, Deliver and PromptHint never bind the
// connection to a session; Deliver/Delivered, DeliverCheck/DeliverCheckReply
// and DeliveryEvent are declared for the typed-never-submitted delivery and
// not served yet (an unknown frame is skipped).
const (
	InputTo           FrameType = 0x08
	Deliver           FrameType = 0x09
	Delivered         FrameType = 0x89
	DeliverCheck      FrameType = 0x8A
	DeliverCheckReply FrameType = 0x0A
	PromptHint        FrameType = 0x0B
	DeliveryEvent     FrameType = 0x8B
	Stop              FrameType = 0x0C
	Stopping          FrameType = 0x8C
)

// ProtocolVersion is the protocol version this host speaks. The protocol
// only grows additively: a v2 host accepts v1 and v2 hellos and answers
// with ProtocolVersion.
const ProtocolVersion = 2

// minProtocolVersion is the oldest client hello the host accepts.
const minProtocolVersion = 1

// HelloMsg is the payload of Hello (client: version) and HelloOK (host:
// version and pid).
type HelloMsg struct {
	Version int `json:"version"`
	Pid     int `json:"pid,omitempty"`
}

// ErrorMsg is the payload of an Error frame.
type ErrorMsg struct {
	Message string `json:"message"`
}

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
	// Scope names the app-side namespace of Row (the workspace whose
	// database the row lives in); stored and listed back unchanged.
	Scope string `json:"scope"`
	// Agent is "claude", "codex" or "" (a shell); stored and listed back.
	Agent string `json:"agent,omitempty"`
	// Detach launches without binding this connection to the session (the
	// hub never attaches; Desktop's pane does).
	Detach bool `json:"detach,omitempty"`
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
	// Scope is the launch's LaunchReq.Scope.
	Scope string `json:"scope"`
	// Launch is the host's per-row launch counter: 1 for the row's first
	// launch in this host, one more for each later one, whatever client
	// asked. InputTo and Stop name it, so a line never reaches a newer run.
	Launch uint64 `json:"launch,omitempty"`
	// Agent is the launch's LaunchReq.Agent.
	Agent string `json:"agent,omitempty"`
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
// killed by a signal. Requested is set only when the exit followed a Stop
// request (the owner stopped the session); a natural exit never carries it.
type ExitMsg struct {
	Code      *int `json:"code"`
	Requested bool `json:"requested,omitempty"`
}

// InputToReq writes Data to a session's PTY without binding the connection.
// Row, Run and Launch must all match a running session.
type InputToReq struct {
	Row    int64  `json:"row"`
	Run    string `json:"run"`
	Launch uint64 `json:"launch"`
	Data   []byte `json:"data"`
}

// PromptHintMsg tells the host whether a permission dialog is up in a
// session (a client that reads hook state knows; the host cannot).
type PromptHintMsg struct {
	Row    int64  `json:"row"`
	Run    string `json:"run"`
	Dialog bool   `json:"dialog"`
}

// StoppingMsg is the payload of a Stopping frame. AlreadyExited: the run had
// already exited, nothing was signalled, and its Exit carries no Requested.
type StoppingMsg struct {
	AlreadyExited bool `json:"already_exited,omitempty"`
}

// StopReq asks the host to stop a session: SIGHUP to its process group, then
// SIGKILL after stopGrace. The run's Exit then carries Requested.
type StopReq struct {
	Row    int64  `json:"row"`
	Run    string `json:"run"`
	Launch uint64 `json:"launch"`
}

// WriteFrame writes one frame: type, big-endian uint32 length, payload.
func WriteFrame(w io.Writer, t FrameType, payload []byte) error {
	if len(payload) > MaxPayload {
		return ErrFrameTooLarge
	}
	buf := make([]byte, 5+len(payload))
	buf[0] = byte(t)
	binary.BigEndian.PutUint32(buf[1:5], uint32(len(payload))) // bounded by MaxPayload above
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
