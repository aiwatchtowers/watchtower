//go:build !darwin && !linux

package hub

import (
	"errors"
	"net"
)

// socketPeerUID has no peer-credential call here: every client is refused.
func socketPeerUID(*net.UnixConn) (int, error) {
	return 0, errors.New("hub: control socket peer credentials unsupported on this platform")
}
