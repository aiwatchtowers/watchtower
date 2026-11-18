package watchmanact

import (
	"os"
	"testing"

	"watchtower/internal/gittest"
)

// TestMain keeps git's background maintenance out of the test repositories
// (the hook tests create them).
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	os.Exit(m.Run())
}
