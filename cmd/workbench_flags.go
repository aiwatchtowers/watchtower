package cmd

import (
	"errors"

	"github.com/spf13/cobra"
)

// workbenchFlag is the workbench id flag; legacyWorkbenchFlag is its
// pre-rename spelling. Every folder set up before the Workbench rename has
// hooks and an MCP registration that pass --project, and until the owner
// resyncs that folder they must keep working exactly (spec 2026-10-02 §5.2).
const (
	workbenchFlag       = "workbench"
	legacyWorkbenchFlag = "project"
)

// errBothWorkbenchFlags refuses an invocation naming the id under both
// spellings: with one variable behind both flags the last one would win.
var errBothWorkbenchFlags = errors.New("--project is the old name of --workbench; pass one")

// addWorkbenchIDFlag registers --workbench on cmd, bound to v, and the
// pre-rename --project as a hidden flag bound to the same variable — hidden
// without a deprecation notice, because a hook's stdout and stderr belong to
// Claude Code. legacy reports whether this invocation used the old spelling,
// which only a pre-rename install ever wrote: brief, check and mcp pick the
// vocabulary the agent sees from it.
func addWorkbenchIDFlag[T int64 | string](cmd *cobra.Command, v *T, usage string) (legacy func() bool) {
	fs := cmd.Flags()
	switch p := any(v).(type) {
	case *int64:
		fs.Int64Var(p, workbenchFlag, 0, usage)
		fs.Int64Var(p, legacyWorkbenchFlag, 0, usage)
	case *string:
		fs.StringVar(p, workbenchFlag, "", usage)
		fs.StringVar(p, legacyWorkbenchFlag, "", usage)
	}
	_ = fs.MarkHidden(legacyWorkbenchFlag)
	return func() bool { return fs.Changed(legacyWorkbenchFlag) }
}

// checkWorkbenchIDFlags refuses --project next to --workbench.
func checkWorkbenchIDFlags(cmd *cobra.Command) error {
	fs := cmd.Flags()
	if fs.Changed(workbenchFlag) && fs.Changed(legacyWorkbenchFlag) {
		return errBothWorkbenchFlags
	}
	return nil
}

// workbenchFlagName is the spelling of the id flag this invocation used, for
// a message that names it back to the caller.
func workbenchFlagName(legacy bool) string {
	if legacy {
		return "--" + legacyWorkbenchFlag
	}
	return "--" + workbenchFlag
}

// vocabulary is the skill and tool names the brief and the Stop hook
// name to the agent. A folder still on its pre-rename install (invoked with
// --project) has only the old skill, and its MCP server serves the old tool
// names, so it is told those; a resynced folder gets the new ones.
type vocabulary struct {
	SkillName  string
	InfoTool   string
	UpdateTool string
	BoardTool  string
	Legacy     bool
}

var (
	workbenchVocabulary = vocabulary{
		SkillName: "watchtower-workbench", InfoTool: "workbench_info", UpdateTool: "update_workbench", BoardTool: "workbench_board",
	}
	legacyWorkbenchVocabulary = vocabulary{
		SkillName: "watchtower-project", InfoTool: "project_info", UpdateTool: "update_project", BoardTool: "project_board",
		Legacy: true,
	}
)

// vocabularyFor is the vocabulary of an invocation that did (legacy) or did
// not use --project.
func vocabularyFor(legacy bool) vocabulary {
	if legacy {
		return legacyWorkbenchVocabulary
	}
	return workbenchVocabulary
}
