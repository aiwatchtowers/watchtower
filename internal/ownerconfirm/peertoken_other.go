//go:build !darwin || !cgo

package ownerconfirm

import (
	"errors"
	"net"
)

// errNoCodeSigning: the Watchtower app and its code signatures exist only
// on macOS; elsewhere no peer is trusted.
var errNoCodeSigning = errors.New("code signatures are checked on macOS only")

// ReadPeerToken has no audit token here: every peer is refused.
func ReadPeerToken(net.Conn) (PeerToken, error) { return PeerToken{}, errNoCodeSigning }

func checkToken(PeerToken, string) error { return errNoCodeSigning }

func tokenPath(PeerToken) (string, error) { return "", errNoCodeSigning }
