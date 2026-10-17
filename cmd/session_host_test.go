package cmd

import "testing"

func TestSessionHostCmd_RequiresSocket(t *testing.T) {
	old := flagSessionHostSocket
	t.Cleanup(func() { flagSessionHostSocket = old })
	flagSessionHostSocket = ""
	if err := runSessionHost(sessionHostCmd, nil); err == nil {
		t.Fatal("runSessionHost without --socket: want an error")
	}
}
