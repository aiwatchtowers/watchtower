//go:build linux

package chat

import (
	"context"
	"os"
	"os/exec"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ownerconfirm"
)

// tokenOf is a token naming pid, as ReadPeerToken builds it off macOS.
func tokenOf(pid int) ownerconfirm.PeerToken {
	var t ownerconfirm.PeerToken
	t[20], t[21], t[22], t[23] = byte(pid), byte(pid>>8), byte(pid>>16), byte(pid>>24)
	return t
}

// TestListen_DefaultVerifyLinux: on linux the real /proc check accepts this
// process (the session's own executable) and refuses another program.
func TestListen_DefaultVerifyLinux(t *testing.T) {
	assert.NoError(t, defaultListenVerify(context.Background(), tokenOf(os.Getpid())))
	cmd := exec.Command("sleep", "30")
	require.NoError(t, cmd.Start())
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	assert.Error(t, defaultListenVerify(context.Background(), tokenOf(cmd.Process.Pid)))
}
