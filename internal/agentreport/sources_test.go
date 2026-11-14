package agentreport

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
)

func src(sid, agent, kind, name string, bytes int64) agentlogdb.AgentContextSource {
	return agentlogdb.AgentContextSource{SessionUUID: sid, AgentID: agent, Kind: kind, Name: name, Bytes: bytes}
}

// rowOf finds the row of part and group kind/group, failing when absent.
func sourceRowOf(t *testing.T, rows []ContextSourceRow, part, groupKind, group string) ContextSourceRow {
	t.Helper()
	for _, r := range rows {
		if r.Part == part && r.GroupKind == groupKind && r.Group == group {
			return r
		}
	}
	require.Failf(t, "no row", "%s %s %q in %+v", part, groupKind, group, rows)
	return ContextSourceRow{}
}

// groupCalls sums the calls of every row of a group.
func groupCalls(rows []ContextSourceRow, groupKind, group string) int {
	n := 0
	for _, r := range rows {
		if r.GroupKind == groupKind && r.Group == group {
			n += r.Calls
		}
	}
	return n
}

func TestGroupOf(t *testing.T) {
	for _, tc := range []struct{ kind, name, group, groupKind string }{
		{"skill", "acme:review", "acme", GroupPlugin},
		{"skill", "acme:sub:review", "acme", GroupPlugin},
		{"agent", "acme-kit:code-reviewer", "acme-kit", GroupPlugin},
		{"tool", "mcp__claude_ai_Example_Mail__search", ConnectorsGroup, GroupConnectors},
		{"mcp_instructions", "claude.ai Example Mail", ConnectorsGroup, GroupConnectors},
		{"tool", "mcp__acme-srv__do_thing", "acme-srv", GroupMCPServer},
		{"tool", "mcp__acme-srv", "acme-srv", GroupMCPServer},
		{"mcp_instructions", "acme-srv", "acme-srv", GroupMCPServer},
		{"mcp_instructions", "plugin:acme:srv", "plugin_acme_srv", GroupMCPServer}, // the tool-id form of the display name
		{"tool", "Bash", "", GroupBuiltin},
		{"tool", "Skill", "", GroupBuiltin},
		{"agent", "general-purpose", "", GroupBuiltin},
		{"agent", "Explore", "", GroupBuiltin},
		{"skill", "pdf", "", GroupUser},
		{"agent", "my-reviewer", "", GroupUser},
	} {
		t.Run(tc.kind+"/"+tc.name, func(t *testing.T) {
			g, k := GroupOf(tc.kind, tc.name)
			assert.Equal(t, tc.group, g)
			assert.Equal(t, tc.groupKind, k)
		})
	}

	t.Run("project", func(t *testing.T) {
		folder := t.TempDir()
		require.NoError(t, os.MkdirAll(filepath.Join(folder, ".claude", "skills", "local-skill"), 0o755))
		require.NoError(t, os.MkdirAll(filepath.Join(folder, ".claude", "agents"), 0o755))
		require.NoError(t, os.WriteFile(filepath.Join(folder, ".claude", "agents", "local-agent.md"), []byte("x"), 0o600))
		gs := newGrouper(folder)
		for _, tc := range []struct{ kind, name, groupKind string }{
			{"skill", "local-skill", GroupProject},
			{"agent", "local-agent", GroupProject},
			{"skill", "pdf", GroupUser},
			{"agent", "my-reviewer", GroupUser},
			{"skill", "acme:local-skill", GroupPlugin},
			{"tool", "Bash", GroupBuiltin},
		} {
			_, k := gs.of(tc.kind, tc.name)
			assert.Equal(t, tc.groupKind, k, "%s %s", tc.kind, tc.name)
		}
		_, k := newGrouper("").of("skill", "local-skill")
		assert.Equal(t, GroupUser, k, "no folder: never project")
	})
}

func TestSources_TokensFromBytes(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 4000, 0, 0)) // 4000 tokens over 8000 bytes: 0.5 per byte
	s.add("s2", 0, ownerTurn())          // no call: 1 / defaultBytesPerToken
	parts := []agentlogdb.AgentContextPart{
		part("s1", "", "skills", 2000), part("s1", "", "tools", 6000),
		part("s2", "", "skills", 2600),
	}
	sources := []agentlogdb.AgentContextSource{
		src("s1", "", "skill", "acme:a", 1000),
		src("s1", "", "skill", "acme:b", 200),
		src("s1", "", "agent", "acme:helper", 600),
		src("s1", "", "tool", "mcp__acme-srv__x", 3000),
		src("s1", "", "mcp_instructions", "acme-srv", 400),
		src("s1", "a1", "tool", "Bash", 9999), // a subagent lane: not the start context
		src("s2", "", "skill", "acme:a", 2600),
	}
	r := Context(factsOf(s), s, parts, sources, "")
	assert.Equal(t, ContextSourceRow{Part: "tools", Group: "acme-srv", GroupKind: GroupMCPServer, Tokens: 1500, Measured: 1},
		sourceRowOf(t, r.Sources, "tools", GroupMCPServer, "acme-srv"))
	// s1: (1000 + 200) * 0.5 = 600; s2: 2600 / 2.6 = 1000; the median of two is their mean.
	assert.Equal(t, ContextSourceRow{Part: "skills", Group: "acme", GroupKind: GroupPlugin, Tokens: 800, Measured: 2},
		sourceRowOf(t, r.Sources, "skills", GroupPlugin, "acme"))
	assert.Equal(t, 300, sourceRowOf(t, r.Sources, "agents", GroupPlugin, "acme").Tokens)
	assert.Equal(t, 200, sourceRowOf(t, r.Sources, "mcp", GroupMCPServer, "acme-srv").Tokens)
	assert.Len(t, r.Sources, 4, "the subagent lane's Bash adds no row")
	assert.Equal(t, "tools", r.Sources[0].Part, "largest first")
}

func TestSources_CallsJoined(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 1000, 0, 0))
	s.add("s1", sec, agentlogdb.AgentReportEvent{Kind: "skill", Name: "acme:review", Trigger: "proactive"})
	s.add("s1", 2*sec, agentlogdb.AgentReportEvent{Kind: "skill", Name: "review", Trigger: "read"}) // the bare folder name
	s.add("s1", 3*sec, tl("Agent", "acme:helper", sec, "ok"))
	s.add("s1", 4*sec, tl("mcp__acme-srv__x", "", sec, "ok"))
	s.add("s1", 5*sec, result("a1", "mcp__acme-srv__y", "", 10)) // a subagent's call is a use too
	s.add("s1", 6*sec, tl("mcp__claude_ai_Example_Mail__search", "", sec, "ok"))
	s.add("s1", 7*sec, tl("Bash", "go test", sec, "ok"))
	sources := []agentlogdb.AgentContextSource{
		src("s1", "", "skill", "acme:review", 100), src("s1", "", "skill", "acme:unused", 100),
		src("s1", "", "agent", "acme:helper", 100),
		src("s1", "", "tool", "mcp__acme-srv__x", 100), src("s1", "", "tool", "mcp__acme-srv__y", 100),
		src("s1", "", "mcp_instructions", "acme-srv", 100),
		src("s1", "", "tool", "mcp__claude_ai_Example_Mail__search", 100),
		src("s1", "", "mcp_instructions", "claude.ai Example Mail", 100),
		src("s1", "", "tool", "Bash", 100), src("s1", "", "tool", "Agent", 100),
	}
	parts := []agentlogdb.AgentContextPart{part("s1", "", "tools", 1000)}
	r := Context(factsOf(s), s, parts, sources, "")
	assert.Equal(t, 2, sourceRowOf(t, r.Sources, "skills", GroupPlugin, "acme").Calls, "by skill name, a bare name resolved")
	assert.Equal(t, 1, sourceRowOf(t, r.Sources, "agents", GroupPlugin, "acme").Calls, "by subagent_type")
	assert.Equal(t, 3, groupCalls(r.Sources, GroupPlugin, "acme"), "summed per group")
	assert.Equal(t, 2, sourceRowOf(t, r.Sources, "tools", GroupMCPServer, "acme-srv").Calls)
	assert.Equal(t, 0, sourceRowOf(t, r.Sources, "mcp", GroupMCPServer, "acme-srv").Calls, "instructions have no calls of their own")
	assert.Equal(t, 2, groupCalls(r.Sources, GroupMCPServer, "acme-srv"))
	assert.Equal(t, 1, groupCalls(r.Sources, GroupConnectors, ConnectorsGroup))
	assert.Equal(t, 2, sourceRowOf(t, r.Sources, "tools", GroupBuiltin, "").Calls, "Bash and the Agent tool itself")
}

// A deferred MCP tool has no tool source: only its server's instructions are
// measured. Its calls still belong to the group (a used server is never "0 calls").
func TestSources_DeferredServerCallsCount(t *testing.T) {
	for _, tc := range []struct{ display, tool, group, groupKind string }{
		{"acme-srv", "mcp__acme-srv__x", "acme-srv", GroupMCPServer},
		{"claude.ai Example Mail", "mcp__claude_ai_Example_Mail__search", ConnectorsGroup, GroupConnectors},
	} {
		t.Run(tc.groupKind, func(t *testing.T) {
			s := evset{}
			s.add("s1", 0, call("", 1000, 0, 0))
			for i := range 5 {
				s.add("s1", time.Duration(i+1)*sec, tl(tc.tool, "", sec, "ok"))
			}
			parts := []agentlogdb.AgentContextPart{part("s1", "", "mcp", 1000)}
			sources := []agentlogdb.AgentContextSource{src("s1", "", "mcp_instructions", tc.display, 400)}
			r := Context(factsOf(s), s, parts, sources, "")
			assert.Equal(t, 5, groupCalls(r.Sources, tc.groupKind, tc.group))
			assert.Equal(t, ContextSourceRow{Part: "mcp", Group: tc.group, GroupKind: tc.groupKind, Tokens: 400, Measured: 1},
				sourceRowOf(t, r.Sources, "mcp", tc.groupKind, tc.group))
			assert.Equal(t, ContextSourceRow{Part: "tools", Group: tc.group, GroupKind: tc.groupKind, Calls: 5},
				sourceRowOf(t, r.Sources, "tools", tc.groupKind, tc.group), "a calls-only row: not measured, never a 0 weight")
		})
	}
}

func TestSources_UnmeasuredSessionsNotZero(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 1000, 0, 0))
	s.add("s2", 0, call("", 1000, 0, 0)) // parsed before v5: no source rows
	s.add("s2", sec, agentlogdb.AgentReportEvent{Kind: "skill", Name: "acme:review", Trigger: "slash"})
	s.add("s2", 2*sec, tl("mcp__other__x", "", sec, "ok")) // a group never measured: no row
	parts := []agentlogdb.AgentContextPart{part("s1", "", "skills", 1000), part("s2", "", "skills", 1000)}
	sources := []agentlogdb.AgentContextSource{src("s1", "", "skill", "acme:review", 500)}
	r := Context(factsOf(s), s, parts, sources, "")
	assert.Equal(t, []ContextSourceRow{{Part: "skills", Group: "acme", GroupKind: GroupPlugin, Tokens: 500, Calls: 1, Measured: 1}}, r.Sources,
		"s2 is not a 0: its tokens are not measured, its calls still count")

	assert.Equal(t, []ContextSourceRow{}, Context(factsOf(s), s, parts, nil, "").Sources, "nothing measured: no rows, never zeros")
}

func TestStartTokensMedian(t *testing.T) {
	sessions := []agentlogdb.AgentReportSession{
		{SessionUUID: "s1", Agent: "claude", Facts: true}, {SessionUUID: "s2", Agent: "claude", Facts: true},
		{SessionUUID: "s3", Agent: "claude", Facts: true}, {SessionUUID: "s4", Agent: "claude", Facts: true},
		{SessionUUID: "s5", Agent: "claude"}, // without the v2 facts
	}
	parts := []agentlogdb.AgentContextPart{
		part("s1", "", "system", 1300), part("s1", "", "tools", 1300), // 2600 bytes = 1000 tokens
		part("s1", "a1", "system", 99999), // a subagent lane
		part("s2", "", "tools", 5200),
		part("s3", "", "tools", 7800),
		part("s4", "a1", "tools", 5200), // no main lane
		part("s5", "", "tools", 99999),
	}
	tokens, n := StartTokensMedian(sessions, parts)
	assert.Equal(t, 2000, tokens)
	assert.Equal(t, 3, n)

	tokens, n = StartTokensMedian(nil, nil)
	assert.Zero(t, tokens)
	assert.Zero(t, n)
}

// putSourcesSession stores a parser-v5 session of wb with one main call, its
// baseline parts, its source rows and n Skill calls of skill.
func putSourcesSession(t *testing.T, d testDBs, wb int64, id string, sources []agentlogdb.AgentContextSource, skill string, n int) {
	t.Helper()
	path := "/tmp/x/" + id + ".jsonl"
	at := func(i int) string { return t0.Add(time.Duration(i) * time.Second).Format(tsLayout) }
	evs := []agentlogdb.AgentLogEvent{{Key: id + ":0", Kind: "api_call", Name: "claude-opus-5-5", InputTokens: 1000, TS: at(0)}}
	for i := range n {
		evs = append(evs, agentlogdb.AgentLogEvent{Key: fmt.Sprintf("%s:s%d", id, i), Kind: "skill", Name: skill, Trigger: "proactive", TS: at(i + 1)})
	}
	for i := range evs {
		evs[i].SessionUUID, evs[i].SrcPath, evs[i].SrcOffset = id, path, int64(i)
	}
	for i := range sources {
		sources[i].SessionUUID = id
	}
	_, err := d.al.ApplyAgentLogBatch(agentlogdb.AgentLogBatch{
		File: agentlogdb.AgentLogFile{Path: path, Agent: "claude", ReadOffset: 10, ParserVersion: 5}, ExpectOffset: -1,
		Sessions: []agentlogdb.AgentLogSession{{SessionUUID: id, Agent: "claude", ProjectID: &wb, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: path, StartedAt: at(0), EndedAt: at(n + 1), Model: "claude-opus-5-5"}},
		Events:         evs,
		ContextParts:   []agentlogdb.AgentContextPart{{SessionUUID: id, Part: "skills", Bytes: 2000}},
		ContextSources: sources,
	})
	require.NoError(t, err)
}

func TestGlobalSources_SumsCallsAcrossWorkbenches(t *testing.T) {
	d, a := buildDB(t)
	b, err := d.CreateWorkbench("b", t.TempDir())
	require.NoError(t, err)
	off, err := d.CreateWorkbench("off", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, d.SetWorkbenchAgentAnalytics(a, true))
	require.NoError(t, d.SetWorkbenchAgentAnalytics(b, true))
	listing := func() []agentlogdb.AgentContextSource {
		return []agentlogdb.AgentContextSource{{Kind: "skill", Name: "acme:review", Bytes: 1000}, {Kind: "skill", Name: "unused:x", Bytes: 600}}
	}
	putSourcesSession(t, d, a, "sa", listing(), "acme:review", 0)
	putSourcesSession(t, d, b, "sb", listing(), "acme:review", 3)
	putSourcesSession(t, d, off, "so", listing(), "unused:x", 5) // analytics off: not counted

	since, now := t0.Add(-24*time.Hour), t0.Add(24*time.Hour)
	ova, err := BuildOverview(d.DB, d.al, a, since, now, English, AgentAll)
	require.NoError(t, err)
	assert.Zero(t, groupCalls(ova.Context.Sources, GroupPlugin, "acme"), "workbench A alone: 0 calls")

	rows, err := GlobalSources(d.DB, d.al, since, now)
	require.NoError(t, err)
	acme := sourceRowOf(t, rows, "skills", GroupPlugin, "acme")
	assert.Equal(t, 3, acme.Calls)
	assert.Equal(t, 2, acme.Measured)
	assert.Equal(t, 500, acme.Tokens, "1000 tokens over 2000 bytes, the same in both")
	assert.Equal(t, 0, sourceRowOf(t, rows, "skills", GroupPlugin, "unused").Calls, "the off workbench's calls are not counted")
	assert.Equal(t, 2, sourceRowOf(t, rows, "skills", GroupPlugin, "unused").Measured)

	later, err := GlobalSources(d.DB, d.al, now, now.Add(time.Hour))
	require.NoError(t, err)
	assert.Equal(t, []ContextSourceRow{}, later, "outside the window: nothing")
}

// MeasuredSessions is the overview's Context.FactsSessions without the report.
func TestMeasuredSessions_MatchesOverview(t *testing.T) {
	d, a := buildDB(t)
	b, err := d.CreateWorkbench("b", t.TempDir())
	require.NoError(t, err)
	putSourcesSession(t, d, a, "s1", nil, "acme:review", 0)
	putSourcesSession(t, d, a, "s2", nil, "acme:review", 1)
	putSourcesSession(t, d, b, "s3", nil, "acme:review", 0)

	since, now := t0.Add(-24*time.Hour), t0.Add(24*time.Hour)
	ov, err := BuildOverview(d.DB, d.al, a, since, now, English, AgentAll)
	require.NoError(t, err)
	n, err := MeasuredSessions(d.al, a, since, now)
	require.NoError(t, err)
	assert.Equal(t, 2, n)
	assert.Equal(t, ov.Context.FactsSessions, n)

	n, err = MeasuredSessions(d.al, a, now, now.Add(time.Hour))
	require.NoError(t, err)
	assert.Zero(t, n, "outside the window")
}
