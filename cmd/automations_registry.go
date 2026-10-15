package cmd

import (
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// buildAutomationRegistry is the one registry every automation path uses —
// the daemon's executor, the CLI's dry-run, P3's draft_automation backends
// and P6's runtime-B agent() (spec 2026-10-14 §6.1, §20.1 D23):
// buildToolRegistry plus the three memory tools on the workspace vault.
// memory_recall gets no shadow handle, so it writes no
// memory_retrieve_shadow row, and memory_open skips its stat bump on the
// automation surface: automation reads write nothing. load_skill is not
// added. buildToolRegistry itself never gains the memory tools — the chat
// MCP server registers them from tools.DependentReadTools, and doing both
// would register them twice.
func buildAutomationRegistry(cfg *config.Config, database *db.DB) *tools.Registry {
	reg := buildToolRegistry(cfg, database)
	// No RetrieveShadowDB and no SkillsDir: recall writes no shadow row, and
	// load_skill is skipped below.
	for _, t := range tools.DependentReadTools(tools.ReadDeps{MemoryVaultPath: memoryVaultPath(cfg)}) {
		if t.Name == "load_skill" {
			continue
		}
		if err := reg.Register(t); err != nil {
			panic("automation tool registry: " + err.Error())
		}
	}
	return reg
}
