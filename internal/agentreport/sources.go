package agentreport

import (
	"cmp"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

// Group kinds of a start-context source (ContextSourceRow.GroupKind).
const (
	GroupPlugin     = "plugin"               // Group = the plugin id (the "<plugin>:" prefix)
	GroupMCPServer  = "mcp_server"           // Group = the server's tool-id name
	GroupConnectors = "claude_ai_connectors" // Group = ConnectorsGroup
	GroupUser       = "user"                 // an unprefixed skill or agent outside the folder
	GroupProject    = "project"              // an unprefixed skill or agent in the folder's .claude/
	GroupBuiltin    = "builtin"              // a built-in tool or agent: can't be changed
)

// ConnectorsGroup is the Group of every claude.ai connector (the servers
// whose tool-id name starts claudeAIServerPrefix).
const ConnectorsGroup = "claude.ai"

const claudeAIServerPrefix = "claude_ai_"

// builtinAgents are the subagent types Claude Code ships: listed in the
// context, but no plugin, user or project setting adds them.
var builtinAgents = map[string]bool{
	"general-purpose": true, "Explore": true, "Plan": true, "statusline-setup": true,
	"output-style-setup": true, "claude-code-guide": true,
}

// ContextSourceRow is what one group's sources of one baseline part (skills,
// agents, tools, mcp) add to a session's start context and how often they
// were called in the period. Tokens is the median over the Measured sessions
// that list the group's sources of this part (the main lane, before its
// first call); a session parsed before parser v5 is not measured, never a 0.
// Calls counts every session of the period, measured or not, every lane:
// Skill calls by skill name (skills), Agent calls by subagent_type (agents),
// tool calls by tool name (tools); server instructions (mcp) have no calls
// of their own. A group's calls are the sum over its rows, which include
// calls-only rows (Measured 0, Tokens 0: called, never measured in this
// part, such as deferred MCP tools). A group's start weight summed over its
// rows is a sum of per-row medians whose session sets may differ: an
// approximation.
type ContextSourceRow struct {
	Part      string `json:"part"`
	Group     string `json:"group"`
	GroupKind string `json:"group_kind"`
	Tokens    int    `json:"tokens"`
	Calls     int    `json:"calls"`
	Measured  int    `json:"measured_sessions"`
}

// sourcePart maps a source kind to the baseline part its bytes are in.
var sourcePart = map[string]string{"skill": "skills", "agent": "agents", "tool": "tools", "mcp_instructions": "mcp"}

// GroupOf is the group of one start-context source of kind (skill, agent,
// tool, mcp_instructions): a "<plugin>:<name>" skill or agent is the plugin's;
// an "mcp__<server>__<tool>" tool, or a server's instructions under its display
// name, is the server's (the claude.ai connectors share ConnectorsGroup); any
// other tool and a built-in agent type are GroupBuiltin; any other skill or
// agent is GroupUser (newGrouper tells GroupProject apart, it needs the folder).
func GroupOf(kind, name string) (group, groupKind string) {
	switch kind {
	case "tool":
		rest, ok := strings.CutPrefix(name, "mcp__")
		if !ok {
			return "", GroupBuiltin
		}
		// A server name holding "__" is cut at the first one; a user server
		// literally named claude_ai_* groups with the connectors. Edge cases.
		server, _, _ := strings.Cut(rest, "__")
		return serverGroup(server)
	case "mcp_instructions":
		return serverGroup(MCPServerID(name))
	case "skill", "agent":
		if plugin, _, ok := strings.Cut(name, ":"); ok && plugin != "" {
			return plugin, GroupPlugin
		}
		if kind == "agent" && builtinAgents[name] {
			return "", GroupBuiltin
		}
		return "", GroupUser
	}
	return "", GroupBuiltin
}

func serverGroup(server string) (string, string) {
	if strings.HasPrefix(server, claudeAIServerPrefix) {
		return ConnectorsGroup, GroupConnectors
	}
	return server, GroupMCPServer
}

// MCPServerID is a server name in its tool-id form: every character other
// than a letter, digit, '_' or '-' becomes '_' ("claude.ai Example" →
// "claude_ai_Example"), as Claude Code names the server's tools. A plugin's
// server is "plugin_" + MCPServerID(plugin) + "_" + its server's id.
func MCPServerID(display string) string {
	return strings.Map(func(r rune) rune {
		if r == '_' || r == '-' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			return r
		}
		return '_'
	}, display)
}

// grouper is GroupOf with one workbench folder: an unprefixed skill with a
// .claude/skills/<name> folder there, or agent with a .claude/agents/<name>.md,
// is GroupProject. Answers are cached.
type grouper struct {
	folder string
	cache  map[[2]string][2]string
}

func newGrouper(folder string) *grouper {
	return &grouper{folder: folder, cache: map[[2]string][2]string{}}
}

func (g *grouper) of(kind, name string) (string, string) {
	k := [2]string{kind, name}
	if v, ok := g.cache[k]; ok {
		return v[0], v[1]
	}
	group, gk := GroupOf(kind, name)
	if gk == GroupUser && g.folder != "" && g.inProject(kind, name) {
		gk = GroupProject
	}
	g.cache[k] = [2]string{group, gk}
	return group, gk
}

func (g *grouper) inProject(kind, name string) bool {
	if name == "" || strings.ContainsAny(name, `/\`) || name == "." || name == ".." {
		return false
	}
	var p string
	if kind == "skill" {
		p = filepath.Join(g.folder, ".claude", "skills", name)
	} else {
		p = filepath.Join(g.folder, ".claude", "agents", name+".md")
	}
	_, err := os.Stat(p)
	return err == nil
}

type sourceKey struct{ part, group, groupKind string }

type sourceAgg struct {
	tokens []int64 // one per measured session listing the group
	calls  int
}

// sourcesAcc sums the sources of one or more workbenches' periods.
type sourcesAcc struct {
	rows map[sourceKey]*sourceAgg
}

func newSourcesAcc() *sourcesAcc { return &sourcesAcc{rows: map[sourceKey]*sourceAgg{}} }

func (a *sourcesAcc) row(k sourceKey) *sourceAgg {
	r := a.rows[k]
	if r == nil {
		r = &sourceAgg{}
		a.rows[k] = r
	}
	return r
}

// add counts one workbench's sessions (folder = its folder, "" = none): the
// start weight of each source in the main lane of every session whose
// context was measured and that has source rows, at that lane's tokens per
// byte (as the baseline split does), and every session's calls.
func (a *sourcesAcc) add(sessions []agentlogdb.AgentReportSession, events map[string][]agentlogdb.AgentReportEvent,
	parts []agentlogdb.AgentContextPart, sources []agentlogdb.AgentContextSource, folder string) {
	g := newGrouper(folder)
	bySession := map[string][]agentlogdb.AgentContextSource{}
	skillNames := map[string]bool{}
	for _, c := range sources {
		if c.Kind == "skill" {
			skillNames[c.Name] = true
		}
		if c.AgentID == "" {
			bySession[c.SessionUUID] = append(bySession[c.SessionUUID], c)
		}
	}
	resolve := listedResolver(skillNames)
	partsFor := groupParts(parts)
	for _, s := range sessions {
		evs := events[s.SessionUUID]
		a.calls(g, resolve, evs)
		srcs := bySession[s.SessionUUID]
		if !contextMeasured(s) || len(srcs) == 0 {
			continue
		}
		perToken := tokensPerByte(partsFor[s.SessionUUID], "", firstMainCtx(evs))
		sum := map[sourceKey]int64{}
		for _, c := range srcs {
			part, ok := sourcePart[c.Kind]
			if !ok {
				continue
			}
			group, gk := g.of(c.Kind, c.Name)
			sum[sourceKey{part, group, gk}] += max(c.Bytes, 0)
		}
		for k, b := range sum {
			r := a.row(k)
			r.tokens = append(r.tokens, int64(math.Round(float64(b)*perToken)))
		}
	}
}

// calls counts one session's Skill, Agent and tool calls by their source.
func (a *sourcesAcc) calls(g *grouper, resolve func(string) string, evs []agentlogdb.AgentReportEvent) {
	for _, e := range evs {
		switch e.Kind {
		case "skill":
			if e.Name != "" {
				group, gk := g.of("skill", resolve(e.Name))
				a.row(sourceKey{"skills", group, gk}).calls++
			}
		case "tool":
			if e.Name == "" {
				continue
			}
			group, gk := g.of("tool", e.Name)
			a.row(sourceKey{"tools", group, gk}).calls++
			if isAgentTool(e.Name) && e.Target != "" {
				group, gk := g.of("agent", e.Target)
				a.row(sourceKey{"agents", group, gk}).calls++
			}
		}
	}
}

// result is the rows of every group with at least one measured row, largest
// first: a row of such a group with calls but no measured bytes stays as a
// calls-only row (tokens 0, measured_sessions 0), so the group's calls are
// whole — a deferred MCP tool (the claude.ai connectors' usual case) has no
// tool source, only its server's instructions do. A group only ever called,
// never measured, has no row.
func (a *sourcesAcc) result() []ContextSourceRow {
	measured := map[[2]string]bool{}
	for k, r := range a.rows {
		if len(r.tokens) > 0 {
			measured[[2]string{k.group, k.groupKind}] = true
		}
	}
	out := []ContextSourceRow{}
	for k, r := range a.rows {
		if !measured[[2]string{k.group, k.groupKind}] || len(r.tokens) == 0 && r.calls == 0 {
			continue
		}
		out = append(out, ContextSourceRow{Part: k.part, Group: k.group, GroupKind: k.groupKind,
			Tokens: int(median(r.tokens)), Calls: r.calls, Measured: len(r.tokens)})
	}
	slices.SortFunc(out, func(x, y ContextSourceRow) int {
		return cmp.Or(cmp.Compare(y.Tokens, x.Tokens), cmp.Compare(y.Calls, x.Calls), cmp.Compare(x.Part, y.Part),
			cmp.Compare(x.GroupKind, y.GroupKind), cmp.Compare(x.Group, y.Group))
	})
	return out
}

// firstMainCtx is the context of the main lane's first call, 0 for none.
func firstMainCtx(evs []agentlogdb.AgentReportEvent) int64 {
	for _, e := range evs {
		if e.Kind == "api_call" && e.AgentID == "" {
			return ctxTokens(e)
		}
	}
	return 0
}

// StartTokensMedian is the median main-lane baseline of the sessions whose
// context was measured, and n the lanes measured. parts must be ordered by
// session, then agent id (AgentReportContextParts' order, the groupParts
// contract); unordered input counts one session's main lane more than once.
// Tokens are the lane's bytes at defaultBytesPerToken (no events needed, so
// one ratio for every period it compares): not the same quantity as
// BaselineSplit.Tokens, which scales by the lane's first call context.
func StartTokensMedian(sessions []agentlogdb.AgentReportSession, parts []agentlogdb.AgentContextPart) (tokens int, n int) {
	measured := map[string]bool{}
	for _, s := range sessions {
		if contextMeasured(s) {
			measured[s.SessionUUID] = true
		}
	}
	var totals []int64
	for sid, lps := range groupParts(parts) {
		if !measured[sid] {
			continue
		}
		for _, lp := range lps {
			if lp.agent == "" && lp.bytes > 0 {
				totals = append(totals, int64(math.Round(float64(lp.bytes)/defaultBytesPerToken)))
			}
		}
	}
	return int(median(totals)), len(totals)
}

// StartTokens is StartTokensMedian over the sessions of agent (AgentAll or
// "" = every agent) of the workbenches ids in the period (as BuildOverview
// takes since and now), their lanes pooled into one median. al is only read.
func StartTokens(al *agentlogdb.DB, ids []int64, since, now time.Time, agent string) (tokens, n int, err error) {
	var sessions []agentlogdb.AgentReportSession
	for _, id := range ids {
		ss, err := periodSessions(al, id, since, now)
		if err != nil {
			return 0, 0, err
		}
		for _, s := range ss {
			if agent == "" || agent == AgentAll || s.Agent == agent {
				sessions = append(sessions, s)
			}
		}
	}
	facts := factsUUIDs(sessions)
	if len(facts) == 0 {
		return 0, 0, nil
	}
	parts, err := al.AgentReportContextParts(facts)
	if err != nil {
		return 0, 0, err
	}
	tokens, n = StartTokensMedian(sessions, parts)
	return tokens, n, nil
}

// GlobalSources is the Sources rows of every workbench with agent analytics
// on, over the sessions that started or ended at or after since (zero = all)
// and started up to now: tokens are the median over the measured sessions of
// all of them, calls the sum. A global change (a plugin, a server, the
// connectors) is decided on it, never on one workbench (D3). main and al are
// only read.
func GlobalSources(main *db.DB, al *agentlogdb.DB, since, now time.Time) ([]ContextSourceRow, error) {
	ids, err := main.AgentAnalyticsWorkbenchIDs()
	if err != nil {
		return nil, err
	}
	acc := newSourcesAcc()
	for _, id := range ids {
		wb, err := main.GetWorkbench(id)
		if err != nil {
			return nil, err
		}
		sessions, err := periodSessions(al, id, since, now)
		if err != nil {
			return nil, err
		}
		if len(sessions) == 0 {
			continue
		}
		evs, err := al.AgentReportEvents(uuidsOf(sessions))
		if err != nil {
			return nil, err
		}
		parts, sources, err := loadSources(al, sessions)
		if err != nil {
			return nil, err
		}
		acc.add(sessions, eventsByUUID(evs), parts, sources, wb.FolderPath)
	}
	return acc.result(), nil
}

// MeasuredSessions is the number of the workbench's sessions in the period
// (as BuildOverview takes since and now) whose start context was measured:
// its overview's Context.FactsSessions, without building the report. al is
// only read.
func MeasuredSessions(al *agentlogdb.DB, workbenchID int64, since, now time.Time) (int, error) {
	sessions, err := periodSessions(al, workbenchID, since, now)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, s := range sessions {
		if contextMeasured(s) {
			n++
		}
	}
	return n, nil
}

// loadSources reads the baseline parts and the per-source weights of the
// sessions with the v2 facts.
func loadSources(al *agentlogdb.DB, sessions []agentlogdb.AgentReportSession) ([]agentlogdb.AgentContextPart, []agentlogdb.AgentContextSource, error) {
	facts := factsUUIDs(sessions)
	if len(facts) == 0 {
		return nil, nil, nil
	}
	parts, err := al.AgentReportContextParts(facts)
	if err != nil {
		return nil, nil, err
	}
	sources, err := al.AgentReportContextSources(facts)
	if err != nil {
		return nil, nil, err
	}
	return parts, sources, nil
}

func factsUUIDs(sessions []agentlogdb.AgentReportSession) []string {
	var out []string
	for _, s := range sessions {
		if s.Facts {
			out = append(out, s.SessionUUID)
		}
	}
	return out
}
