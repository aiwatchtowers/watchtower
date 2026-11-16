package sessioncleanup

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/gittest"
)

// TestMain keeps the owner's git configuration out of the test
// repositories (every git run inherits this environment), so the tests can
// run in parallel without t.Setenv.
//
// It also turns off git's background maintenance (see
// gittest.DisableBackgroundGit).
//
// It installs the db schema template cache too: the DBStore tests open
// in-memory databases.
func TestMain(m *testing.M) {
	for k, v := range map[string]string{
		"GIT_CONFIG_GLOBAL": os.DevNull, "GIT_CONFIG_NOSYSTEM": "1",
		"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
		"GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
	} {
		if err := os.Setenv(k, v); err != nil {
			panic(err)
		}
	}
	gittest.DisableBackgroundGit()
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
