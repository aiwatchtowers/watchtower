package coach

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
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

// ctxInstalled is installed_plugins.json with alpha's installs in dir.
func ctxInstalled(dir string) string {
	return `{"version": 2, "plugins": {
  "alpha@example-market": [{"scope": "user", "installPath": "` + dir + `/user"},
    {"scope": "project", "projectPath": "/work/acme", "installPath": "` + dir + `/acme"}],
  "superpowers@claude-plugins-official": [{"scope": "user", "installPath": "` + dir + `/sp"}]
}}`
}

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
// and the two seams faked: global are the install-wide rows, facts every
// workbench's measured sessions. plugins holds alpha's two install folders
// (user, acme), each with a skills folder only.
type ctxFixture struct {
	d       dbs
	home    string
	wb      int64
	folder  string
	plugins string
	global  []agentreport.ContextSourceRow
	facts   int
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
	f.plugins = t.TempDir()
	for _, inst := range []string{"user", "acme", "sp"} {
		writeHomeFile(t, filepath.Join(f.plugins, inst, "skills", "x", "SKILL.md"), "a skill")
		writeHomeFile(t, filepath.Join(f.plugins, inst, ".claude-plugin", "plugin.json"), `{"name": "alpha", "version": "1.0.0"}`)
	}
	writeHomeFile(t, installedPluginsPath(f.home), ctxInstalled(f.plugins))
	writeHomeFile(t, claudeJSONPath(f.home), ctxProposeClaudeJSON)
	og, om := contextGlobalSources, contextMeasuredSessions
	contextGlobalSources = func(_ *db.DB, _ *agentlogdb.DB, since, now time.Time) ([]agentreport.ContextSourceRow, error) {
		f.globalCalls++
		assert.Equal(t, ctxNow.Add(-ctxWindowDays*24*time.Hour), since)
		assert.Equal(t, ctxNow, now)
		return f.global, nil
	}
	contextMeasuredSessions = func(_ *agentlogdb.DB, _ int64, since, now time.Time) (int, error) {
		assert.Equal(t, ctxNow.Add(-ctxWindowDays*24*time.Hour), since)
		assert.Equal(t, ctxNow, now)
		return f.facts, nil
	}
	t.Cleanup(func() { contextGlobalSources, contextMeasuredSessions = og, om })
	return f
}

func (f *ctxFixture) env() ContextEnv {
	return ContextEnv{DB: f.d.DB, AgentLog: f.d.al, Home: f.home, Now: func() time.Time { return ctxNow }}
}

func (f *ctxFixture) run(t *testing.T, wbs ...int64) int {
	t.Helper()
	n, err := ProposeContext(context.Background(), f.env(), wbs)
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
	// calls-only row: called, never measured in that part). The install-wide
	// rows decide.
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

	assert.Equal(t, 1, f.run(t, f.wb, other))
	assert.Equal(t, 1, f.globalCalls, "one pass reads the install-wide sources once")
	ps := f.rows(t)
	require.Len(t, ps, 1)
	assert.Equal(t, int64(0), ps[0].WorkbenchID)
	assert.Equal(t, 0, f.run(t, other), "a later pass files it again for no workbench")
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

// claudeMDBig is a CLAUDE.md of one small section and the big sections of
// the given sizes, with the bytes of the big sections (heading lines included).
func claudeMDBig(sizes ...int) (text string, bigBytes int) {
	var b strings.Builder
	b.WriteString("# Project\n\nIntro.\n\n## Small\n" + strings.Repeat("x", 3*1024) + "\n")
	for i, n := range sizes {
		sec := "## Big " + strconv.Itoa(i) + "\n" + strings.Repeat("y", n) + "\n"
		b.WriteString(sec)
		bigBytes += len(sec)
	}
	return b.String(), bigBytes
}

func evidenceOf(p db.CoachProposal, kind string) []db.CoachEvidence {
	var out []db.CoachEvidence
	for _, e := range p.Evidence {
		if e.Kind == kind {
			out = append(out, e)
		}
	}
	return out
}

func TestProposeContext_ClaudeMDSavingTokens(t *testing.T) {
	t.Run("sum of the big sections in tokens", func(t *testing.T) {
		f := newCtxFixture(t)
		text, bigBytes := claudeMDBig(12*1024, 9*1024)
		writeHomeFile(t, filepath.Join(f.folder, "CLAUDE.md"), text)
		require.Equal(t, 1, f.run(t, f.wb))
		p := f.rows(t)[0]
		saving := evidenceOf(p, "saving_tokens")
		require.Len(t, saving, 1)
		assert.Equal(t, strconv.FormatInt(agentreport.TokensOfBytes(int64(bigBytes)), 10), saving[0].Ref)
		assert.Equal(t, "saving_tokens", p.Evidence[len(p.Evidence)-1].Kind)
		assert.Len(t, evidenceOf(p, "section"), 2, "the small section is not counted")
		// The fingerprint is the key and the size class only, as before the
		// saving item: a declined proposal does not come back for it.
		key := keyOf(DestRepoClaudeMD, f.wb, "", "", "")
		assert.Equal(t, contextFingerprint(key, "size:"+strconv.Itoa(len(text)/ctxClaudeMDMinBytes), ""), p.Fingerprint)
	})
	t.Run("same size class, other sections: same fingerprint", func(t *testing.T) {
		f := newCtxFixture(t)
		a, _ := claudeMDBig(12*1024, 9*1024)
		b, _ := claudeMDBig(8*1024, 8*1024, 5*1024)
		require.Equal(t, len(a)/ctxClaudeMDMinBytes, len(b)/ctxClaudeMDMinBytes)
		wb := &db.Workbench{ID: f.wb, FolderPath: f.folder}
		writeHomeFile(t, filepath.Join(f.folder, "CLAUDE.md"), a)
		pa, ok := claudeMDProposal(f.env(), wb, 5)
		require.True(t, ok)
		writeHomeFile(t, filepath.Join(f.folder, "CLAUDE.md"), b)
		pb, ok := claudeMDProposal(f.env(), wb, 5)
		require.True(t, ok)
		assert.NotEqual(t, evidenceOf(pa, "saving_tokens"), evidenceOf(pb, "saving_tokens"))
		assert.Equal(t, pa.Fingerprint, pb.Fingerprint)
	})
	t.Run("the saving keeps its slot under the evidence cap", func(t *testing.T) {
		f := newCtxFixture(t)
		sizes := make([]int, maxEvidence+2)
		for i := range sizes {
			sizes[i] = 8 * 1024
		}
		text, bigBytes := claudeMDBig(sizes...)
		writeHomeFile(t, filepath.Join(f.folder, "CLAUDE.md"), text)
		require.Equal(t, 1, f.run(t, f.wb))
		p := f.rows(t)[0]
		require.Len(t, p.Evidence, maxEvidence)
		assert.Len(t, evidenceOf(p, "section"), maxEvidence-2)
		last := p.Evidence[maxEvidence-1]
		assert.Equal(t, "saving_tokens", last.Kind)
		assert.Equal(t, strconv.FormatInt(agentreport.TokensOfBytes(int64(bigBytes)), 10), last.Ref,
			"every big section counts, shown or not")
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
	assert.Empty(t, evidenceOf(p, "saving_tokens"), "the agent decides what moves: no saving")
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
	_, err := ProposeContext(context.Background(), env, []int64{f.wb})
	require.NoError(t, err)
	p := f.rows(t)[0]
	assert.Contains(t, p.Title, "плагин")
	assert.Contains(t, p.Why, "1200")
}

func TestPreviewContext_WritesNothing(t *testing.T) {
	f := newCtxFixture(t)
	f.global = unusedEverything()
	ps, err := PreviewContext(context.Background(), f.env(), []int64{f.wb})
	require.NoError(t, err)
	assert.Len(t, ps, 3)
	assert.Empty(t, f.rows(t))
}

func TestProposeContext_PluginUsedThroughItsServerSkipped(t *testing.T) {
	f := newCtxFixture(t)
	// alpha's skills are never called, but its own server is, every session.
	f.global = []agentreport.ContextSourceRow{
		srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, 6),
		srcRow("tools", "plugin_alpha_docs", agentreport.GroupMCPServer, 0, 3, 0),
	}
	assert.Equal(t, 0, f.run(t, f.wb))
	assert.Empty(t, f.rows(t))
}

func TestProposeContext_UnusedPluginWeighsItsServer(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{
		srcRow("skills", "alpha", agentreport.GroupPlugin, 300, 0, 6),
		srcRow("mcp", "plugin_alpha_docs", agentreport.GroupMCPServer, 900, 0, 6),
		srcRow("mcp", "plugin_other_docs", agentreport.GroupMCPServer, 5000, 7, 6), // another plugin's
	}
	require.Equal(t, 1, f.run(t, f.wb), "300 tokens alone are under the threshold; with its server they are not")
	p := f.rows(t)[0]
	assert.Equal(t, DestPluginOff, p.Destination)
	assert.Equal(t, "alpha · 1200 tok · 0 calls in Watchtower sessions (all workbenches) in 30 days", p.Evidence[0].Ref)
}

// A plugin can work with no calls at all, through hooks or an output style:
// it is never proposed, nor one whose install folder cannot be read.
func TestProposeContext_PluginWithHooksOrStylesSkipped(t *testing.T) {
	unused := []agentreport.ContextSourceRow{srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, 6)}
	for name, prep := range map[string]func(t *testing.T, f *ctxFixture){
		"hooks.json": func(t *testing.T, f *ctxFixture) {
			writeHomeFile(t, filepath.Join(f.plugins, "acme", "hooks", "hooks.json"), `{"hooks": {}}`)
		},
		"manifest hooks": func(t *testing.T, f *ctxFixture) {
			writeHomeFile(t, filepath.Join(f.plugins, "user", ".claude-plugin", "plugin.json"), `{"name": "alpha", "hooks": "./h.json"}`)
		},
		"output styles": func(t *testing.T, f *ctxFixture) {
			writeHomeFile(t, filepath.Join(f.plugins, "user", "output-styles", "terse.md"), "style")
		},
		"manifest output styles": func(t *testing.T, f *ctxFixture) {
			writeHomeFile(t, filepath.Join(f.plugins, "user", ".claude-plugin", "plugin.json"), `{"outputStyles": "./s"}`)
		},
		".lsp.json": func(t *testing.T, f *ctxFixture) {
			writeHomeFile(t, filepath.Join(f.plugins, "acme", ".lsp.json"), `{"go": {}}`)
		},
		"manifest lsp servers": func(t *testing.T, f *ctxFixture) {
			writeHomeFile(t, filepath.Join(f.plugins, "user", ".claude-plugin", "plugin.json"), `{"lspServers": "./lsp.json"}`)
		},
		"bad manifest": func(t *testing.T, f *ctxFixture) {
			writeHomeFile(t, filepath.Join(f.plugins, "user", ".claude-plugin", "plugin.json"), "not json")
		},
		"install folder gone": func(t *testing.T, f *ctxFixture) {
			require.NoError(t, os.RemoveAll(filepath.Join(f.plugins, "acme")))
		},
		"no install folder known": func(t *testing.T, f *ctxFixture) {
			writeHomeFile(t, installedPluginsPath(f.home), `{"version": 2, "plugins": {"alpha@example-market": [{"scope": "user"}]}}`)
		},
	} {
		t.Run(name, func(t *testing.T) {
			f := newCtxFixture(t)
			f.global = unused
			prep(t, f)
			assert.Equal(t, 0, f.run(t, f.wb))
		})
	}
	t.Run("skills only", func(t *testing.T) {
		f := newCtxFixture(t)
		f.global = unused
		assert.Equal(t, 1, f.run(t, f.wb), "the control: the same plugin with skills only is proposed")
	})
}

func TestProposeContext_ConnectorsDeclinedStaysDeclined(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{
		srcRow("mcp", agentreport.ConnectorsGroup, agentreport.GroupConnectors, 2000, 0, 6),
	}
	require.Equal(t, 1, f.run(t, f.wb))
	require.NoError(t, f.d.DecideCoachProposal(f.rows(t)[0].ID, "open", "declined", ctxNow))
	// Something writes the key as "true": still on, still declined.
	writeHomeFile(t, claudeSettingsPath(f.home), `{"env": {"ENABLE_CLAUDEAI_MCP_SERVERS": "true"}}`)
	assert.Equal(t, 0, f.run(t, f.wb))
}

func TestProposeContext_CancelledFilesNothing(t *testing.T) {
	f := newCtxFixture(t)
	f.global = unusedEverything()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	n, err := ProposeContext(ctx, f.env(), []int64{f.wb})
	assert.ErrorIs(t, err, context.Canceled)
	assert.Zero(t, n)
	assert.Empty(t, f.rows(t))
}

func TestProposeContext_WorkbenchErrorDoesNotStopOthers(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{srcRow("skills", "alpha", agentreport.GroupPlugin, 1200, 0, 6)}
	writeHomeFile(t, memoryPath(f.home, f.folder), strings.Repeat("- a memory line\n", 600))
	n, err := ProposeContext(context.Background(), f.env(), []int64{9999, f.wb})
	assert.Error(t, err, "the missing workbench is reported")
	assert.Equal(t, 2, n, "the global row and this workbench's memory row are still filed")
}

// A pass stops between workbenches once ctx is cancelled.
func TestPreviewContext_StopsBetweenWorkbenches(t *testing.T) {
	f := newCtxFixture(t)
	other, _ := f.d.workbench(t, "beta", 0)
	ctx, cancel := context.WithCancel(context.Background())
	var seen []int64
	contextMeasuredSessions = func(_ *agentlogdb.DB, wb int64, _, _ time.Time) (int, error) {
		seen = append(seen, wb)
		cancel()
		return 0, nil
	}
	_, err := PreviewContext(ctx, f.env(), []int64{f.wb, other})
	assert.ErrorIs(t, err, context.Canceled)
	assert.Equal(t, []int64{f.wb}, seen)
}

// Overlapping plugin ids ("alpha", "alpha_x"): a server's tokens go to the
// longest match only, its calls to both.
func TestProposeContext_PluginServerTokensToLongestMatch(t *testing.T) {
	f := newCtxFixture(t)
	f.global = []agentreport.ContextSourceRow{
		srcRow("skills", "alpha", agentreport.GroupPlugin, 300, 0, 6),
		srcRow("skills", "alpha_x", agentreport.GroupPlugin, 300, 0, 6),
		srcRow("mcp", "plugin_alpha_x_docs", agentreport.GroupMCPServer, 900, 0, 6),
	}
	assert.Equal(t, 0, f.run(t, f.wb), "alpha stays at 300 tokens: alpha_x's server is not its weight")

	groups := foldPluginServers(sourceGroups(f.global))
	byName := map[string]sourceGroup{}
	for _, g := range groups {
		byName[g.group] = g
	}
	assert.Equal(t, 300, byName["alpha"].tokens)
	assert.Equal(t, 1200, byName["alpha_x"].tokens)

	f.global = append(f.global, srcRow("tools", "plugin_alpha_x_docs", agentreport.GroupMCPServer, 0, 2, 0))
	groups = foldPluginServers(sourceGroups(f.global))
	for _, g := range groups {
		if g.kind == agentreport.GroupPlugin {
			assert.Equal(t, 2, g.calls, "calls count for every matching plugin: %s", g.group)
		}
	}
}
