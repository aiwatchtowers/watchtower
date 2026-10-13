package sessioncleanup

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain keeps the owner's git configuration out of the test
// repositories (every git run inherits this environment), so the tests can
// run in parallel without t.Setenv.
//
// It also turns off git's auto maintenance: `git commit` (and other writing
// commands) otherwise starts a detached `git maintenance run --auto
// --detach` that outlives the test and writes into the repository's .git
// while t.TempDir's cleanup removes it ("directory not empty", #535).
//
// It installs the db schema template cache too: the DBStore tests open
// in-memory databases.
func TestMain(m *testing.M) {
	for k, v := range map[string]string{
		"GIT_CONFIG_GLOBAL": os.DevNull, "GIT_CONFIG_NOSYSTEM": "1",
		"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
		"GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
		"GIT_CONFIG_COUNT": "4",
		"GIT_CONFIG_KEY_0": "maintenance.auto", "GIT_CONFIG_VALUE_0": "false",
		"GIT_CONFIG_KEY_1": "gc.auto", "GIT_CONFIG_VALUE_1": "0",
		"GIT_CONFIG_KEY_2": "gc.autoDetach", "GIT_CONFIG_VALUE_2": "false",
		"GIT_CONFIG_KEY_3": "core.fsmonitor", "GIT_CONFIG_VALUE_3": "false",
	} {
		if err := os.Setenv(k, v); err != nil {
			panic(err)
		}
	}
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
