package tools

import (
	"context"
	"errors"
	"fmt"

	"watchtower/internal/db"
)

// WorkbenchContextType is the agent_actions.context_type of a project-bound
// proposal; context_id then holds the project id (newProposalRow/bindingOf).
// Exported so a reader outside this package (internal/mcp's actionVisible)
// need not hardcode the literal.
const WorkbenchContextType = "project"

// workbenchOf loads the project the binding is bound to. A binding with no
// project, or a project deleted while the session runs, is a model-facing
// ValidationError — the latter always worded "project N no longer exists".
func workbenchOf(_ context.Context, d *db.DB, b Binding) (*db.Workbench, error) {
	if b.WorkbenchID == 0 {
		return nil, &ValidationError{Msg: "this tool works only in a project session (watchtower mcp --project N)"}
	}
	p, err := d.GetWorkbench(b.WorkbenchID)
	if errors.Is(err, db.ErrWorkbenchNotFound) || (err == nil && p == nil) {
		return nil, &ValidationError{Msg: fmt.Sprintf("project %d no longer exists", b.WorkbenchID)}
	}
	if err != nil {
		return nil, fmt.Errorf("loading project %d: %w", b.WorkbenchID, err)
	}
	return p, nil
}
