package tools

import "watchtower/internal/db"

// ReadTools returns every read tool that has been migrated into the registry,
// in a stable registration order. It is the single list the MCP server (dev and
// chat modes) and the runtime-B loop both mount, so the assistant's three faces
// can never disagree about which read tools exist or what they do.
//
// The migration adds to this list one domain at a time; the MCP server drops the
// matching per-domain register* handler in the same change, keeping the exposed
// tool set constant (guarded by internal/mcp's TestToolsList).
func ReadTools() []*Tool {
	return []*Tool{
		NewListSituations(),
		NewGetSituation(),
		NewGetTodayBriefing(),
		NewListDigests(),
		NewGetDigest(),
		NewListIdeas(),
		NewGetIdea(),
		NewListTargets(),
		NewGetTarget(),
		NewListJiraIssues(),
		NewGetJiraIssue(),
		NewListJiraProjects(),
		NewListPeople(),
		NewGetPerson(),
		NewListTracks(),
		NewGetTrack(),
		NewListUpcomingEvents(),
		NewListTranscripts(),
		NewGetTranscript(),
		NewListMessages(),
		NewFindExperts(),
		NewGetTaskContext(),
	}
}

// NewReadRegistry builds a registry holding only the migrated read tools over d.
// It is what the dev-mode MCP server and its tests mount: no write tools, no
// external dependencies, nothing that could write. The dependency-carrying read
// tools (memory_*, load_skill) are NOT here — they need a vault path, skills dir
// and shadow handle; the MCP server registers them via DependentReadTools.
func NewReadRegistry(d *db.DB) *Registry {
	reg := New(d)
	for _, t := range ReadTools() {
		if err := reg.Register(t); err != nil {
			panic("read registry: " + err.Error())
		}
	}
	return reg
}

// ReadDeps are the non-db dependencies the dependency-carrying read tools close
// over: the memory vault path, the skills directory, and the optional
// recall-compare shadow handle (nil when memory.retrieve.recall_compare is off).
type ReadDeps struct {
	MemoryVaultPath  string
	SkillsDir        string
	RetrieveShadowDB *db.DB
}

// DependentReadTools returns the read tools that cannot sit in the zero-arg
// ReadTools() list because they close over ReadDeps: the three memory tools
// (vault + index; memory_open bumps usage stats, memory_recall writes the dark
// shadow row) and load_skill (a file read of the skills dir). The MCP server
// registers them onto its registry in both modes (NewServer), from the paths it
// resolved. The runtime-B loop, which builds its registry from ReadTools()
// alone, does not mount them yet (a documented follow-up).
func DependentReadTools(deps ReadDeps) []*Tool {
	return []*Tool{
		NewMemoryMap(deps.MemoryVaultPath),
		NewMemoryOpen(deps.MemoryVaultPath),
		NewMemoryRecall(deps.MemoryVaultPath, deps.RetrieveShadowDB),
		NewLoadSkill(deps.SkillsDir),
	}
}
