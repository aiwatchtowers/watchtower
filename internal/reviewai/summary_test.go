package reviewai

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/prompts"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/reviewmap"
)

// summaryInput: three chapters (server, scripts, docs) plus "collapsed";
// only server is described.
func summaryInput() SummaryInput {
	d := reviewdiff.Diff{Files: []reviewdiff.File{
		fileOf("server/greet.go", 3), fileOf("scripts/cleanup.sh", 1), fileOf("docs/api.md", 2),
		{Path: "go.sum", Additions: 4, CollapsedReason: "lockfile"},
	}}
	return SummaryInput{
		Intent: []IntentItem{{Text: "Greeting"}, {Text: "PROJ-7 docs", Source: SourceLane}},
		Map:    reviewmap.Build(reviewmap.Input{Diff: d}),
		Described: map[string]ChapterDesc{"dir:server": {Key: "dir:server", What: "The endpoint.",
			Risks: []Risk{{Path: "server/greet.go", Level: "medium", Why: "public"}}}},
	}
}

func TestBuildSummaryUser(t *testing.T) {
	out := BuildSummaryUser(summaryInput())
	assert.Contains(t, out, "1. Greeting\n")
	assert.Contains(t, out, "2. PROJ-7 docs\n   From: the ticket of a lane merged into the branch\n")
	assert.Contains(t, out, "key: dir:server\n")
	assert.Contains(t, out, "description: The endpoint.\nrisk: server/greet.go (medium): public\n")
	assert.Contains(t, out, "key: dir:scripts\ntitle: scripts\nlevel: normal\nfiles: scripts/cleanup.sh\ndescription: NOT DESCRIBED\n")
	assert.NotContains(t, out, "+line", "no diff")
	assert.Contains(t, out, "key: collapsed\n")
}

func TestParseSummary_ValidatesAgainstItsInput(t *testing.T) {
	raw := `{"summary":"Half seen.",
	 "coverage":[{"index":1,"item":"Greeting","status":"done","where":["server/greet.go","ghost.go"]},
	             {"index":2,"item":"Docs","status":"partial","where":["docs/api.md"]},
	             {"index":3,"item":"ghost","status":"done","where":[]}],
	 "out_of_scope":["scripts/cleanup.sh","ghost.sh"],
	 "not_covered":["dir:scripts","dir:server","collapsed","dir:ghost","dir:docs","dir:scripts"]}`
	sum, err := ParseSummary(raw, summaryInput())
	require.NoError(t, err)
	assert.Equal(t, "Half seen.", sum.Summary)
	assert.Equal(t, []Coverage{
		{Index: 1, Item: "Greeting", Status: "done", Where: []string{"server/greet.go"}, Source: SourceSession},
		{Index: 2, Item: "Docs", Status: "partial", Where: []string{"docs/api.md"}, Source: SourceLane},
	}, sum.Coverage)
	assert.Equal(t, []string{"scripts/cleanup.sh"}, sum.OutOfScope)
	assert.Equal(t, []string{"dir:scripts", "dir:docs"}, sum.NotCovered, "only not-described chapters of the input, once each")
}

func TestParseSummary_RejectsInvalid(t *testing.T) {
	for name, raw := range map[string]string{
		"not json":      "sorry",
		"array root":    `[{"summary":"s"}]`,
		"empty summary": `{"summary":""}`,
	} {
		_, err := ParseSummary(raw, summaryInput())
		assert.ErrorIs(t, err, ErrParse, name)
	}
	sum, err := ParseSummary(`{"summary":"s"}`, summaryInput())
	require.NoError(t, err)
	assert.Equal(t, []string{}, sum.NotCovered)
	assert.Equal(t, []Coverage{}, sum.Coverage)
}

func TestSummarize_OneCallTaggedAndTemplated(t *testing.T) {
	g := &countGen{out: map[string]string{prompts.ReviewSummary: `{"summary":"s","not_covered":["dir:docs"]}`}}
	sum, err := New(g).Summarize(context.Background(), summaryInput())
	require.NoError(t, err)
	assert.Equal(t, 1, g.calls)
	assert.Equal(t, prompts.ReviewSummary, g.sources[0])
	assert.Equal(t, prompts.Defaults[prompts.ReviewSummary], g.systems[0])
	assert.Equal(t, []string{"dir:docs"}, sum.NotCovered)
}
