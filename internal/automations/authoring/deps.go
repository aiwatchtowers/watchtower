// Package authoring holds the chat tools that write automation recipes with
// the owner (spec 2026-10-14-automations-design §11): draft_automation
// validates and dry-runs a draft in memory, save_automation proposes saving
// it for the owner's Approve.
package authoring

import (
	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// Deps is what the authoring tools need. A workbench's folder comes from
// Workbench — the same resolver Backends().Workbench carries, without building
// the whole backends set for one lookup.
type Deps struct {
	DB           *db.DB
	WorkspaceDir string
	// Backends builds the dry run's SDK backends per call (the generator and
	// the tool registry may change while the process runs).
	Backends func() automations.Backends
	// Clock is the dry run's clock when Backends().Clock is nil.
	Clock automations.Clock
	// Workbench resolves save_automation's workbench_id to its folder.
	Workbench automations.WorkbenchResolver
}

// backends is Backends() with DB and Clock filled from d when unset.
func (d Deps) backends() automations.Backends {
	var b automations.Backends
	if d.Backends != nil {
		b = d.Backends()
	}
	if b.DB == nil {
		b.DB = d.DB
	}
	if b.Clock == nil {
		b.Clock = d.Clock
	}
	return b
}
