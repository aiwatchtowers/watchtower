package tools

import (
	"context"
	"errors"
	"fmt"

	"watchtower/internal/db"
)

// WorkbenchContextType is the agent_actions.context_type of a workbench-bound
// proposal; context_id then holds the workbench id (newProposalRow/bindingOf).
// Exported so a reader outside this package (internal/mcp's actionVisible)
// need not hardcode the literal.
// The value is the pre-rename "project": it is persisted in agent_actions
// (spec 2026-10-02 A1).
const WorkbenchContextType = "project"

// workbenchOf loads the workbench the binding is bound to. A binding with no
// workbench, or a workbench deleted while the session runs, is a model-facing
// ValidationError — the latter always worded "workbench N no longer exists".
func workbenchOf(_ context.Context, d *db.DB, b Binding) (*db.Workbench, error) {
	if b.WorkbenchID == 0 {
		return nil, &ValidationError{Msg: "this tool works only in a workbench session (watchtower mcp --workbench N)"}
	}
	p, err := d.GetWorkbench(b.WorkbenchID)
	if errors.Is(err, db.ErrWorkbenchNotFound) || (err == nil && p == nil) {
		return nil, &ValidationError{Msg: fmt.Sprintf("workbench %d no longer exists", b.WorkbenchID)}
	}
	if err != nil {
		return nil, fmt.Errorf("loading workbench %d: %w", b.WorkbenchID, err)
	}
	return p, nil
}
