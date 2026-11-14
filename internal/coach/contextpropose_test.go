package coach

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentfiles"
	"watchtower/internal/agentlogdb"
	"watchtower/internal/agentreport"
	"watchtower/internal/db"
)

// The context proposer reads the Context facts through two seams (the
// install-wide sources and one workbench's overview) and the owner's config
// under a temp home; no test here reads the real home.

var ctxNow = time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)

const ctxProposeSettings = `{
  "enabledPlugins": {
    "alpha@example-market": true,
    "superpowers@claude-plugins-official": true,
    "pr-review-toolkit@claude-plugins-official": true
  },
  "env": {"OTHER": "x"}
}`

const ctxInstalled = `{"version": 2, "plugins": {
  "alpha@example-market": [{"scope": "user"}, {"scope": "project", "projectPath": "/work/acme"}],
  "superpowers@claude-plugins-official": [{"scope": "user"}]
}}`

var ctxProposeClaudeJSON = `{
  "mcpServers": {
    "alpha-docs": {"type": "http", "url": "https://mcp.example.com/a", "headers": {"Authorization": "` + ctxSecret + `"}},
    "watchtower-workbench": {"command": "watchtower"}
  },
  "projects": {
    "/work/acme": {"mcpServers": {"alpha-docs": {"command": "alpha"}}},
    "/work/beta": {"mcpServers": {"other": {"command": "other"}}}
  }
}`

// ctxFixture is a home with the config above, a workbench with analytics on
// and the two seams faked: global are the install-wide rows, facts the
// workbench's measured sessions, local its own overview rows.
type ctxFixture struct {
	d      dbs
	home   string
	wb     int64
	folder string
	global []agentreport.ContextSourceRow
	local  []agentreport.ContextSourceRow
	facts  int
	// globalCalls counts the reads of the install-wide sources.
	globalCalls int
}

func newCtxFixture(t *testing.T) *ctxFixture {
	t.Helper()
	f := &ctxFixture{d: openDBs(t), home: ctxHome(t), facts: 6}
	f.wb, _ = f.d.workbench(t, "acme", 0)
	w, err := f.d.GetWorkbench(f.wb)
	require.NoError(t, err)
	f.folder = w.FolderPath
	writeHomeFile(t, claudeSettingsPath(f.home), ctxProposeSettings)
	writeHomeFile(t, installedPluginsPath(f.home), ctxInstalled)
	writeHomeFile(t, claudeJSONPath(f.home), ctxProposeClaudeJSON)
	og, oo := contextGlobalSources, contextOverview
	contextGlobalSources = func(_ *db.DB, _ *agentlogdb.DB, since, now time.Time) ([]agentreport.ContextSourceRow, error) {
		f.globalCalls++
		assert.Equal(t, ctxNow.Add(-ctxWindowDays*24*time.Hour), since)
		assert.Equal(t, ctxNow, now)
		return f.global, nil
	}
	contextOverview = func(_ ContextEnv, wb int64, since, now time.Time) (*agentreport.Overview, error) {
		assert.Equal(t, ctxNow.Add(-ctxWindowDays*24*time.Hour), since)
		ov := &agentreport.Overview{WorkbenchID: wb}
		ov.Context.FactsSessions = f.facts
		ov.Context.Sources = f.local
		return ov, nil
	}
	t.Cleanup(func() { contextGlobalSources, contextOverview = og, oo })
	return f
}

func (f *ctxFixture) env() ContextEnv {
	return ContextEnv{DB: f.d.DB, AgentLog: f.d.al, Home: f.home, Now: func() time.Time { return ctxNow }}
}

func (f *ctxFixture) run(t *testing.T, wb int64) int {
	t.Helper()
	n, err := ProposeContext(f.env(), wb)
	require.NoError(t, err)
	return n
}

func (f *ctxFixture) rows(t *testing.T) []db.CoachProposal {
	t.Helper()
	ps, err := f.d.ListCoachProposals()
	require.NoError(t, err)
	return ps
}

func srcRow(part, group, kind string, tokens, calls, measured int) agentreport.ContextSourceRow {
	return agentreport.ContextSourceRow{Part: part, Group: group, GroupKind: kind, Tokens: tokens, Calls: calls, Measured: measured}
}

func memoryPath(home, folder string) string {
	return filepath.Join(home, ".claude", "projects", agentfiles.Slug(folder), "memory", "MEMORY.md")
}

func onlyDest(ps []db.CoachProposal, dest string) []db.CoachProposal {
	var out []db.CoachProposal
	for _, p := range ps {
		if p.Destination == dest {
			out = append(out, p)
		}
	}
	return out
}

func TestProposeContext_UnusedPlugin(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{
		srcRow("skills", "alpha", agentreport.GroupPlugin, 900, 0, 6),
		srcRow("agents", "alpha", agentreport.GroupPlugin, 300, 0, 5),
	}

	require.Equal(t, 1, f.run(t, f.wb))
	ps := f.rows(t)
	require.Len(t, ps, 1)
	p := ps[0]
	assert.Equal(t, DestPluginOff, p.Destination)
	assert.Equal(t, "alpha@example-market", p.SourceKey)
	assert.Equal(t, "true", p.BeforeText)
	assert.Equal(t, "false", p.AfterText)
	assert.Equal(t, int64(0), p.WorkbenchID, "a global destination has no workbench")
	assert.Equal(t, "context", p.Origin)
	assert.Equal(t, "start_tokens", p.Metric)
	assert.Equal(t, "open", p.Status)
	assert.NotEmpty(t, p.Title)
	assert.NotEmpty(t, p.Why)
	require.NotEmpty(t, p.Evidence)
	assert.Equal(t, db.CoachEvidence{Kind: "source",
		Ref: "alpha · 1200 tok · 0 calls in Watchtower sessions (all workbenches) in 30 days"}, p.Evidence[0])
	assert.Equal(t, 6, p.Sources)
}

func TestProposeContext_UsedInAnotherWorkbenchSkipped(t *testing.T) {
	f := newCtxFixture(t)
	// This workbench never called it; another workbench did, twice (a
	// calls-only row: called, never measured in that part).
	f.local = []agentreport.ContextSourceRow{srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, 6)}
	f.global = []agentreport.ContextSourceRow{
		srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, 9),
		srcRow("agents", "alpha", agentreport.GroupPlugin, 0, 2, 0),
	}

	assert.Equal(t, 0, f.run(t, f.wb))
	assert.Empty(t, f.rows(t))
	assert.Equal(t, 1, f.globalCalls, "the global rules read the install-wide sources")
}

func TestProposeContext_GlobalFiledOnce(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, 6)}
	other, _ := f.d.workbench(t, "beta", 0)

	assert.Equal(t, 1, f.run(t, f.wb))
	assert.Equal(t, 0, f.run(t, other))
	ps := f.rows(t)
	require.Len(t, ps, 1)
	assert.Equal(t, int64(0), ps[0].WorkbenchID)
}

// unusedEverything is one unused plugin, one unused server and the unused
// connectors.
func unusedEverything() []agentreport.ContextSourceRow {
	return []agentreport.ContextSourceRow{
		srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, 6),
		srcRow("mcp", "alpha-docs", agentreport.GroupMCPServer, 800, 0, 6),
		srcRow("mcp", agentreport.ConnectorsGroup, agentreport.GroupConnectors, 2000, 0, 6),
	}
}

func TestProposeContext_UnreadableSettingsFilesNothingForIt(t *testing.T) {
	t.Run("settings.json", func(t *testing.T) {
		f := newCtxFixture(t)
		f.global = unusedEverything()
		writeHomeFile(t, claudeSettingsPath(f.home), "not json")
		writeHomeFile(t, memoryPath(f.home, f.folder), strings.Repeat("- a memory line\n", 600))

		f.run(t, f.wb)
		ps := f.rows(t)
		assert.Empty(t, onlyDest(ps, DestPluginOff))
		assert.Empty(t, onlyDest(ps, DestConnectorsOff))
		assert.Len(t, onlyDest(ps, DestMCPServerOff), 1, "the server rule reads another file")
		assert.Len(t, onlyDest(ps, DestMemoryIndex), 1, "the memory rule still runs")
	})
	t.Run(".claude.json", func(t *testing.T) {
		f := newCtxFixture(t)
		f.global = unusedEverything()
		writeHomeFile(t, claudeJSONPath(f.home), "[1, 2]")

		f.run(t, f.wb)
		ps := f.rows(t)
		assert.Empty(t, onlyDest(ps, DestMCPServerOff))
		assert.Len(t, onlyDest(ps, DestPluginOff), 1)
		assert.Len(t, onlyDest(ps, DestConnectorsOff), 1)
	})
}

func TestProposeContext_UsedPluginSkipped(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{
		srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 3, 6),
		srcRow("mcp", "alpha-docs", agentreport.GroupMCPServer, 800, 1, 6),
	}
	assert.Equal(t, 0, f.run(t, f.wb))
	assert.Empty(t, f.rows(t))
}

func TestProposeContext_LightSourceSkipped(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{srcRow("skills", "alpha", agentreport.GroupPlugin, ctxUnusedMinTokens-1, 0, 6)}
	assert.Equal(t, 0, f.run(t, f.wb))
}

func TestProposeContext_ProtectedSkipped(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{
		srcRow("skills", "superpowers", agentreport.GroupPlugin, 5000, 0, 6),
		srcRow("agents", "pr-review-toolkit", agentreport.GroupPlugin, 3000, 0, 6),
		srcRow("mcp", "watchtower-workbench", agentreport.GroupMCPServer, 4000, 0, 6),
	}
	assert.Equal(t, 0, f.run(t, f.wb))
	assert.Empty(t, f.rows(t))
}

func TestProposeContext_ConnectorsOnlyWhenAllUnused(t *testing.T) {
	t.Run("one connector used", func(t *testing.T) {
		f := newCtxFixture(t)
		f.global = []agentreport.ContextSourceRow{
			srcRow("mcp", agentreport.ConnectorsGroup, agentreport.GroupConnectors, 2000, 0, 6),
			srcRow("tools", agentreport.ConnectorsGroup, agentreport.GroupConnectors, 0, 1, 0),
		}
		assert.Equal(t, 0, f.run(t, f.wb))
	})
	t.Run("all unused", func(t *testing.T) {
		f := newCtxFixture(t)
		f.global = []agentreport.ContextSourceRow{
			srcRow("mcp", agentreport.ConnectorsGroup, agentreport.GroupConnectors, 2000, 0, 6),
		}
		require.Equal(t, 1, f.run(t, f.wb))
		p := f.rows(t)[0]
		assert.Equal(t, DestConnectorsOff, p.Destination)
		assert.Equal(t, "connectors", p.SourceKey)
		assert.Empty(t, p.BeforeText, "the env key is absent")
		assert.Equal(t, `"false"`, p.AfterText)
	})
	t.Run("already off", func(t *testing.T) {
		f := newCtxFixture(t)
		writeHomeFile(t, claudeSettingsPath(f.home), `{"env": {"ENABLE_CLAUDEAI_MCP_SERVERS": "false"}}`)
		f.global = []agentreport.ContextSourceRow{
			srcRow("mcp", agentreport.ConnectorsGroup, agentreport.GroupConnectors, 2000, 0, 6),
		}
		assert.Equal(t, 0, f.run(t, f.wb))
	})
}

// claudeMD is a CLAUDE.md of small sections plus one of big bytes.
func claudeMD(small, big int) string {
	var b strings.Builder
	b.WriteString("# Project\n\nIntro.\n\n")
	for i := range small {
		b.WriteString("## Small " + string(rune('a'+i)) + "\n")
		b.WriteString(strings.Repeat("x", 3*1024) + "\n")
	}
	if big > 0 {
		b.WriteString("## Big section\n")
		b.WriteString(strings.Repeat("y", big) + "\n")
	}
	return b.String()
}

func TestProposeContext_ClaudeMDSections(t *testing.T) {
	t.Run("big file with a big section", func(t *testing.T) {
		f := newCtxFixture(t)
		writeHomeFile(t, filepath.Join(f.folder, "CLAUDE.md"), claudeMD(4, 10*1024))
		require.Equal(t, 1, f.run(t, f.wb))
		p := f.rows(t)[0]
		assert.Equal(t, DestRepoClaudeMD, p.Destination)
		assert.Equal(t, "restructure", p.Kind)
		assert.Equal(t, f.wb, p.WorkbenchID, "a repository proposal keeps its workbench")
		assert.Empty(t, p.SourceKey)
		assert.Empty(t, p.AfterText)
		var refs []string
		for _, e := range p.Evidence {
			refs = append(refs, e.Ref)
		}
		joined := strings.Join(refs, "\n")
		assert.Contains(t, joined, "## Big section · 10.0 KB")
		assert.NotContains(t, joined, "Small a", "only the big sections are named")
		assert.Contains(t, joined, "CLAUDE.md · ")
	})
	t.Run("big file of small sections", func(t *testing.T) {
		f := newCtxFixture(t)
		writeHomeFile(t, filepath.Join(f.folder, "CLAUDE.md"), claudeMD(8, 0))
		assert.Equal(t, 0, f.run(t, f.wb))
	})
	t.Run("small file", func(t *testing.T) {
		f := newCtxFixture(t)
		writeHomeFile(t, filepath.Join(f.folder, "CLAUDE.md"), claudeMD(0, 9*1024))
		assert.Equal(t, 0, f.run(t, f.wb))
	})
	t.Run("no file", func(t *testing.T) {
		f := newCtxFixture(t)
		assert.Equal(t, 0, f.run(t, f.wb))
	})
}

func TestProposeContext_MemoryIndex(t *testing.T) {
	f := newCtxFixture(t)
	writeHomeFile(t, memoryPath(f.home, f.folder), strings.Repeat("- a memory line\n", 600))
	other, _ := f.d.workbench(t, "beta", 0)
	w, err := f.d.GetWorkbench(other)
	require.NoError(t, err)
	writeHomeFile(t, memoryPath(f.home, w.FolderPath), strings.Repeat("- a line\n", 10))

	require.Equal(t, 1, f.run(t, f.wb))
	assert.Equal(t, 0, f.run(t, other), "a small index files nothing")
	p := f.rows(t)[0]
	assert.Equal(t, DestMemoryIndex, p.Destination)
	assert.Equal(t, "restructure", p.Kind)
	assert.Equal(t, "memory", p.SourceKey)
	assert.Equal(t, f.wb, p.WorkbenchID)
	assert.Equal(t, "start_tokens", p.Metric)
	assert.NotEmpty(t, p.Evidence)
}

func TestProposeContext_TooFewMeasuredSessions(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{
		srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, judgeMinSessions-1),
		srcRow("mcp", "alpha-docs", agentreport.GroupMCPServer, 800, 0, judgeMinSessions-1),
		srcRow("mcp", agentreport.ConnectorsGroup, agentreport.GroupConnectors, 2000, 0, judgeMinSessions-1),
	}
	f.facts = judgeMinSessions - 1
	writeHomeFile(t, memoryPath(f.home, f.folder), strings.Repeat("- a memory line\n", 600))
	writeHomeFile(t, filepath.Join(f.folder, "CLAUDE.md"), claudeMD(4, 10*1024))

	assert.Equal(t, 0, f.run(t, f.wb))
	assert.Empty(t, f.rows(t))
}

func TestProposeContext_DeclinedNeverReturns(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, 6)}
	writeHomeFile(t, memoryPath(f.home, f.folder), strings.Repeat("- a memory line\n", 600))
	require.Equal(t, 2, f.run(t, f.wb))
	for _, p := range f.rows(t) {
		require.NoError(t, f.d.DecideCoachProposal(p.ID, "open", "declined", ctxNow))
	}
	// Auto-memory adds a line: the index is not new enough to ask again.
	writeHomeFile(t, memoryPath(f.home, f.folder), strings.Repeat("- a memory line\n", 601))

	assert.Equal(t, 0, f.run(t, f.wb))
	assert.Len(t, f.rows(t), 2)
}

func TestProposeContext_ElsewhereEvidence(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{
		srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, 6),
		srcRow("mcp", "alpha-docs", agentreport.GroupMCPServer, 800, 0, 6),
	}
	require.Equal(t, 2, f.run(t, f.wb))
	for _, p := range f.rows(t) {
		assert.Contains(t, p.Evidence, db.CoachEvidence{Kind: "elsewhere", Ref: "on in: acme"}, p.Destination)
		for _, e := range p.Evidence {
			assert.NotContains(t, e.Ref, ctxSecret)
			assert.NotContains(t, e.Ref, "/work/", "basenames only")
		}
	}
	server := onlyDest(f.rows(t), DestMCPServerOff)
	require.Len(t, server, 1)
	assert.Equal(t, "alpha-docs", server[0].SourceKey)
	assert.Equal(t, "present", server[0].BeforeText)
	assert.Empty(t, server[0].AfterText)
}

func TestProposeContext_Idempotent(t *testing.T) {
	f := newCtxFixture(t)
	f.global = unusedEverything()
	writeHomeFile(t, memoryPath(f.home, f.folder), strings.Repeat("- a memory line\n", 600))
	writeHomeFile(t, filepath.Join(f.folder, "CLAUDE.md"), claudeMD(4, 10*1024))

	assert.Equal(t, 5, f.run(t, f.wb))
	assert.Equal(t, 0, f.run(t, f.wb))
	assert.Len(t, f.rows(t), 5)
}

func TestProposeContext_RussianTitles(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, 6)}
	env := f.env()
	env.Lang = agentreport.Russian
	_, err := ProposeContext(env, f.wb)
	require.NoError(t, err)
	p := f.rows(t)[0]
	assert.Contains(t, p.Title, "плагин")
	assert.Contains(t, p.Why, "1200")
}

func TestPreviewContext_WritesNothing(t *testing.T) {
	f := newCtxFixture(t)
	f.global = unusedEverything()
	ps, err := PreviewContext(f.env(), f.wb)
	require.NoError(t, err)
	assert.Len(t, ps, 3)
	assert.Empty(t, f.rows(t))
}
