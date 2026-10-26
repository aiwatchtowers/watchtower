package prompts

import (
	"context"
	"strings"
	"testing"
	"time"

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
	require.Error(t, err, "an empty row is reported so the caller logs the fallback")
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

func TestResolve_UnregisteredIDReturnsEmptyAndError(t *testing.T) {
	store := New(openTestDB(t), nil)

	tmpl, version, err := Resolve(store, "no.such.prompt", "")
	require.Error(t, err)
	assert.Empty(t, tmpl)
	assert.Equal(t, 0, version)
}

func TestDefaultForRole(t *testing.T) {
	assert.Equal(t, Defaults[DigestChannel], DefaultForRole(DigestChannel, ""))
	assert.Equal(t, Defaults[DigestChannel], DefaultForRole(DigestChannel, "no-such-role"))
	Defaults["test.role_x"] = "base"
	Defaults["test.role_x_lead"] = "lead variant"
	t.Cleanup(func() { delete(Defaults, "test.role_x"); delete(Defaults, "test.role_x_lead") })
	assert.Equal(t, "lead variant", DefaultForRole("test.role_x", "lead"))
	assert.Equal(t, "base", DefaultForRole("test.role_x", "other"))
}

func TestTuner_SkipsMovedPrompts(t *testing.T) {
	tuner := NewTuner(nil, nil, nil)
	for id := range MovedToBuiltin {
		_, err := tuner.Suggest(context.Background(), id)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "Automations")
		_, err = tuner.SuggestManual(context.Background(), id, "x")
		require.Error(t, err)
	}
	assert.Equal(t, "morning-brief", MovedToBuiltin[BriefingDaily])
	assert.Equal(t, "morning-brief", MovedToBuiltin[DayPlanGenerate])
}

func TestMovedToBuiltin_CThreeIDs(t *testing.T) {
	assert.Equal(t, "track-my-threads", MovedToBuiltin[TracksExtractBatch])
	assert.Equal(t, "idea-finder", MovedToBuiltin[IdeasConsolidate])
	assert.Equal(t, "reactions", MovedToBuiltin[ReactionCommand])
	_, err := NewTuner(nil, nil, nil).Suggest(context.Background(), IdeasConsolidate)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "idea-finder")
}

func TestResolve_AppendsAdditions(t *testing.T) {
	database := openTestDB(t)
	store := New(database, nil)
	require.NoError(t, store.Seed())
	_, err := database.AddPromptAddition(CatchupCompose, "Do not flag naming choices.", 0, time.Now())
	require.NoError(t, err)

	tmpl, _, err := Resolve(store, CatchupCompose, "")
	require.NoError(t, err)
	assert.Equal(t, Defaults[CatchupCompose]+"\n\n=== OWNER PREFERENCES (approved by the owner) ===\n- Do not flag naming choices.\n", tmpl)

	// Unseeded store: the built-in default gets the block too.
	bare := New(openTestDB(t), nil)
	_, err = bare.DB().AddPromptAddition(MeetingRecap, "Be brief.", 0, time.Now())
	require.NoError(t, err)
	tmpl, _, err = Resolve(bare, MeetingRecap, "")
	require.NoError(t, err)
	assert.True(t, strings.HasSuffix(tmpl, "- Be brief.\n"))
}

func TestResolve_AdditionsOnRoleVariant(t *testing.T) {
	database := openTestDB(t)
	require.NoError(t, database.UpsertPrompt(db.Prompt{ID: BriefingDaily + "_top_management", Template: "variant", Version: 3}))
	_, err := database.AddPromptAddition(BriefingDaily, "Keep it short.", 0, time.Now())
	require.NoError(t, err)

	tmpl, _, err := Resolve(New(database, nil), BriefingDaily, "top_management")
	require.NoError(t, err)
	assert.Equal(t, WithAdditions("variant", []string{"Keep it short."}), tmpl)
}

func TestResolve_NoAdditionsUnchanged(t *testing.T) {
	store := New(openTestDB(t), nil)
	require.NoError(t, store.Seed())
	tmpl, _, err := Resolve(store, CatchupCompose, "")
	require.NoError(t, err)
	assert.Equal(t, Defaults[CatchupCompose], tmpl)
}

func TestResolve_AdditionsDoNotSetCustomized(t *testing.T) {
	database := openTestDB(t)
	store := New(database, nil)
	require.NoError(t, store.Seed())
	_, err := database.AddPromptAddition(DigestChannel, "Do not flag naming choices.", 0, time.Now())
	require.NoError(t, err)
	_, _, err = Resolve(store, DigestChannel, "")
	require.NoError(t, err)

	row, err := database.GetPrompt(DigestChannel)
	require.NoError(t, err)
	assert.False(t, row.Customized)

	// A shipped default bump still upgrades the row, and the addition stays.
	original := DefaultVersions[DigestChannel]
	DefaultVersions[DigestChannel] = row.Version + 5
	t.Cleanup(func() { DefaultVersions[DigestChannel] = original })
	require.NoError(t, New(database, nil).Seed())

	tmpl, version, err := Resolve(New(database, nil), DigestChannel, "")
	require.NoError(t, err)
	assert.Equal(t, row.Version+5, version)
	assert.True(t, strings.HasSuffix(tmpl, "- Do not flag naming choices.\n"))
}

func TestValidateAddition(t *testing.T) {
	for _, bad := range []string{"", "  ", "uses %d", "x {{.X}}", "a }} b", "two\nlines", strings.Repeat("я", 301)} {
		assert.Error(t, ValidateAddition(bad), "%q", bad)
	}
	assert.NoError(t, ValidateAddition("Do not flag naming choices."))
	assert.NoError(t, ValidateAddition(strings.Repeat("я", 300)))
}

func TestWithAdditions_Format(t *testing.T) {
	tmpl := "base"
	assert.Equal(t, tmpl, WithAdditions(tmpl, nil))
	want := tmpl + "\n\n=== OWNER PREFERENCES (approved by the owner) ===\n- Do not flag naming choices.\n"
	assert.Equal(t, want, WithAdditions(tmpl, []string{"Do not flag naming choices."}))
}
