package tools

// The workbench tools whose names changed in the Workbench rename (spec
// 2026-10-02 §4.3). The other workbench tools kept their neutral names.
const (
	WorkbenchInfoTool         = "workbench_info"
	WorkbenchBoardTool        = "workbench_board"
	UpdateWorkbenchTool       = "update_workbench"
	AddWorkbenchSourceTool    = "add_workbench_source"
	RemoveWorkbenchSourceTool = "remove_workbench_source"
)

// preRenameWorkbenchToolNames maps each renamed workbench tool's pre-rename
// name to its current one. No session serves the old names any more; the map
// only lets an agent_actions row recorded before the rename find its tool
// (Registry.Get) and be shown under the current name. Read-only: never
// modified at run time.
var preRenameWorkbenchToolNames = map[string]string{
	"project_info":          WorkbenchInfoTool,
	"project_board":         WorkbenchBoardTool,
	"update_project":        UpdateWorkbenchTool,
	"add_project_source":    AddWorkbenchSourceTool,
	"remove_project_source": RemoveWorkbenchSourceTool,
}

// CanonicalToolName is name with a pre-rename workbench tool name replaced by
// the current one; any other name comes back unchanged.
func CanonicalToolName(name string) string {
	if c, ok := preRenameWorkbenchToolNames[name]; ok {
		return c
	}
	return name
}
