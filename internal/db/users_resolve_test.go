package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestResolveSlackUserID_NamespacesBareInput is the point of the helper: the id
// an operator reads off the Slack UI is bare, and since migration 00048 a bare
// id matches no column in this database. Resolving it against users.id turns
// what a human can see into what every reader compares against.
func TestResolveSlackUserID_NamespacesBareInput(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUser(User{ID: "1:U0123ABCD", Name: "alice"}))

	got, err := d.ResolveSlackUserID("U0123ABCD")
	require.NoError(t, err)
	assert.Equal(t, "1:U0123ABCD", got)
}

// A non-1 account id is the case a hardcoded "1:" prefix gets wrong: slack
// remove is non-destructive, so an install that removed its first workspace
// and added another has exactly one usable account whose id is 2.
func TestResolveSlackUserID_UsesTheAccountTheUserActuallyBelongsTo(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUser(User{ID: "2:U0123ABCD", Name: "alice"}))

	got, err := d.ResolveSlackUserID("U0123ABCD")
	require.NoError(t, err)
	assert.Equal(t, "2:U0123ABCD", got, "the prefix must come from the matched row, never be assumed")
}

// An already-namespaced id needs no interpretation and must survive unchanged —
// otherwise re-running a mapping would double-prefix it.
func TestResolveSlackUserID_PassesThroughExactMatch(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUser(User{ID: "1:U0123ABCD", Name: "alice"}))

	got, err := d.ResolveSlackUserID("1:U0123ABCD")
	require.NoError(t, err)
	assert.Equal(t, "1:U0123ABCD", got)
}

// An id naming nobody is refused rather than stored: a mapping row nothing can
// join is invisible to every reader, so the failure has to be loud at write
// time or it is never seen at all.
func TestResolveSlackUserID_RefusesUnknownID(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUser(User{ID: "1:U0123ABCD", Name: "alice"}))

	_, err := d.ResolveSlackUserID("UNOBODY")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "UNOBODY")
}

// A namespaced input that misses names a specific account's row. Re-pointing it
// at another account's row with the same raw id would attribute one
// workspace's person to another — so it is refused, not silently remapped.
func TestResolveSlackUserID_RefusesNamespacedMissEvenWhenRawIDExists(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUser(User{ID: "2:U0123ABCD", Name: "alice"}))

	_, err := d.ResolveSlackUserID("1:U0123ABCD")
	require.Error(t, err)
}

// The same raw id under two connected workspaces is genuinely ambiguous;
// guessing would attach one org's identity to the other's person.
func TestResolveSlackUserID_RefusesAmbiguousBareID(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUser(User{ID: "1:U0123ABCD", Name: "alice"}))
	require.NoError(t, d.UpsertUser(User{ID: "2:U0123ABCD", Name: "alice2"}))

	_, err := d.ResolveSlackUserID("U0123ABCD")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "1:U0123ABCD")
	assert.Contains(t, err.Error(), "2:U0123ABCD")
}

// A prefix of a real id must not resolve: the raw part is compared whole, so a
// typo cannot silently land on someone else's row.
func TestResolveSlackUserID_RefusesPartialID(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUser(User{ID: "1:U0123ABCD", Name: "alice"}))

	_, err := d.ResolveSlackUserID("U0123")
	require.Error(t, err)
}

// A LIKE wildcard is data, not a pattern — the raw ids are split in Go for
// exactly this reason.
func TestResolveSlackUserID_TreatsWildcardsAsLiteralText(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUser(User{ID: "1:U0123ABCD", Name: "alice"}))

	_, err := d.ResolveSlackUserID("U%")
	require.Error(t, err)
}

// The degenerate input: nothing typed at all.
func TestResolveSlackUserID_RefusesEmptyInput(t *testing.T) {
	d := openTestDB(t)

	_, err := d.ResolveSlackUserID("   ")
	require.Error(t, err)
}
