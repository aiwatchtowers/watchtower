package ownerconfirm

import "encoding/binary"

// PeerToken is a socket peer's audit token (audit_token_t, eight 32-bit
// words) as the kernel gave it when it was read: it names one process image
// (pid and pidversion), so a check of it fails once that process exec'd.
type PeerToken [32]byte

// PID is the token's process id (audit_token_to_pid: word 5).
func (t PeerToken) PID() int {
	return int(binary.LittleEndian.Uint32(t[20:24]))
}
