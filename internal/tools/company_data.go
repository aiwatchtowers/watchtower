package tools

import (
	"fmt"
	"slices"
)

// unmarkedReadTools are the read tools that are NOT company data, each with
// the reason. Every other read tool sets Tool.CompanyData and counts against
// the read budget (READ-01). A new read tool must land in one of the two;
// UndecidedReadTools is the guard.
var unmarkedReadTools = map[string]string{
	"workbench_info":       "the owner's own board",
	"workbench_board":      "the owner's own board",
	"list_targets":         "the owner's own board",
	"get_target":           "the owner's own board",
	"list_comments":        "the owner's own board",
	"get_ask":              "the owner's own asks",
	"list_asks":            "the owner's own asks",
	"get_review":           "the owner's own code review",
	"get_spec_review":      "the owner's own review loop",
	"load_skill":           "a skill file",
	"workbench_skills":     "skill files of the workbench folder",
	"list_jira_projects":   "project names only, no issue content",
	"list_linear_teams":    "team names only, no issue content",
	"list_slack_channels":  "channel names only, no message content",
	"get_track_counts":     "counts only, no track content",
	"draft_automation":     "the owner's own recipe draft",
	"list_automations":     "the owner's own recipes",
	"get_automation":       "the owner's own recipe",
	"list_automation_runs": "run metadata only (trigger, status, times, tokens, error); no step results or outputs",
}

// UndecidedReadTools returns one problem per read tool in ts that is neither
// CompanyData nor in the unmarked list, or is both, sorted — READ-01's guard,
// run over the tools package's list and over cmd's full registry.
func UndecidedReadTools(ts []*Tool) []string {
	var out []string
	for _, t := range ts {
		if t.Access != AccessRead {
			continue
		}
		_, unmarked := unmarkedReadTools[t.Name]
		switch {
		case t.CompanyData && unmarked:
			out = append(out, fmt.Sprintf("%s is CompanyData and in unmarkedReadTools; pick one", t.Name))
		case !t.CompanyData && !unmarked:
			out = append(out, fmt.Sprintf("%s is undecided: set CompanyData or list it in unmarkedReadTools with a reason", t.Name))
		}
	}
	slices.Sort(out)
	return out
}
