package automations

import (
	"context"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
)

// workbenchResolver is the WorkbenchResolver over the workbench rows.
type workbenchResolver struct {
	db           *db.DB
	defaultAgent func() string
	protected    func(string) bool
}

// NewWorkbenchResolver returns the WorkbenchResolver of Backends.Workbench:
// a workbench's id and folder, Protected as protected answers for the folder
// (the daemon passes fsutil.PrivacyProtected) and DefaultAgent as
// defaultAgent answers (workbench.default_agent), claude when that is no
// agent kind. An unknown id fails with db.ErrWorkbenchNotFound.
func NewWorkbenchResolver(d *db.DB, defaultAgent func() string, protected func(string) bool) WorkbenchResolver {
	return &workbenchResolver{db: d, defaultAgent: defaultAgent, protected: protected}
}

func (r *workbenchResolver) Workbench(_ context.Context, id int64) (WorkbenchInfo, error) {
	wb, err := r.db.GetWorkbench(id)
	if err != nil {
		return WorkbenchInfo{}, err
	}
	agent, ok := agentkind.Parse(r.defaultAgent())
	if !ok {
		agent = agentkind.Claude
	}
	return WorkbenchInfo{ID: wb.ID, Folder: wb.FolderPath, Protected: r.protected(wb.FolderPath), DefaultAgent: string(agent)}, nil
}
