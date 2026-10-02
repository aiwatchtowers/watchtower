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

// canonicalWorkbenchToolNames is LegacyWorkbenchToolNames inverted.
var canonicalWorkbenchToolNames = invert(LegacyWorkbenchToolNames)

func invert(m map[string]string) map[string]string {
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[v] = k
	}
	return out
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
// list. Only a standalone name is rewritten: one that touches no identifier
// character, '/', '.' or '-' on either side, so a path, a file name or an
// identifier the text echoes from the agent's input
// (internal/db/workbench_board.go) is left as it was.
func (b Binding) Spell(text string) string {
	if !b.LegacyNames {
		return text
	}
	var out strings.Builder
	last := 0 // text[last:i] is not yet copied
	for i := 0; i < len(text); i++ {
		if i > 0 && nameRune(text[i-1]) {
			continue
		}
		for newName, oldName := range LegacyWorkbenchToolNames {
			end := i + len(newName)
			if !strings.HasPrefix(text[i:], newName) || !tokenEnds(text, end) {
				continue
			}
			out.WriteString(text[last:i])
			out.WriteString(oldName)
			last = end
			i = end - 1
			break
		}
	}
	if last == 0 {
		return text
	}
	out.WriteString(text[last:])
	return out.String()
}

// tokenEnds reports whether a name ending at text[end] stands alone: the
// text ends there or goes on with a non-name character — a '.' counting as
// the end of a sentence when no name character follows it ("… from
// workbench_info."), and as part of a file name otherwise
// ("workbench_info.go").
func tokenEnds(text string, end int) bool {
	switch {
	case end >= len(text):
		return true
	case text[end] == '.':
		return end+1 >= len(text) || !nameRune(text[end+1])
	default:
		return !nameRune(text[end])
	}
}

// nameRune reports whether c, next to a tool name, makes it part of a longer
// token: an identifier, a path or a file name.
func nameRune(c byte) bool {
	return c == '_' || c == '/' || c == '.' || c == '-' ||
		(c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}
