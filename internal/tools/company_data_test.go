package tools_test

// An external test package: it builds the read tools of the whole registry,
// the authoring ones (internal/automations/authoring, which imports tools)
// included, the way cmd's buildToolRegistry and the MCP server mount them.

import (
	"testing"

	"watchtower/internal/automations/authoring"
	"watchtower/internal/tools"
	"watchtower/internal/workbenchfiles"
)

// allReadCandidates is every tool the registry can mount that may be a read:
// buildToolRegistry's list plus the dependency-carrying reads.
func allReadCandidates() []*tools.Tool {
	deps := authoring.Deps{}
	all := []*tools.Tool{
		tools.NewBriefContext(),
		tools.NewGetConfluencePage(nil),
		tools.NewGetWritingStyle(),
		tools.NewListEmails(),
		tools.NewGetEmail(),
		tools.NewListSlackChannels(),
		tools.NewClaudeAIConnectorCall(),
		tools.NewApplyTrackAction(),
		authoring.NewDraftAutomation(deps),
		authoring.NewWorkbenchSkills(deps),
		authoring.NewListAutomationRuns(deps),
		authoring.NewGetAutomationRun(deps),
		authoring.NewListAutomations(deps),
		authoring.NewGetAutomation(deps),
	}
	all = append(all, tools.AutomationReadTools()...)
	all = append(all, tools.WorkbenchTools(workbenchfiles.Store{}, nil)...)
	all = append(all, tools.ReadTools()...)
	all = append(all, tools.DependentReadTools(tools.ReadDeps{})...)
	return all
}

func TestRead01_EveryReadToolDecided(t *testing.T) {
	reg := tools.New(nil)
	for _, tool := range allReadCandidates() {
		if err := reg.Register(tool); err != nil {
			t.Fatalf("register %s: %v", tool.Name, err)
		}
	}
	for _, problem := range tools.UndecidedReadTools(reg.All()) {
		t.Error(problem)
	}
	reads := map[string]bool{}
	for _, tool := range reg.All() {
		if tool.Access == tools.AccessRead {
			reads[tool.Name] = true
		}
	}
	for name, reason := range tools.UnmarkedReadToolsForTest() {
		if !reads[name] {
			t.Errorf("unmarkedReadTools names %s, which is not a registered read tool", name)
		}
		if reason == "" {
			t.Errorf("unmarkedReadTools[%s] has no reason", name)
		}
	}
}
