package tools

import "strings"

// The workbench tools whose names changed in the Workbench rename (spec
// 2026-10-02 §4.3). The other six workbench tools kept their neutral names.
const (
	WorkbenchInfoTool         = "workbench_info"
	WorkbenchBoardTool        = "workbench_board"
	UpdateWorkbenchTool       = "update_workbench"
	AddWorkbenchSourceTool    = "add_workbench_source"
	RemoveWorkbenchSourceTool = "remove_workbench_source"
)

// LegacyWorkbenchToolNames maps each renamed workbench tool to its
// pre-rename name. A folder set up before the rename still runs
// `watchtower mcp --project N`, and its installed skill calls the old names,
// so that session lists the tools under them (Binding.LegacyNames) until the
// owner resyncs the folder (spec §5.2). Registry lookups accept both
// spellings; agent_actions always records the new one. Read-only: never
// modified at run time.
var LegacyWorkbenchToolNames = map[string]string{
	WorkbenchInfoTool:         "project_info",
	WorkbenchBoardTool:        "project_board",
	UpdateWorkbenchTool:       "update_project",
	AddWorkbenchSourceTool:    "add_project_source",
	RemoveWorkbenchSourceTool: "remove_project_source",
}

var (
	// canonicalWorkbenchToolNames is LegacyWorkbenchToolNames inverted.
	canonicalWorkbenchToolNames = invert(LegacyWorkbenchToolNames)
	// legacySpeller rewrites every renamed tool name in a model-facing text
	// to its old name.
	legacySpeller = newLegacySpeller(LegacyWorkbenchToolNames)
)

func invert(m map[string]string) map[string]string {
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[v] = k
	}
	return out
}

func newLegacySpeller(m map[string]string) *strings.Replacer {
	pairs := make([]string, 0, 2*len(m))
	for newName, oldName := range m {
		pairs = append(pairs, newName, oldName)
	}
	return strings.NewReplacer(pairs...)
}

// CanonicalToolName is name with a pre-rename workbench tool name replaced by
// the current one; any other name comes back unchanged.
func CanonicalToolName(name string) string {
	if c, ok := canonicalWorkbenchToolNames[name]; ok {
		return c
	}
	return name
}

// Spell is a model-facing text — a tool name, a description, an error — in
// the vocabulary this binding's session sees: unchanged, or, for a legacy
// session (LegacyNames), with every renamed workbench tool named by its old
// name, so the text never points the agent at a tool its session does not
// list.
func (b Binding) Spell(text string) string {
	if !b.LegacyNames {
		return text
	}
	return legacySpeller.Replace(text)
}
