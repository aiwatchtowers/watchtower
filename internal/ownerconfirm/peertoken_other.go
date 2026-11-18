//go:build !darwin || !cgo

package ownerconfirm

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"

	"watchtower/internal/platform"
)

// errNoCodeSigning: the Watchtower app and its code signatures exist only
// on macOS (there is no signed app on linux); here every token check fails,
// so the real verifiers refuse every peer.
var errNoCodeSigning = errors.New("code signatures are checked on macOS only")

// ReadPeerToken has no audit token here: the token carries only the peer's
// pid (SO_PEERCRED; PID() reads it), so an injected verifier still knows the
// peer. checkToken never accepts it.
func ReadPeerToken(c net.Conn) (PeerToken, error) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return PeerToken{}, errors.New("not a unix socket")
	}
	pid, err := platform.PeerPID(uc)
	if err != nil {
		return PeerToken{}, fmt.Errorf("the peer: %w", err)
	}
	var t PeerToken
	binary.LittleEndian.PutUint32(t[20:24], uint32(pid))
	return t, nil
}

func checkToken(PeerToken, string) error { return errNoCodeSigning }

func tokenPath(PeerToken) (string, error) { return "", errNoCodeSigning }
