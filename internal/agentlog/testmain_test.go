package agentlog

import (
	"os"
	"testing"

	"watchtower/internal/gittest"
)

// TestMain keeps git's background maintenance out of the test repositories
// (see gittest.DisableBackgroundGit).
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	os.Exit(m.Run())
}
