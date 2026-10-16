package automations

import (
	"slices"

	"watchtower/internal/tools"
)

// EffectiveAgentTools is the tool set an agent() call may use (spec §6.5):
// requested (nil = every tool on the automation surface) ∩ the tools m
// admits by name — AdmitsTool, or the tool behind an outputs-only shortcut
// (outputs:[target] → create_target, as output.target allows) — minus the
// write tools in a dry run (AUTO-12). Unknown names are dropped; the result
// is sorted. The runtime-B loop's allowlist and the agent MCP server's
// --allowedTools both come from here.
func EffectiveAgentTools(reg ToolRegistry, m *Manifest, requested []string, dryRun bool) []string {
	var candidates []*tools.Tool
	if requested == nil {
		candidates = reg.List(tools.AutomationSurface)
	} else {
		for _, name := range requested {
			if t, ok := reg.Get(name); ok {
				candidates = append(candidates, t)
			}
		}
	}
	out := []string{}
	for _, t := range candidates {
		if !m.AdmitsTool(t) && !m.admitsAsOutput(t) {
			continue
		}
		if dryRun && t.Access == tools.AccessWrite {
			continue
		}
		if !slices.Contains(out, t.Name) {
			out = append(out, t.Name)
		}
	}
	slices.Sort(out)
	return out
}
