//go:build !darwin

package ownerconfirm

import (
	"errors"
	"net"
)

// PeerPID fails off macOS: the Desktop exists only there, so no peer is
// trusted elsewhere.
func PeerPID(net.Conn) (int, error) {
	return 0, errors.New("the Watchtower Desktop runs only on macOS")
}
