//go:build !darwin || !cgo

package ownerconfirm

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Off macOS the token carries the peer's pid only, and every check of it
// refuses: there is no signed app to accept.
func TestPeerTokenOffDarwinCarriesThePIDAndFailsClosed(t *testing.T) {
	dir, err := os.MkdirTemp("", "oct")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	l, err := net.Listen("unix", filepath.Join(dir, "s.sock"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = l.Close() })
	c, err := net.Dial("unix", l.Addr().String())
	require.NoError(t, err)
	t.Cleanup(func() { _ = c.Close() })
	s, err := l.Accept()
	require.NoError(t, err)
	t.Cleanup(func() { _ = s.Close() })

	tok, err := ReadPeerToken(s)
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), tok.PID())
	assert.Error(t, checkToken(tok, "always"))
	assert.Error(t, VerifySameTeamCLI(context.Background(), tok))
	t.Setenv(DevTrustUnsignedEnv, "1")
	assert.Error(t, VerifyDesktopPeer(context.Background(), tok))
}
