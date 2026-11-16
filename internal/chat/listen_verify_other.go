//go:build !darwin

package chat

import (
	"context"
	"os"

	"watchtower/internal/ownerconfirm"
)

// defaultListenVerify off macOS (a headless hub host): there is no code
// signature, so the client — already checked to be this user's process —
// must run this session's own executable, by /proc/<pid>/exe of the pid
// the socket credentials gave at accept.
func defaultListenVerify(_ context.Context, t ownerconfirm.PeerToken) error {
	own, err := os.Executable()
	if err != nil {
		return err //nolint:wrapcheck // the client is refused either way
	}
	return sameExecutable("/proc", t.PID(), own)
}
