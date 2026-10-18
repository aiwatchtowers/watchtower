package workbenchgit

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fetchedRepo is newRepo with an origin that gained the branch "topic"
// elsewhere, fetched: topic is remote-only.
func fetchedRepo(t *testing.T) string {
	t.Helper()
	dir := newRepo(t)
	elsewhere(t, withOrigin(t, dir))
	require.True(t, Fetch(context.Background(), Options{Folder: dir}, false).Fetched)
	return dir
}

// A remote-only branch checked out is local afterwards, tracking origin's.
func TestProj10_CheckoutMakesALocalTrackingBranch(t *testing.T) {
	dir := fetchedRepo(t)
	res := Checkout(context.Background(), Options{Folder: dir}, SwitchRequest{Branch: "topic"})
	require.True(t, res.Switched, "%+v", res)
	assert.True(t, res.Created)
	assert.Empty(t, res.Refused)
	assert.Equal(t, "topic", res.Status.Branch)
	assert.Equal(t, "origin/topic", res.Status.Upstream)
	assert.Equal(t, "origin", gitIn(t, dir, "config", "branch.topic.remote"))
	assert.Equal(t, "refs/heads/topic", gitIn(t, dir, "config", "branch.topic.merge"))
	l := ListBranches(context.Background(), Options{Folder: dir})
	assert.Empty(t, l.RemoteOnly, "a branch with a local copy is not remote-only")
}

func TestProj10_CheckoutRefusesDirtyWithoutStash(t *testing.T) {
	dir := fetchedRepo(t)
	dirty(t, dir)
	before := snapshot(t, dir)
	rec := &recorder{}
	res := Checkout(context.Background(), options(dir, rec), SwitchRequest{Branch: "topic", AgentRunning: true})
	assert.Equal(t, []string{NeedUncommitted, NeedAgent}, res.NeedsConfirmation)
	assert.False(t, res.Switched)
	assertNoWrites(t, rec)
	assert.Equal(t, before, snapshot(t, dir))
	_, _, err := execRunner(context.Background(), dir, nil, gitBin(t), "rev-parse", "--verify", "-q", "refs/heads/topic")
	assert.Error(t, err, "no local branch is made before the owner confirms")
}

func TestProj10_CheckoutStashesWhatTheOwnerConfirmed(t *testing.T) {
	dir := fetchedRepo(t)
	dirty(t, dir)
	res := Checkout(context.Background(), Options{Folder: dir},
		SwitchRequest{Branch: "topic", Stash: true, AgentRunning: true, ConfirmAgent: true})
	require.True(t, res.Switched, "%+v", res)
	assert.Regexp(t, `^watchtower: switching from main to topic \[[0-9a-f]+\]$`, res.StashMessage)
	assert.NotEmpty(t, res.Stashed)
	assert.Equal(t, 0, res.Status.Changes)
	assert.Contains(t, gitIn(t, dir, "stash", "list"), res.StashMessage, "the entry stays on the stack")
}

func TestProj10_CheckoutRefusesALocalOrUnknownName(t *testing.T) {
	dir := fetchedRepo(t)
	all := SwitchRequest{Stash: true, AgentRunning: true, ConfirmAgent: true}
	for name, want := range map[string]string{
		"main":         RefusedExists,
		"feature":      RefusedExists, // local, its upstream gone
		"nope":         RefusedUnknownBranch,
		"origin/topic": RefusedUnknownBranch,
		"-topic":       RefusedUnknownBranch,
		"":             RefusedUnknownBranch,
	} {
		rec := &recorder{}
		req := all
		req.Branch = name
		res := Checkout(context.Background(), options(dir, rec), req)
		assert.Equal(t, want, res.Refused, name)
		assertNoWrites(t, rec)
	}
}

func TestProj10_CheckoutOperationInProgressIsRefused(t *testing.T) {
	dir := fetchedRepo(t)
	gitIn(t, dir, "switch", "-q", "-c", "side", "feature")
	commit(t, dir, "feature.txt", "side\n", "side")
	gitIn(t, dir, "switch", "-q", "main")
	commit(t, dir, "feature.txt", "main side\n", "main side")
	_, _, err := execRunner(context.Background(), dir, nil, gitBin(t), "merge", "side")
	require.Error(t, err, "the merge must conflict")
	rec := &recorder{}
	res := Checkout(context.Background(), options(dir, rec),
		SwitchRequest{Branch: "topic", Stash: true, AgentRunning: true, ConfirmAgent: true})
	assert.Equal(t, RefusedOperationInProgress, res.Refused)
	assertNoWrites(t, rec)
}

func TestProj10_FailedCheckoutRestoresTheStash(t *testing.T) {
	dir := fetchedRepo(t)
	dirty(t, dir)
	rec := &recorder{fail: "switch"}
	res := Checkout(context.Background(), options(dir, rec), SwitchRequest{Branch: "topic", Stash: true})
	assert.False(t, res.Switched)
	assert.False(t, res.Created)
	assert.NotEmpty(t, res.Error)
	assert.True(t, res.StashRestored, "%+v", res)
	assert.Equal(t, "edited\n", readFile(t, dir, "README.md"))
}

func TestProj10_CheckoutNeverForcesOrFetches(t *testing.T) {
	dir := fetchedRepo(t)
	dirty(t, dir)
	rec := &recorder{}
	res := Checkout(context.Background(), options(dir, rec), SwitchRequest{Branch: "topic", Stash: true})
	require.True(t, res.Switched, "%+v", res)
	for _, c := range rec.argv() {
		assert.NotEqual(t, "fetch", c[0])
		for _, a := range c {
			assert.NotContains(t, []string{"-f", "--force", "--discard-changes", "-C", "--force-create", "--hard", "pop", "drop"}, a, "%v", c)
		}
		if c[0] == "switch" {
			assert.Equal(t, []string{"switch", "--no-guess", "--no-overwrite-ignore", "--track=direct", "-c", "topic", "refs/remotes/origin/topic"}, c)
		}
	}
}
