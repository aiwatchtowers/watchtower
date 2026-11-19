package workbenchgit

import (
	"os"
	"testing"

	"watchtower/internal/gittest"
)

// TestMain keeps git's background maintenance out of the test repositories
// (see gittest.DisableBackgroundGit).
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	localPushTargets = true // the fixtures' origins are bare repositories on disk
	os.Exit(m.Run())
}
