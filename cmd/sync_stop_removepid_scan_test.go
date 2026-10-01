package cmd

import (
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestSyncGo_NoDirectRemovePIDCalls is a property guard against
// reintroducing the F3 bug class from the daemon-pid-reuse backlog item: a
// signal-completion branch in runSyncStop/forceStopSync calling
// daemon.RemovePID directly instead of through reapPIDFile, which defers
// the removal decision to daemon.FindProcess's own re-read — so a fresh
// daemon that claimed the pid file in a race window since the last check
// is never clobbered. Every stop-flow branch now goes through reapPIDFile,
// so there should be no direct daemon.RemovePID( call left in this file at
// all; a future edit reintroducing one should fail this scan immediately
// rather than being caught only by a review of the diff.
func TestSyncGo_NoDirectRemovePIDCalls(t *testing.T) {
	src, err := os.ReadFile("sync.go")
	require.NoError(t, err)

	require.Zero(t, strings.Count(string(src), "daemon.RemovePID("),
		"sync.go must not call daemon.RemovePID directly — every pid-file cleanup must go through reapPIDFile")
}
