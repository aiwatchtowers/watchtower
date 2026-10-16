package agentreport

import (
	"strings"

	"watchtower/internal/db"
)

// Tool classes of the time split.
const (
	ClassBuildTest   = "build_test"
	ClassGit         = "git"
	ClassReadSearch  = "read_search"
	ClassEdit        = "edit"
	ClassMCP         = "mcp"
	ClassSubagentsFG = "subagents_fg"
	ClassOther       = "other"
)

var (
	buildTestVerbs = map[string]bool{"go test": true, "go build": true, "swift build": true, "swift test": true,
		"npm test": true, "npm run": true, "xcodebuild": true}
	readSearchTools = map[string]bool{"Read": true, "Grep": true, "Glob": true}
	readSearchProgs = map[string]bool{"cat": true, "ls": true, "grep": true, "rg": true, "find": true, "sed": true,
		"head": true, "tail": true}
	editTools = map[string]bool{"Edit": true, "Write": true, "MultiEdit": true, "NotebookEdit": true}
)

// ToolClass classifies a tool call by its name and stored target (a Bash
// target is the shell verb). An Agent/Task call is subagents_fg here; the
// time walk files a background one under other.
func ToolClass(name, target string) string {
	switch {
	case name == "Bash":
		prog, _, _ := strings.Cut(target, " ")
		switch {
		case buildTestVerbs[target] || prog == "make":
			return ClassBuildTest
		case prog == "git" || prog == "gh":
			return ClassGit
		case readSearchProgs[prog]:
			return ClassReadSearch
		}
	case readSearchTools[name]:
		return ClassReadSearch
	case editTools[name]:
		return ClassEdit
	case strings.HasPrefix(name, "mcp__"):
		return ClassMCP
	case isAgentTool(name):
		return ClassSubagentsFG
	}
	return ClassOther
}

func isAgentTool(name string) bool { return name == "Agent" || name == "Task" }

// eventClass is ToolClass with the background flag of an Agent call applied.
func eventClass(e db.AgentReportEvent) string {
	c := ToolClass(e.Name, e.Target)
	if c == ClassSubagentsFG && e.Background {
		return ClassOther
	}
	return c
}

// verb is what a tool segment names: the shell verb for Bash, else the tool.
func verb(e db.AgentReportEvent) string {
	if e.Name == "Bash" {
		return e.Target
	}
	return e.Name
}

func (t *ToolTimes) add(class string, ms int64) {
	switch class {
	case ClassBuildTest:
		t.BuildTest += ms
	case ClassGit:
		t.Git += ms
	case ClassReadSearch:
		t.ReadSearch += ms
	case ClassEdit:
		t.Edit += ms
	case ClassMCP:
		t.MCP += ms
	case ClassSubagentsFG:
		t.SubagentsFG += ms
	default:
		t.Other += ms
	}
}
