//go:build darwin

package chat

import (
	"context"

	"watchtower/internal/ownerconfirm"
)

// defaultListenVerify on macOS: the client is this team's watchtower CLI,
// by the audit token read at accept (D17).
func defaultListenVerify(ctx context.Context, t ownerconfirm.PeerToken) error {
	return ownerconfirm.VerifySameTeamCLI(ctx, t)
}
