package workbenchgit

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// withOrigin gives newRepo a bare repository as origin, with main and
// feature pushed and tracked, and returns the origin's path.
func withOrigin(t *testing.T, dir string) string {
	t.Helper()
	origin, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	gitIn(t, origin, "init", "-q", "--bare", "-b", "main")
	gitIn(t, dir, "remote", "add", "origin", origin)
	gitIn(t, dir, "push", "-q", "-u", "origin", "main", "feature")
	return origin
}

// elsewhere is another clone of origin that pushes: a commit on main, a
// new branch "topic", and feature deleted.
func elsewhere(t *testing.T, origin string) {
	t.Helper()
	parent, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	gitIn(t, parent, "clone", "-q", origin, "other")
	other := filepath.Join(parent, "other")
	commit(t, other, "later.txt", "later\n", "later")
	gitIn(t, other, "push", "-q", "origin", "main")
	gitIn(t, other, "switch", "-q", "-c", "topic")
	commit(t, other, "topic.txt", "topic\n", "topic")
	gitIn(t, other, "push", "-q", "origin", "topic", ":feature")
}

// marker is a script that leaves a file when it runs, and that file's path.
func marker(t *testing.T, name string) (script, ran string) {
	t.Helper()
	dir := t.TempDir()
	ran = filepath.Join(dir, name+"-ran")
	script = filepath.Join(dir, name)
	require.NoError(t, os.WriteFile(script, []byte("#!/bin/sh\ntouch '"+ran+"'\nexit 1\n"), 0o755))
	return script, ran
}

func assertNotRan(t *testing.T, ran string) {
	t.Helper()
	_, err := os.Stat(ran)
	assert.True(t, os.IsNotExist(err), "%s ran", filepath.Base(ran))
}

func findBranchIn(t *testing.T, l BranchList, name string) Branch {
	t.Helper()
	b, ok := findBranch(l.Branches, name)
	require.True(t, ok, "no local branch %s in %+v", name, l.Branches)
	return b
}

func TestFetch_UpdatesTheCountersAndNeverTheWorkTree(t *testing.T) {
	dir := newRepo(t)
	elsewhere(t, withOrigin(t, dir))
	dirty(t, dir)
	before := snapshot(t, dir)

	l := ListBranches(context.Background(), Options{Folder: dir})
	assert.Equal(t, 0, findBranchIn(t, l, "main").Behind, "not fetched yet")
	assert.False(t, findBranchIn(t, l, "feature").UpstreamGone)
	assert.Empty(t, l.RemoteOnly)

	start := time.Now().UTC()
	res := Fetch(context.Background(), Options{Folder: dir})
	require.True(t, res.Fetched, "%+v", res)
	assert.Empty(t, res.Error)
	assert.Equal(t, "origin", res.Remote)
	require.NotNil(t, res.FetchedAt)
	assert.False(t, res.FetchedAt.Before(start.Truncate(time.Second)))

	l = ListBranches(context.Background(), Options{Folder: dir})
	assert.Equal(t, 1, findBranchIn(t, l, "main").Behind)
	assert.True(t, findBranchIn(t, l, "feature").UpstreamGone, "--prune drops the deleted branch")
	require.Len(t, l.RemoteOnly, 1, "%+v", l.RemoteOnly)
	assert.Equal(t, RemoteBranch{Name: "topic", Ref: "origin/topic", Head: l.RemoteOnly[0].Head,
		CommittedAt: l.RemoteOnly[0].CommittedAt}, l.RemoteOnly[0])
	assert.Len(t, l.RemoteOnly[0].Head, shortHash)
	assert.Empty(t, l.RemoteOnlyError)
	assert.Equal(t, before, snapshot(t, dir), "a fetch touches no file, branch or stash")
}

func TestFetch_NoOriginRunsNoFetch(t *testing.T) {
	dir := newRepo(t)
	rec := &recorder{}
	res := Fetch(context.Background(), options(dir, rec))
	assert.True(t, res.Git)
	assert.True(t, res.NoRemote)
	assert.False(t, res.Fetched)
	assert.Empty(t, res.Error)
	assert.False(t, rec.ran("fetch"))
}

func TestFetch_OutsideARepositoryRunsNoGit(t *testing.T) {
	gitBin(t)
	rec := &recorder{}
	res := Fetch(context.Background(), options(t.TempDir(), rec))
	assert.False(t, res.Git)
	assert.NotEmpty(t, res.Note)
	assert.Empty(t, rec.argv())
}

// An unreachable ssh remote fails fast and quietly: ssh runs in batch mode,
// and the folder's own ssh and askpass commands never run.
func TestFetch_UnreachableRemoteRunsNoFolderCommand(t *testing.T) {
	dir := newRepo(t)
	gitIn(t, dir, "remote", "add", "origin", "ssh://127.0.0.1:1/repo.git")
	ssh, sshRan := marker(t, "ssh")
	askpass, askpassRan := marker(t, "askpass")
	gitIn(t, dir, "config", "core.sshCommand", ssh)
	gitIn(t, dir, "config", "core.askPass", askpass)
	t.Setenv("SSH_ASKPASS", askpass)

	res := Fetch(context.Background(), Options{Folder: dir})
	assert.False(t, res.Fetched)
	assert.False(t, res.TimedOut)
	assert.NotEmpty(t, res.Error)
	assert.Nil(t, res.FetchedAt)
	assertNotRan(t, sshRan)
	assertNotRan(t, askpassRan)
}

// A remote that asks for credentials gets none: no credential helper — the
// folder's or the owner's global one (osxkeychain would read the
// Keychain) — and no askpass; git fails with its own words.
func TestFetch_AuthenticationRunsNoHelperOrPrompt(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("WWW-Authenticate", `Basic realm="test"`)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(srv.Close)
	dir := newRepo(t)
	gitIn(t, dir, "remote", "add", "origin", srv.URL+"/repo.git")
	local, localRan := marker(t, "local-helper")
	global, globalRan := marker(t, "global-helper")
	askpass, askpassRan := marker(t, "askpass")
	gitIn(t, dir, "config", "credential.helper", local)
	gitIn(t, dir, "config", "core.askPass", askpass)
	globalConfig := filepath.Join(t.TempDir(), "gitconfig")
	require.NoError(t, os.WriteFile(globalConfig, []byte("[credential]\n\thelper = "+global+"\n"), 0o644))
	t.Setenv("GIT_CONFIG_GLOBAL", globalConfig)
	t.Setenv("GIT_ASKPASS", askpass)

	res := Fetch(context.Background(), Options{Folder: dir})
	assert.False(t, res.Fetched)
	assert.Contains(t, res.Error, "terminal prompts disabled")
	assertNotRan(t, localRan)
	assertNotRan(t, globalRan)
	assertNotRan(t, askpassRan)
}

// A path remote's upload-pack is git's own, never one the folder names.
func TestFetch_PathRemoteRunsNoFolderUploadPack(t *testing.T) {
	dir := newRepo(t)
	withOrigin(t, dir)
	pack, packRan := marker(t, "upload-pack")
	gitIn(t, dir, "config", "remote.origin.uploadpack", pack)
	res := Fetch(context.Background(), Options{Folder: dir})
	assert.True(t, res.Fetched, "%+v", res)
	assertNotRan(t, packRan)
}

// A remote that never answers is cut off at the deadline as timed out.
func TestFetch_TimeoutIsReported(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(release) }) // runs before srv.Close
	dir := newRepo(t)
	gitIn(t, dir, "remote", "add", "origin", srv.URL+"/repo.git")

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	start := time.Now()
	res := Fetch(ctx, Options{Folder: dir})
	assert.Less(t, time.Since(start), 5*time.Second, "the whole process group is killed at the deadline")
	assert.True(t, res.TimedOut, "%+v", res)
	assert.False(t, res.Fetched)
	assert.Equal(t, "git fetch timed out", res.Error)
}
