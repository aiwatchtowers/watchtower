package authoring

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"watchtower/internal/policy/policytest"
	"watchtower/internal/tools"
)

// TestSaveAutomation_PolicyRefusesShellRecipe: save_automation never
// proposes a recipe the organization's policy forbids (#608).
func TestSaveAutomation_PolicyRefusesShellRecipe(t *testing.T) {
	text := "---\nname: Shell\ntrigger:\n  manual: true\npermissions:\n  - 'shell:\"make test\"'\n---\nRuns tests.\n\n```js\nshell(\"make test\")\n```\n"
	raw, err := json.Marshal(saveArgs{RecipeText: text, Slug: "shell", WorkbenchID: 7, Reason: "tests"})
	if err != nil {
		t.Fatal(err)
	}
	validate := NewSaveAutomation(Deps{}).Validate

	policytest.Set(t, nil)
	if err := validate(context.Background(), nil, raw); err != nil {
		t.Fatalf("no profile: %v", err)
	}
	policytest.Set(t, map[string]any{"AllowAutomationShell": false})
	err = validate(context.Background(), nil, raw)
	var ve *tools.ValidationError
	if !errors.As(err, &ve) || !strings.Contains(ve.Msg, "shell() in automations is not allowed by your organization") {
		t.Fatalf("shell off: Validate = %v; want the policy refusal", err)
	}
}
