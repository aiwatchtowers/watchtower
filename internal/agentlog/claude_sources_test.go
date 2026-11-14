package agentlog

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// sourcesOf maps "<session>/<agent>/<kind>/<name>" to the stored bytes.
func sourcesOf(r *ParseResult) map[string]int64 {
	got := map[string]int64{}
	for _, s := range r.ContextSources {
		got[s.SessionUUID+"/"+s.AgentID+"/"+s.Kind+"/"+s.Name] = s.Bytes
	}
	return got
}

func TestParse_SkillBytesPerLine(t *testing.T) {
	content := "The following skills are available:\n\n- a: x\n- bb: yyyy\n- pk:brain: zz\n- pk: q\n"
	names := []string{"a", "bb", "pk", "pk:brain", "nolines"}
	s := attachLine(t, "s1", "skill_listing", map[string]any{"names": names, "content": content}, "0123456789") +
		line(t, assistant("s1", "u1", "m1", "r1", 5))
	r := parse(t, s, ParseOptions{})

	want := map[string]int64{"a": int64(len("- a: x")), "bb": int64(len("- bb: yyyy")),
		"pk": int64(len("- pk: q")), "pk:brain": int64(len("- pk:brain: zz")),
		"nolines": 10 / 5} // no line of its own: the old even split, for that name only
	listed := map[string]int64{}
	for _, k := range r.SkillListing {
		listed[k.Skill] = k.Bytes
	}
	assert.Equal(t, want, listed)
	src := map[string]int64{}
	for name, b := range want {
		src["s1//skill/"+name] = b
	}
	assert.Equal(t, src, sourcesOf(r))
}

func TestParse_AgentListingSources(t *testing.T) {
	s := attachLine(t, "s1", "agent_listing_delta", map[string]any{
		"addedTypes": []string{"t1", "plug:t2", "unpaired"},
		"addedLines": []string{"- t1: does one thing", "- plug:t2: another"}}, "rendered") +
		line(t, assistant("s1", "u1", "m1", "r1", 5))
	r := parse(t, s, ParseOptions{})
	assert.Equal(t, map[string]int64{
		"s1//agent/t1":      int64(len("- t1: does one thing")),
		"s1//agent/plug:t2": int64(len("- plug:t2: another")),
	}, sourcesOf(r), "a type without its line is not measured")
}

func TestParse_ToolBytesFromShape(t *testing.T) {
	bash := map[string]any{"name": "Bash", "description": "run", "input_schema": map[string]any{"type": "object"}}
	mcp := map[string]any{"name": "mcp__srv__x", "description": "an mcp tool"}
	s := shapeLine(t, "s1", []map[string]any{{"type": "text", "text": "sys"}}, []any{bash, mcp, map[string]any{"description": "nameless"}}) +
		line(t, assistant("s1", "u1", "m1", "r1", 5))
	r := parse(t, s, ParseOptions{})
	assert.Equal(t, map[string]int64{"s1//tool/Bash": jsonLen(t, bash), "s1//tool/mcp__srv__x": jsonLen(t, mcp)}, sourcesOf(r))

	// A shape whose tools are not a list measures no tool.
	r = parse(t, shapeLine(t, "s1", nil, map[string]any{"name": "odd"}), ParseOptions{})
	assert.Empty(t, r.ContextSources)
}

func TestParse_SurfacedDeferredTool(t *testing.T) {
	def := map[string]any{"name": "mcp__srv__late", "description": "loaded on demand", "input_schema": map[string]any{"type": "object"}}
	s := attachLine(t, "s1", "deferred_tools_delta", map[string]any{
		"addedNames": []string{"mcp__srv__late", "mcp__srv__other"}, "addedLines": []string{"mcp__srv__late", "mcp__srv__other"},
		"surfacedDefinitions": []map[string]any{{"name": "mcp__srv__late", "listing": "mcp__srv__late", "definition": def}}}, "d") +
		line(t, assistant("s1", "u1", "m1", "r1", 5))
	r := parse(t, s, ParseOptions{})
	assert.Equal(t, map[string]int64{"s1//tool/mcp__srv__late": jsonLen(t, def)}, sourcesOf(r),
		"only a surfaced definition is a tool row; listed deferred names weigh nothing yet")
}

func TestParse_MCPInstructionBlocks(t *testing.T) {
	s := attachLine(t, "s1", "mcp_instructions_delta", map[string]any{
		"addedNames":  []string{"claude.ai Docs", "watchtower-workbench"},
		"addedBlocks": []string{"## claude.ai Docs\nuse it", "## watchtower-workbench\nboard"}}, "mm") +
		line(t, assistant("s1", "u1", "m1", "r1", 5))
	r := parse(t, s, ParseOptions{})
	assert.Equal(t, map[string]int64{
		"s1//mcp_instructions/claude.ai Docs":       int64(len("## claude.ai Docs\nuse it")),
		"s1//mcp_instructions/watchtower-workbench": int64(len("## watchtower-workbench\nboard")),
	}, sourcesOf(r))
}

func TestParse_SourcesOnlyBeforeFirstCall(t *testing.T) {
	tool := map[string]any{"name": "Bash"}
	before := shapeLine(t, "s1", nil, []any{tool}) +
		attachLine(t, "s1", "mcp_instructions_delta", map[string]any{"addedNames": []string{"srv"}, "addedBlocks": []string{"abc"}}, "abc")
	after := shapeLine(t, "s1", nil, []any{tool, map[string]any{"name": "Later", "description": "after the first call"}}) +
		attachLine(t, "s1", "mcp_instructions_delta", map[string]any{"addedNames": []string{"srv", "late"}, "addedBlocks": []string{"abcdefgh", "x"}}, "x") +
		attachLine(t, "s1", "skill_listing", map[string]any{"names": []string{"k"}, "content": "- k: v"}, "- k: v")
	want := map[string]int64{"s1//tool/Bash": jsonLen(t, tool), "s1//mcp_instructions/srv": 3}
	r := parse(t, before+line(t, assistant("s1", "u1", "m1", "r1", 5))+after+line(t, assistant("s1", "u2", "m2", "r2", 5)), ParseOptions{})
	assert.Equal(t, want, sourcesOf(r))

	// A sub-agent lane is its own lane, under its agent id.
	sub := parse(t, before+line(t, assistant("s1", "u1", "m9", "r9", 5)),
		ParseOptions{Path: "/h/.claude/projects/-w/s1/subagents/agent-a1.jsonl", Subagent: true, AgentID: "a1"})
	assert.Equal(t, map[string]int64{"s1/a1/tool/Bash": jsonLen(t, tool), "s1/a1/mcp_instructions/srv": 3}, sourcesOf(sub))

	// An incremental read of a lane whose first call is stored adds nothing.
	o := ParseOptions{Path: "/h/.claude/projects/-w/s1.jsonl", Folder: "/w",
		LaneBaseline: func(string) (bool, map[string]int64, error) { return true, nil, nil }}
	inc, err := ParseClaude(strings.NewReader(before), 500, o)
	require.NoError(t, err)
	assert.Empty(t, inc.ContextSources)
}

// A transcript stored at parser v4 has no per-source rows ("not measured",
// never 0) until the bump rereads it from offset 0.
func TestParse_ParserV4RowsStayUnmeasured(t *testing.T) {
	f := newFixture(t)
	shape := line(t, map[string]any{"type": "api-request-shape", "sessionId": "s1", "cwd": f.folder,
		"shape": map[string]any{"system": []any{}, "tools": []any{map[string]any{"name": "Bash"}}}})
	path := f.write(f.folder, "s1.jsonl", shape+call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	require.Equal(t, 1, f.scan().FilesScanned)
	count := func() (n int) {
		require.NoError(t, f.al.QueryRow(`SELECT COUNT(*) FROM agent_log_context_sources WHERE session_uuid = 's1'`).Scan(&n))
		return n
	}
	require.Equal(t, 1, count())

	// Simulate a file parsed by v4: no source rows, version 4.
	_, err := f.al.Exec(`DELETE FROM agent_log_context_sources`)
	require.NoError(t, err)
	_, err = f.al.Exec(`UPDATE agent_log_files SET parser_version = 4`)
	require.NoError(t, err)
	got, err := f.al.AgentReportContextSources([]string{"s1"})
	require.NoError(t, err)
	assert.Empty(t, got, "a v4 session reports no source, not a zero-byte one")

	require.Equal(t, 1, f.scan().FilesScanned, "the unchanged v4 file is reread")
	assert.Equal(t, 1, count())
	fr, err := f.al.GetAgentLogFile(path)
	require.NoError(t, err)
	require.NotNil(t, fr)
	assert.Equal(t, parserVersionFor(AgentClaude), fr.ParserVersion)
	assert.Equal(t, 5, fr.ParserVersion)
}
