// Package gittest holds test-only setup for packages whose tests create git
// repositories under t.TempDir.
package gittest

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
	mustSetenv("GIT_TEMPLATE_DIR", quietTemplateDir())
}

// quietTemplateDir is a git template directory whose config file carries
// quietConfig plus receive.autoGC=false; `git init` copies it into every
// repository the tests create (GIT_TEMPLATE_DIR). The environment config
// alone does not reach a bare remote: a local push runs receive-pack with
// GIT_CONFIG_COUNT stripped (git's local_repo_env), and its receive.autoGC
// would start a detached gc/maintenance in the remote (#684). The directory
// is named by its content and shared by the test binaries; it is written
// to a temp sibling and renamed into place, so a reader never sees it half
// written.
func quietTemplateDir() string {
	var b strings.Builder
	for _, kv := range append(quietConfig, [2]string{"receive.autoGC", "false"}) {
		section, key, _ := strings.Cut(kv[0], ".")
		fmt.Fprintf(&b, "[%s]\n\t%s = %s\n", section, key, kv[1])
	}
	content := b.String()
	// The layout tag is part of the name, so a changed layout gets its own
	// directory instead of reusing an older one.
	sum := sha256.Sum256([]byte("config+info/exclude+hooks/\n" + content))
	dir := filepath.Join(os.TempDir(), "watchtower-gittest-template-"+hex.EncodeToString(sum[:6]))
	if _, err := os.Stat(filepath.Join(dir, "config")); err == nil {
		return dir
	}
	tmp, err := os.MkdirTemp(os.TempDir(), "watchtower-gittest-template-*")
	if err != nil {
		panic(err)
	}
	// info/ and hooks/ as git's default template has them: tests write
	// .git/info/attributes or a hook straight into a fresh repository.
	for _, sub := range []string{"info", "hooks"} {
		if err := os.Mkdir(filepath.Join(tmp, sub), 0o700); err != nil {
			panic(err)
		}
	}
	if err := os.WriteFile(filepath.Join(tmp, "info", "exclude"), []byte("# git ls-files --others --exclude-from=.git/info/exclude\n"), 0o600); err != nil {
		panic(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "config"), []byte(content), 0o600); err != nil {
		panic(err)
	}
	if err := os.Rename(tmp, dir); err != nil {
		// Another test binary renamed its copy into place first.
		_ = os.RemoveAll(tmp)
		if _, statErr := os.Stat(filepath.Join(dir, "config")); statErr != nil {
			panic(fmt.Sprintf("gittest: installing the git template dir: %v", err))
		}
	}
	return dir
}

func mustSetenv(k, v string) {
	if err := os.Setenv(k, v); err != nil {
		panic(err)
	}
}
