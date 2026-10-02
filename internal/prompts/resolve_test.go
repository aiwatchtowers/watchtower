package prompts

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestResolve_NilStoreReturnsDefault(t *testing.T) {
	tmpl, version, err := Resolve(nil, DigestChannel, "")
	require.NoError(t, err)
	assert.Equal(t, Defaults[DigestChannel], tmpl)
	assert.Equal(t, 0, version)
}

func TestResolve_StoreRowWins(t *testing.T) {
	database := openTestDB(t)
	store := New(database, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(CatchupCompose, "custom %s", "test"))

	tmpl, version, err := Resolve(store, CatchupCompose, "")
	require.NoError(t, err)
	assert.Equal(t, "custom %s", tmpl)
	assert.Greater(t, version, DefaultVersions[CatchupCompose])
}

func TestResolve_MissingRowReturnsDefault(t *testing.T) {
	store := New(openTestDB(t), nil) // not seeded: no rows at all

	tmpl, version, err := Resolve(store, MeetingRecap, "")
	require.NoError(t, err)
	assert.Equal(t, Defaults[MeetingRecap], tmpl)
	assert.Equal(t, 0, version)
}

func TestResolve_EmptyStoredTemplateReturnsDefault(t *testing.T) {
	database := openTestDB(t)
	require.NoError(t, database.UpsertPrompt(db.Prompt{ID: MeetingNotes, Template: "", Version: 7}))

	tmpl, version, err := Resolve(New(database, nil), MeetingNotes, "")
	require.NoError(t, err)
	assert.Equal(t, Defaults[MeetingNotes], tmpl)
	assert.Equal(t, 0, version)
}

func TestResolve_RoleVariantRowWins(t *testing.T) {
	database := openTestDB(t)
	require.NoError(t, database.UpsertPrompt(db.Prompt{ID: BriefingDaily + "_top_management", Template: "variant", Version: 3}))
	store := New(database, nil)

	tmpl, version, err := Resolve(store, BriefingDaily, "top_management")
	require.NoError(t, err)
	assert.Equal(t, "variant", tmpl)
	assert.Equal(t, 3, version)

	// No role: the variant row is never consulted.
	tmpl, _, err = Resolve(store, BriefingDaily, "")
	require.NoError(t, err)
	assert.Equal(t, Defaults[BriefingDaily], tmpl)
}

func TestResolve_ReadErrorReturnsDefaultAndError(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	store := New(database, nil)
	require.NoError(t, database.Close()) // every read now fails

	tmpl, version, err := Resolve(store, DigestDaily, "")
	require.Error(t, err)
	assert.Equal(t, Defaults[DigestDaily], tmpl, "a failed read still hands back the built-in default")
	assert.Equal(t, 0, version)
}

func TestWithRoleInstruction(t *testing.T) {
	assert.Equal(t, "body", WithRoleInstruction("", "body"))
	assert.Equal(t, "body", WithRoleInstruction("no_such_role", "body"))

	got := WithRoleInstruction("top_management", "body")
	assert.Equal(t, GetRoleInstruction("top_management")+"\n\nbody", got)
}
