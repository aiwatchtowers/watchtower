package workbenchfolders

import (
	"os"
	"testing"

	"watchtower/internal/gittest"
)

// TestMain keeps git's background maintenance out of the repositories the
// tests create (gittest.DisableBackgroundGit).
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	os.Exit(m.Run())
}
