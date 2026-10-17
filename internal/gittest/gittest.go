// Package gittest holds test-only setup for packages whose tests create git
// repositories under t.TempDir.
package gittest

import (
	"fmt"
	"os"
	"strconv"
)

// quietConfig turns off the maintenance git may leave running in the
// background, writing into a repository's .git after the command that
// started it returned: `git commit`, `merge`, `fetch` and a push's
// receive-pack run `git maintenance run --auto` / `git gc --auto`, detached
// by default. Still writing while t.TempDir's cleanup removes the repository,
// it fails the test with "directory not empty".
//
// core.fsmonitor stays out on purpose: environment config outranks the
// repository's, so forcing it off here would make the untrusted-config
// tests' planted fsmonitor unreachable and the code under test's own
// `-c core.fsmonitor=false` untested. A test keeps the owner's fsmonitor out
// by isolating the global config (GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM).
var quietConfig = [][2]string{
	{"maintenance.auto", "false"},
	{"gc.auto", "0"},
	{"gc.autoDetach", "false"},
	{"maintenance.autoDetach", "false"},
}

// DisableBackgroundGit adds quietConfig to the process environment through
// GIT_CONFIG_COUNT, so every git the tests start inherits it, unless its
// command sets a GIT_CONFIG_COUNT of its own (the last value wins).
// Environment config outranks the system, global and repository files.
// Entries already in GIT_CONFIG_COUNT are kept. Call it from TestMain before
// m.Run: os.Setenv is not safe once tests run in parallel.
func DisableBackgroundGit() {
	n := 0
	if v := os.Getenv("GIT_CONFIG_COUNT"); v != "" {
		var err error
		if n, err = strconv.Atoi(v); err != nil || n < 0 {
			panic(fmt.Sprintf("gittest: GIT_CONFIG_COUNT=%q is not a count", v))
		}
	}
	for _, kv := range quietConfig {
		mustSetenv(fmt.Sprintf("GIT_CONFIG_KEY_%d", n), kv[0])
		mustSetenv(fmt.Sprintf("GIT_CONFIG_VALUE_%d", n), kv[1])
		n++
	}
	mustSetenv("GIT_CONFIG_COUNT", strconv.Itoa(n))
}

func mustSetenv(k, v string) {
	if err := os.Setenv(k, v); err != nil {
		panic(err)
	}
}
