package extsync

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A child listing that comes back empty while the pages stay listed (a
// lagging search index, a renamed key) is not proof of deletion: only the
// children confirmed gone one by one are deleted.
func TestReconcileEmptyChildListingDeletesOnlyConfirmedGone(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Now().UTC().Truncate(time.Second).Add(-30 * 24 * time.Hour)
	old := now.Add(-time.Hour)
	f.addPage("p1", 1, old)
	for i := range 4 {
		f.addAttachment(fmt.Sprintf("a%d", i), "p1", 1, old, fmt.Sprintf("n%d.txt", i), "text/plain", []byte("x"), -1)
		f.addComment(fmt.Sprintf("c%d", i), "p1", 1, old, fmt.Sprintf("c%d", i))
	}
	e := New(d, Options{Now: func() time.Time { return now }, Extractor: newFakeExtractor()})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	for i := range 4 {
		f.removeFromAll(fmt.Sprintf("a%d", i))
		f.removeFromAll(fmt.Sprintf("c%d", i))
	}
	f.markGone("a3", 1, old) // really deleted: Fetch reports it gone
	f.deleteComment("c3")    // really deleted: its page's Comments no longer has it
	now = now.Add(24 * time.Hour)
	st, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"a0", "a1", "a2", "p1"}, docIDs(t, d, src.ID))
	assert.Equal(t, []string{"c0", "c1", "c2"}, commentTexts(t, d, src.ID, "p1"))
	assert.Equal(t, 1, st.Deleted)
	assert.NotEmpty(t, loadSource(t, d).LastReconcileAt, "a guarded reconcile still completes")
}

// A verification that fails for itself keeps what it was checking and
// does not block the reconcile's other deletions.
func TestReconcileGuardVerificationFailureKeeps(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Now().UTC().Truncate(time.Second).Add(-30 * 24 * time.Hour)
	old := now.Add(-time.Hour)
	f.addPage("p1", 1, old)
	f.addPage("p2", 1, old)
	for i := range 2 {
		f.addAttachment(fmt.Sprintf("a%d", i), "p1", 1, old, fmt.Sprintf("n%d.txt", i), "text/plain", []byte("x"), -1)
	}
	e := New(d, Options{Now: func() time.Time { return now }, Extractor: newFakeExtractor()})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	f.removeFromAll("a0")
	f.removeFromAll("a1")
	f.markGone("a1", 1, old)
	f.fetchErr["a0"] = errors.New("502: bad gateway")
	f.removeFromAll("p2")
	now = now.Add(24 * time.Hour)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"a0", "p1"}, docIDs(t, d, src.ID), "a0 kept unverified, a1 and p2 deleted")
}

// A listing that lacks only a minority of the stored children is trusted:
// they are deleted without a per-item check.
func TestReconcileSmallChildDropIsTrusted(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Now().UTC().Truncate(time.Second).Add(-30 * 24 * time.Hour)
	old := now.Add(-time.Hour)
	f.addPage("p1", 1, old)
	for i := range 4 {
		f.addAttachment(fmt.Sprintf("a%d", i), "p1", 1, old, fmt.Sprintf("n%d.txt", i), "text/plain", []byte("x"), -1)
	}
	e := New(d, Options{Now: func() time.Time { return now }, Extractor: newFakeExtractor()})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	f.removeFromAll("a0")
	now = now.Add(24 * time.Hour)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"a1", "a2", "a3", "p1"}, docIDs(t, d, src.ID))
	assert.Equal(t, 1, f.fetchCount("a0"), "no verification Fetch for a trusted listing")
}

// Children of a page the listing dropped go with it, unverified, however
// many they are: the permission model is not weakened by the guard.
func TestReconcileOrphanChildrenGoWithTheirPage(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Now().UTC().Truncate(time.Second).Add(-30 * 24 * time.Hour)
	old := now.Add(-time.Hour)
	f.addPage("p1", 1, old)
	f.addPage("p2", 1, old)
	for i := range 3 {
		id := fmt.Sprintf("a%d", i)
		f.addAttachment(id, "p2", 1, old, id+".txt", "text/plain", []byte("x"), -1)
	}
	e := New(d, Options{Now: func() time.Time { return now }, Extractor: newFakeExtractor()})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	for _, id := range []string{"p2", "a0", "a1", "a2"} {
		f.removeFromAll(id) // the owner lost access to p2
	}
	now = now.Add(24 * time.Hour)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"p1"}, docIDs(t, d, src.ID))
	for i := range 3 {
		assert.Equal(t, 1, f.fetchCount(fmt.Sprintf("a%d", i)), "an orphan is not verified")
	}
}

// With more suspect children than the cap, each reconcile verifies a
// different window of them, so a deleted one among many still present is
// found within a few days.
func TestReconcileVerifySampleRotatesByDay(t *testing.T) {
	prev := reconcileVerifyCap
	reconcileVerifyCap = 1
	t.Cleanup(func() { reconcileVerifyCap = prev })
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Now().UTC().Truncate(time.Second).Add(-30 * 24 * time.Hour)
	old := now.Add(-time.Hour)
	f.addPage("p1", 1, old)
	for i := range 3 {
		id := fmt.Sprintf("a%d", i)
		f.addAttachment(id, "p1", 1, old, id+".txt", "text/plain", []byte("x"), -1)
	}
	e := New(d, Options{Now: func() time.Time { return now }, Extractor: newFakeExtractor()})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	for i := range 3 {
		f.removeFromAll(fmt.Sprintf("a%d", i))
	}
	f.markGone("a1", 1, old)
	for range 3 {
		now = now.Add(24 * time.Hour)
		_, err = e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, []string{"a0", "a2", "p1"}, docIDs(t, d, src.ID))
}

// A renamed container key is picked up from Containers (by the stable ext
// id) before the reconcile enumerates, and stored on the source.
func TestReconcileRefreshesRenamedContainerKey(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Now().UTC().Truncate(time.Second).Add(-30 * 24 * time.Hour)
	f.addPage("p1", 1, now.Add(-time.Hour))
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	f.mu.Lock()
	f.containers = []Container{{Key: "OTHER", Name: "Other", ExtID: "9"}, {Key: "ENG2", Name: "Engineering 2", ExtID: "1"}}
	f.allKeys = nil
	f.mu.Unlock()
	now = now.Add(24 * time.Hour)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	stored := loadSource(t, d)
	assert.Equal(t, "ENG2", stored.ContainerKey)
	assert.Equal(t, "Engineering 2", stored.ContainerName)
	f.mu.Lock()
	keys := append([]string(nil), f.allKeys...)
	f.mu.Unlock()
	require.NotEmpty(t, keys)
	for _, k := range keys {
		assert.Equal(t, "ENG2", k, "the enumeration uses the new key")
	}
	assert.Equal(t, []string{"p1"}, docIDs(t, d, src.ID))
}

// A container the account no longer sees keeps its stored key.
func TestReconcileKeepsKeyOfUnlistedContainer(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	f.containers = []Container{{Key: "OTHER", Name: "Other", ExtID: "9"}}
	now := time.Now().UTC().Truncate(time.Second)
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "ENG", loadSource(t, d).ContainerKey)
}

func TestAbsentChildren(t *testing.T) {
	parents := map[string]ItemRef{"p1": {}}
	stored := []storedChild{{"a", "p1"}, {"b", "p1"}, {"c", "p1"}, {"d", "p1"}, {"x", "gone"}}
	listed := func(ids ...string) map[string]ItemRef {
		m := map[string]ItemRef{}
		for _, id := range ids {
			m[id] = ItemRef{}
		}
		return m
	}
	cands, suspect := absentChildren(stored, listed("a", "b", "c"), parents)
	assert.Equal(t, []storedChild{{"d", "p1"}}, cands)
	assert.False(t, suspect)
	cands, suspect = absentChildren(stored, listed("a", "b"), parents)
	assert.Len(t, cands, 2)
	assert.False(t, suspect, "exactly half is not more than half")
	_, suspect = absentChildren(stored, listed("a"), parents)
	assert.True(t, suspect)
	_, suspect = absentChildren([]storedChild{{"a", "p1"}}, listed(), parents)
	assert.True(t, suspect, "an empty listing is suspect however few are stored")
	cands, _ = absentChildren([]storedChild{{"x", "gone"}}, listed(), parents)
	assert.Empty(t, cands, "an orphan is never a candidate")
}
