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
// external dependencies, nothing that could write.
func NewReadRegistry(d *db.DB) *Registry {
	reg := New(d)
	for _, t := range ReadTools() {
		if err := reg.Register(t); err != nil {
			panic("read registry: " + err.Error())
		}
	}
	return reg
}
