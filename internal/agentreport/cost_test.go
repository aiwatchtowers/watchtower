package agentreport

import (
	"testing"
	"watchtower/internal/agentlogdb"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func apiEv(agentID, model string, cost float64, in, read, w5, w1 int64) agentlogdb.AgentReportEvent {
	return agentlogdb.AgentReportEvent{Kind: "api_call", AgentID: agentID, Name: model, Model: model, CostUSD: cost,
		InputTokens: in, OutputTokens: 10, CacheReadTokens: read, CacheWrite5mTokens: w5, CacheWrite1hTokens: w1}
}

func TestModels_MainVsSub(t *testing.T) {
	evs := []agentlogdb.AgentReportEvent{
		apiEv("", "claude-opus-5-5", 2, 100, 600, 200, 100),
		apiEv("a1", "claude-opus-5-5", 1, 0, 0, 0, 0),
		apiEv("a1", "claude-haiku-4-5", 0.5, 50, 0, 0, 0),
		{Kind: "tool", Name: "Read", CostUSD: 9}, // not an api_call
	}
	rows := Models(evs)
	require.Len(t, rows, 2)
	assert.Equal(t, ModelRow{Model: "claude-opus-5-5", MainCostUSD: 2, SubCostUSD: 1, Tokens: 1000 + 20, CacheReadShare: 0.6}, rows[0])
	assert.Equal(t, "claude-haiku-4-5", rows[1].Model)
	assert.InDelta(t, 0.5, rows[1].SubCostUSD, 1e-9)
	assert.Zero(t, rows[1].MainCostUSD)
	assert.Zero(t, rows[1].CacheReadShare)
	assert.Empty(t, Models(nil))
	assert.NotNil(t, Models(nil))

	// no input at all: share 0, not NaN
	z := Models([]agentlogdb.AgentReportEvent{apiEv("", "m", 0, 0, 0, 0, 0)})
	assert.Zero(t, z[0].CacheReadShare)
}

func TestCommands_Aggregates(t *testing.T) {
	f := &fixture{}
	f.tool(0, "Bash", "go test", new(4*sec))
	e := f.tool(10*sec, "Bash", "go test", new(2*sec))
	e.Outcome = "error"
	f.tool(20*sec, "Bash", "go test", nil) // pending: a run with no time
	f.tool(30*sec, "Read", "/tmp/x/a.go", new(1*sec))
	f.api(40 * sec)
	rows := Commands(f.evs)
	require.Len(t, rows, 2)
	assert.Equal(t, CommandRow{Verb: "go test", Class: ClassBuildTest, Runs: 3, Errors: 1, TotalMS: 6000, AvgMS: 3000}, rows[0])
	assert.Equal(t, CommandRow{Verb: "Read", Class: ClassReadSearch, Runs: 1, TotalMS: 1000, AvgMS: 1000}, rows[1])
	assert.NotNil(t, Commands(nil))
}
