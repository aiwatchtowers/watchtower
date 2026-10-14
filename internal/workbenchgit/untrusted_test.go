package workbenchgit

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// plantFSMonitor points the repository's own config at an fsmonitor
// command that leaves a marker file when git runs it, and returns the
// marker's path.
func plantFSMonitor(t *testing.T, dir string) string {
	t.Helper()
	marker := filepath.Join(t.TempDir(), "fsmonitor-ran")
	hook := filepath.Join(t.TempDir(), "fsmonitor")
	require.NoError(t, os.WriteFile(hook, []byte("#!/bin/sh\ntouch '"+marker+"'\nexit 1\n"), 0o755))
	gitIn(t, dir, "config", "core.fsmonitor", hook)
	return marker
}

// A planted .git/config never runs a command: neither the background reads
// nor the owner's confirmed switch (its stash included) run the folder's
// fsmonitor, and the results are what they were.
func TestUntrustedConfig_NoFSMonitorCommandRuns(t *testing.T) {
	dir := newRepo(t)
	marker := plantFSMonitor(t, dir)
	dirty(t, dir)

	st := ReadStatus(context.Background(), options(dir, &recorder{}))
	require.True(t, st.Git, "%+v", st)
	assert.True(t, st.Dirty)
	_, err := ListFiles(context.Background(), Options{Folder: dir})
	require.NoError(t, err)
	res := Switch(context.Background(), options(dir, &recorder{}), SwitchRequest{Branch: "feature", Stash: true})
	require.True(t, res.Switched, "%+v", res)

	_, statErr := os.Stat(marker)
	assert.True(t, os.IsNotExist(statErr), "the folder's fsmonitor command ran")
}

// Background reads run no hook of the folder's; the owner's confirmed
// switch, its stash and its restore keep the repository's hooks, as a
// terminal would (PROJ-10's failing-hook rule depends on it).
func TestExecRunner_HooksOnlyForTheOwnersWrites(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "git")
	require.NoError(t, os.WriteFile(bin, []byte("#!/bin/sh\necho \"$*\"\n"), 0o755))
	const read = "-c core.fsmonitor=false -c core.hooksPath=/dev/null -c log.showSignature=false "
	const owner = "-c core.fsmonitor=false "
	for _, tc := range []struct{ args, want string }{
		{"status --porcelain=v2", read},
		{"stash list --format=%H", read},
		{"for-each-ref refs/heads/", read},
		{"switch --no-guess feature", owner},
		{"switch -c topic", owner},
		{"stash push --include-untracked -m m", owner},
		{"stash apply --index abc", owner},
	} {
		out, _, err := execRunner(context.Background(), t.TempDir(), nil, bin, strings.Fields(tc.args)...)
		require.NoError(t, err)
		assert.Equal(t, tc.want+tc.args, strings.TrimSpace(string(out)), tc.args)
	}
}

// A filter driver named in the folder's own config (with the repository's
// .gitattributes pointing every file at it) never runs from a background
// read: status hashes the edited file without it, and the read answers.
func TestUntrustedConfig_NoFilterDriverRuns(t *testing.T) {
	dir := newRepo(t)
	marker := filepath.Join(t.TempDir(), "filter-ran")
	script := filepath.Join(t.TempDir(), "planted")
	require.NoError(t, os.WriteFile(script, []byte("#!/bin/sh\ntouch '"+marker+"'\ncat\n"), 0o755))
	gitIn(t, dir, "config", "filter.planted.clean", script)
	gitIn(t, dir, "config", "filter.planted.process", script)
	gitIn(t, dir, "config", "filter.planted.required", "true")
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".git", "info", "attributes"), []byte("* filter=planted\n"), 0o644))
	// Same size as the committed "hello\n": only hashing the content (the
	// clean filter's moment) tells it changed.
	writeFile(t, dir, "README.md", "HELLO\n")

	st := ReadStatus(context.Background(), Options{Folder: dir})
	require.True(t, st.Git, "%+v", st)
	assert.True(t, st.Dirty)
	_, err := ListFiles(context.Background(), Options{Folder: dir})
	require.NoError(t, err)

	_, statErr := os.Stat(marker)
	assert.True(t, os.IsNotExist(statErr), "the folder's filter driver ran")
}
