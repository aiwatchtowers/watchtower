package tools

import (
	"context"
	"errors"
	"fmt"

	"watchtower/internal/db"
)

// projectContextType is the agent_actions.context_type of a project-bound
// proposal; context_id then holds the project id (newProposalRow/bindingOf).
const projectContextType = "project"

// projectOf loads the project the binding is bound to. A binding with no
// project, or a project deleted while the session runs, is a model-facing
// ValidationError — the latter always worded "project N no longer exists".
func projectOf(_ context.Context, d *db.DB, b Binding) (*db.Project, error) {
	if b.ProjectID == 0 {
		return nil, &ValidationError{Msg: "this tool works only in a project session (watchtower mcp --project N)"}
	}
	p, err := d.GetProject(b.ProjectID)
	if errors.Is(err, db.ErrProjectNotFound) || (err == nil && p == nil) {
		return nil, &ValidationError{Msg: fmt.Sprintf("project %d no longer exists", b.ProjectID)}
	}
	if err != nil {
		return nil, fmt.Errorf("loading project %d: %w", b.ProjectID, err)
	}
	return p, nil
}
