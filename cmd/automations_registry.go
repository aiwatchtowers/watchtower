package cmd

import (
	"watchtower/internal/automations"
	"watchtower/internal/automations/authoring"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
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

// automationAuthoringDeps wires draft_automation and save_automation (spec
// 2026-10-14 §11). The dry run's backends are built per call: the
// same automationBackends a run gets (registry, MCP caller, agent runner)
// around the authoring generator. The agent runner's children get an
// allowlisted env (automationAgentEnv), so no agent marker reaches them.
// agent() itself is not previewed in a draft (no run row to bind to).
// budget is the registry whose read budget the dry run spends (READ-01);
// nil gives each dry run a fresh one (tests).
func automationAuthoringDeps(cfg *config.Config, database *db.DB, budget *tools.Registry) authoring.Deps {
	return authoring.Deps{
		DB:           database,
		WorkspaceDir: cfg.WorkspaceDir(),
		Backends: func() automations.Backends {
			b := automationBackends(cfg, database, automationsAuthoringGenerator(cfg))
			// The dry run's reads spend the calling process's read budget
			// (READ-01), not a fresh one per draft.
			if reg, ok := b.Registry.(*tools.Registry); ok && budget != nil {
				reg.ShareReadBudget(budget)
			}
			return b
		},
		Clock:     automations.RealClock{},
		Workbench: automationWorkbenchResolver(cfg, database),
	}
}

// automationsAuthoringGenerator is the generator a draft's dry-run llm()
// calls use: the bounded CLI generator (H8 wall-clock cap) whose child runs
// in its own process group and without AGENT-07's agent markers. The chat
// MCP server that runs the draft is itself a child of claude (so it carries
// CLAUDECODE) or of a workbench/Codex agent; the model call it starts is
// the automation's, not that agent's.
func automationsAuthoringGenerator(cfg *config.Config) digest.Generator {
	gen := cliGenerator(cfg)
	if s, ok := gen.(interface{ SetIsolatedChild(...string) }); ok {
		s.SetIsolatedChild(agentEnvMarkers...)
	}
	return digest.WithCallTimeout(gen, digest.DaemonAICallTimeout)
}
