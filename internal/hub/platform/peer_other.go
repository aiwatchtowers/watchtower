//go:build !darwin && !linux

package platform

import (
	"errors"
	"net"
)

// PeerUID has no peer-credential call here: every client is refused.
func PeerUID(*net.UnixConn) (int, error) {
	return 0, errors.New("hub: socket peer credentials unsupported on this platform")
}
