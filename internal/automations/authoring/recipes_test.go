package authoring

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

func seedRecipe(t *testing.T, d *db.DB, scope string, projectID int64, slug, front string) int64 {
	t.Helper()
	id, err := d.UpsertAutomationIndex(db.Automation{
		Slug: slug, Scope: scope, ProjectID: projectID, Path: "/acme/" + scope + "/" + slug + ".md", Name: "Acme " + slug,
		TriggerKind: "manual", TriggerSpec: `{"manual":true}`, MissedPolicy: "run_once",
		Concurrency: 1, BudgetTokens: 50000, BudgetMinutes: 5, PauseTimeoutHours: 72,
		PermissionsJSON: `["llm"]`, OutputsJSON: `["inbox"]`,
		RecipeText:  recipeText(nil, front, "state.set('k', 1)"),
		ContentHash: "c-" + slug + scope, ApprovalHash: "a-" + slug + scope,
	})
	require.NoError(t, err)
	return id
}

func TestListAutomations_ExcludesRemovedAndFilters(t *testing.T) {
	d := openRunsTestDB(t)
	seedRecipe(t, d, "personal", 0, "digest", "")
	gone := seedRecipe(t, d, "personal", 0, "digest-old", "")
	seedRecipe(t, d, "personal", 0, "other", "")
	_, err := d.Exec(`UPDATE automations SET removed_at = '2026-10-01T00:00:00Z' WHERE id = ?`, gone)
	require.NoError(t, err)
	tool := NewListAutomations(Deps{DB: d})

	out, err := callRunTool(t, tool, `{}`)
	require.NoError(t, err)
	assert.Len(t, out["automations"], 2)

	out, err = callRunTool(t, tool, `{"query":"DIGE"}`)
	require.NoError(t, err)
	list := out["automations"].([]any)
	require.Len(t, list, 1)
	row := list[0].(map[string]any)
	assert.Equal(t, "digest", row["slug"])
	assert.Equal(t, "personal", row["scope"])
	assert.Equal(t, "manual", row["trigger"])
	assert.Equal(t, false, row["builtin"])
}

func TestListAutomations_SummaryFallback(t *testing.T) {
	d := openRunsTestDB(t)
	seedRecipe(t, d, "personal", 0, "plain", "")
	seedRecipe(t, d, "personal", 0, "explicit", "summary: Acme at nine\n")
	out, err := callRunTool(t, NewListAutomations(Deps{DB: d}), `{}`)
	require.NoError(t, err)
	got := map[string]string{}
	for _, r := range out["automations"].([]any) {
		m := r.(map[string]any)
		got[m["slug"].(string)] = m["summary"].(string)
	}
	assert.Equal(t, "Acme at nine", got["explicit"])
	assert.Equal(t, "A draft test recipe.", got["plain"])
}

func TestGetAutomation_ReturnsRecipeText(t *testing.T) {
	d := openRunsTestDB(t)
	id := seedRecipe(t, d, "personal", 0, "digest", "")
	out, err := callRunTool(t, NewGetAutomation(Deps{DB: d}), `{"automation":"digest"}`)
	require.NoError(t, err)
	assert.EqualValues(t, id, out["id"])
	assert.Contains(t, out["recipe_text"], "state.set")
	assert.Equal(t, "", out["parse_error"])
	assert.Contains(t, NewGetAutomation(Deps{}).Description, "data")
	assert.Equal(t, tools.AccessRead, NewGetAutomation(Deps{}).Access)
}

func TestGetAutomation_AmbiguousSlug(t *testing.T) {
	d := openRunsTestDB(t)
	seedRecipe(t, d, "personal", 0, "digest", "")
	bench, err := d.CreateWorkbench("Acme bench", t.TempDir())
	require.NoError(t, err)
	seedRecipe(t, d, "workbench", bench, "digest", "")
	_, err = callRunTool(t, NewGetAutomation(Deps{DB: d}), `{"automation":"digest"}`)
	var ve *tools.ValidationError
	require.ErrorAs(t, err, &ve)
}
