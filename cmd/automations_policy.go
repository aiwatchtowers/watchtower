package cmd

import (
	"errors"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// automationPolicyBlocked is show/list's policy_blocked (#608): "" when the
// organization's policy allows a's manifest (or it does not parse), else
// automations.PolicyBlockShell or PolicyBlockMCP. The card shows "Blocked by
// your organization's policy"; the recipe stays listed and indexed.
func automationPolicyBlocked(a *db.Automation, lookup func(string) (string, string, string, bool)) string {
	m, err := automationManifest(a)
	if err != nil {
		return ""
	}
	var b *automations.PolicyBlock
	if errors.As(automations.CheckManifestPolicy(m, lookup), &b) {
		return b.Kind
	}
	return ""
}
