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

// unmarkedReadTools are the read tools that are NOT company data, each with
// the reason. Every other read tool sets Tool.CompanyData and counts against
// the read budget (READ-01). A new read tool must land in one of the two.
var unmarkedReadTools = map[string]string{
	"workbench_info":       "the owner's own board",
	"workbench_board":      "the owner's own board",
	"list_targets":         "the owner's own board",
	"get_target":           "the owner's own board",
	"list_comments":        "the owner's own board",
	"get_ask":              "the owner's own asks",
	"list_asks":            "the owner's own asks",
	"get_review":           "the owner's own code review",
	"load_skill":           "a skill file",
	"workbench_skills":     "skill files of the workbench folder",
	"get_writing_style":    "the owner's own writing style",
	"list_jira_projects":   "project names only, no issue content",
	"list_linear_teams":    "team names only, no issue content",
	"list_slack_channels":  "channel names only, no message content",
	"get_track_counts":     "counts only, no track content",
	"draft_automation":     "the owner's own recipe draft",
	"list_automations":     "the owner's own recipes",
	"get_automation":       "the owner's own recipe",
	"list_automation_runs": "the owner's own run history",
	"get_automation_run":   "the owner's own run history",
}

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
	all = append(all, tools.WorkbenchTools(workbenchfiles.Store{})...)
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
	reads := map[string]bool{}
	for _, tool := range reg.All() {
		if tool.Access != tools.AccessRead {
			continue
		}
		reads[tool.Name] = true
		_, unmarked := unmarkedReadTools[tool.Name]
		switch {
		case tool.CompanyData && unmarked:
			t.Errorf("%s is CompanyData and in unmarkedReadTools; pick one", tool.Name)
		case !tool.CompanyData && !unmarked:
			t.Errorf("%s is undecided: set CompanyData or list it in unmarkedReadTools with a reason", tool.Name)
		}
	}
	for name, reason := range unmarkedReadTools {
		if !reads[name] {
			t.Errorf("unmarkedReadTools names %s, which is not a registered read tool", name)
		}
		if reason == "" {
			t.Errorf("unmarkedReadTools[%s] has no reason", name)
		}
	}
}
