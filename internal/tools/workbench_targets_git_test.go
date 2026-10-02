package tools

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// #131: project targets link to their git branch and pull request.
func TestProjectTargets_BranchAndPRAreSetShownAndCleared(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	out := mustApply(t, reg, fx.a, "create_targets",
		`{"items":[{"text":"Feature","branch":"feature/x","pr":"#12"}],"reason":"plan"}`)
	created := out["created"].([]any)
	id := int64(created[0].(map[string]any)["target_id"].(float64))

	board := callReadIn(t, reg, fx.a, "project_board", `{}`)
	assert.Contains(t, board, `"branch":"feature/x","pr":"#12"`)

	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"branch":" feature/y ","reason":"renamed"}`, id))
	got, err := fx.d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "feature/y", got.Branch, "trimmed")
	assert.Equal(t, "#12", got.PR, "an absent field stays as it was")

	// Re-setting the same branch is no movement: updated_at (the drift
	// check's stale clock) stays put.
	_, err = fx.d.Exec(`UPDATE targets SET updated_at = '2020-01-01T00:00:00Z' WHERE id = ?`, id)
	require.NoError(t, err)
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"branch":"feature/y","reason":"same"}`, id))
	got, err = fx.d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "2020-01-01T00:00:00Z", got.UpdatedAt)

	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"branch":"","pr":"","reason":"kept open on purpose"}`, id))
	got, err = fx.d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "", got.Branch)
	assert.Equal(t, "", got.PR)
}

func TestProjectTargets_GitLinksMustBeOneTokenNeverAnOption(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	cases := []struct{ name, tool, args string }{
		{"option branch", "create_targets", `{"items":[{"text":"F","branch":"--upload-pack=x"}],"reason":"r"}`},
		{"spaced pr", "create_targets", `{"items":[{"text":"F","pr":"12 13"}],"reason":"r"}`},
		{"option pr", "update_target", fmt.Sprintf(`{"target_id":%d,"pr":"-1","reason":"r"}`, fx.aTarget)},
		{"newline", "update_target", fmt.Sprintf(`{"target_id":%d,"branch":"a\nb","reason":"r"}`, fx.aTarget)},
		{"remote prefix", "update_target", fmt.Sprintf(`{"target_id":%d,"branch":"origin/feature-x","reason":"r"}`, fx.aTarget)},
		{"full ref", "create_targets", `{"items":[{"text":"F","branch":"refs/heads/x"}],"reason":"r"}`},
		{"range", "create_targets", `{"items":[{"text":"F","branch":"x..HEAD"}],"reason":"r"}`},
		{"reflog syntax", "create_targets", `{"items":[{"text":"F","branch":"x@{1}"}],"reason":"r"}`},
		{"ancestor syntax", "create_targets", `{"items":[{"text":"F","branch":"x~1"}],"reason":"r"}`},
	}
	for _, c := range cases {
		_, err := proposeIn(t, reg, fx.a, c.tool, c.args)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, c.name)
	}
}
