//go:build !darwin

package ownerconfirm

import (
	"errors"
	"net"
)

// PeerPID: the Desktop exists only on macOS; elsewhere no peer is trusted.
func PeerPID(net.Conn) (int, error) {
	return 0, errors.New("the Watchtower Desktop runs only on macOS")
}
