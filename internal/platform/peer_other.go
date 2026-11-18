//go:build !darwin && !linux

package platform

import (
	"errors"
	"net"
)

// PeerUID has no peer-credential call here: every client is refused.
func PeerUID(*net.UnixConn) (int, error) {
	return 0, errors.New("platform: socket peer credentials unsupported on this platform")
}

// PeerPID has no peer-credential call here: every client is refused.
func PeerPID(*net.UnixConn) (int, error) {
	return 0, errors.New("platform: socket peer credentials unsupported on this platform")
}

// MaxSocketPath is the conservative sockaddr_un bound (darwin's).
const MaxSocketPath = 103
