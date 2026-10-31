package cmd

import (
	"testing"

	"watchtower/internal/sessionhost"
)

func TestSessionHostCmd_RequiresSocket(t *testing.T) {
	old := flagSessionHostSocket
	t.Cleanup(func() { flagSessionHostSocket = old })
	flagSessionHostSocket = ""
	t.Setenv(sessionhost.SocketEnv, "")
	if err := runSessionHost(sessionHostCmd, nil); err == nil {
		t.Fatal("runSessionHost without --socket: want an error")
	}
}
