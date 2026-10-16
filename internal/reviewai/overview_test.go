package reviewai

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewdiff"
)

func fileOf(path string, lines int) reviewdiff.File {
	ls := make([]string, lines)
	for i := range ls {
		ls[i] = "+line"
	}
	return reviewdiff.File{Path: path, Status: "modified", Additions: lines,
		Hunks: []reviewdiff.Hunk{{ID: "0123456789abcdef", Header: "@@ -1 +1 @@", Lines: ls}}}
}

func okInput() Input {
	return Input{
		Intent:  []IntentItem{{Text: "Add a greeting endpoint"}, {Text: "Document the endpoint"}},
		Diff:    reviewdiff.Diff{Files: []reviewdiff.File{fileOf("server/greet.go", 3), fileOf("server/greet_test.go", 2), fileOf("scripts/cleanup.sh", 1)}},
		LensIDs: []string{"correctness", "tests", "house_rules"},
	}
}

func TestParseOverview_ValidFixture(t *testing.T) {
	raw, err := os.ReadFile("testdata/overview_ok.json")
	require.NoError(t, err)
	o, err := ParseOverview(string(raw), okInput())
	require.NoError(t, err)
	assert.Contains(t, o.Summary, "greeting endpoint")
	require.Len(t, o.Coverage, 2)
	assert.Equal(t, Coverage{Item: "Add a greeting endpoint", Status: "done", Where: []string{"server/greet.go"}}, o.Coverage[0])
	assert.Equal(t, "not_found", o.Coverage[1].Status)
	assert.Equal(t, []string{"scripts/cleanup.sh"}, o.OutOfScope)
	require.Len(t, o.Risk, 3)
	assert.Equal(t, Risk{Path: "scripts/cleanup.sh", Level: "high", Why: "deletes files"}, o.Risk[2])
	require.Len(t, o.Chapters, 2)
	assert.Equal(t, Chapter{Title: "Greeting endpoint", Paths: []string{"server/greet.go", "server/greet_test.go"}, Core: true, Lenses: []string{"correctness", "tests"}}, o.Chapters[0])
	assert.Empty(t, o.Chapters[1].Lenses)
}

func TestParseOverview_DropsUnknownPathsLensesAndEnums(t *testing.T) {
	raw := "```json\n" + `{"summary":"s",
	 "coverage":[{"item":"a","status":"done","where":["server/greet.go","ghost.go"]},{"item":"b","status":"great","where":[]}],
	 "out_of_scope":["ghost.go","scripts/cleanup.sh"],
	 "risk":[{"path":"server/greet.go","level":"critical","why":"x"},{"path":"ghost.go","level":"low","why":"x"},{"path":"scripts/cleanup.sh","level":"low","why":"y"}],
	 "chapters":[{"title":"A","paths":["server/greet.go"],"core":true,"lenses":["perf","tests"]},{"title":"B","paths":["ghost.go"],"core":false,"lenses":[]}]}` + "\n```"
	o, err := ParseOverview(raw, okInput())
	require.NoError(t, err)
	require.Len(t, o.Coverage, 1)
	assert.Equal(t, []string{"server/greet.go"}, o.Coverage[0].Where)
	assert.Equal(t, []string{"scripts/cleanup.sh"}, o.OutOfScope)
	require.Len(t, o.Risk, 1)
	assert.Equal(t, "scripts/cleanup.sh", o.Risk[0].Path)
	require.Len(t, o.Chapters, 1)
	assert.Equal(t, []string{"tests"}, o.Chapters[0].Lenses)
}

func TestParseOverview_RejectsInvalid(t *testing.T) {
	for name, raw := range map[string]string{
		"not json":      "I could not do that",
		"array root":    `[{"summary":"s"}]`,
		"empty summary": `{"summary":"  ","coverage":[]}`,
	} {
		_, err := ParseOverview(raw, okInput())
		assert.Error(t, err, name)
	}
}

func TestBuildOverviewUser_CapsPerFileAndOverall(t *testing.T) {
	in := Input{Diff: reviewdiff.Diff{Files: []reviewdiff.File{fileOf("big.go", 1000)}}}
	out := BuildOverviewUser(in)
	assert.Contains(t, out, "big.go (+1000 −0) — not shown")

	in = Input{}
	for i := 0; i < 30; i++ {
		in.Diff.Files = append(in.Diff.Files, fileOf(fmt.Sprintf("f%02d.go", i), 300))
	}
	out = BuildOverviewUser(in)
	assert.Equal(t, MaxOverviewLines, strings.Count(out, "+line\n"))
	assert.Contains(t, out, "--- f19.go")
	assert.Contains(t, out, "f20.go (+300 −0) — not shown")
	assert.Contains(t, out, "f29.go (+300 −0) — not shown")

	in = Input{Diff: reviewdiff.Diff{Files: []reviewdiff.File{
		{Path: "package-lock.json", Additions: 9, CollapsedReason: "lockfile"},
		{Path: "img.png", Binary: true},
		fileOf("small.go", 2),
	}}}
	out = BuildOverviewUser(in)
	assert.Contains(t, out, "package-lock.json (+9 −0) — not shown")
	assert.Contains(t, out, "img.png (+0 −0) — not shown")
	assert.Contains(t, out, "--- small.go")
}

type recGen struct {
	system, user, source string
	out                  string
}

func (g *recGen) Generate(ctx context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	g.system, g.user = system, user
	g.source, _ = digest.SourceFromContext(ctx)
	return g.out, &digest.Usage{}, "", nil
}

func TestOverview_UsesPromptStoreAndSourceTag(t *testing.T) {
	g := &recGen{out: `{"summary":"fine"}`}
	p := New(g)
	_, err := p.Overview(context.Background(), okInput())
	require.NoError(t, err)
	assert.Equal(t, "workbench.review_overview", g.source)
	assert.Equal(t, prompts.Defaults[prompts.ReviewOverview], g.system)
	assert.Contains(t, g.user, "Add a greeting endpoint")

	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	store := prompts.New(database, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(prompts.ReviewOverview, "custom overview template", "test"))
	p.SetPromptStore(store)
	_, err = p.Overview(context.Background(), okInput())
	require.NoError(t, err)
	assert.Equal(t, "custom overview template", g.system)
}

func TestIntentHash_ChangesWithANote(t *testing.T) {
	items := []IntentItem{{Text: "a"}}
	base := IntentHash(items, nil)
	assert.Equal(t, base, IntentHash(items, nil))
	withNote := IntentHash(items, []db.ReviewNote{{Kind: "note", Path: "x.go", Text: "look"}})
	assert.NotEqual(t, base, withNote)
	assert.NotEqual(t, withNote, IntentHash(items, []db.ReviewNote{{Kind: "note", Path: "x.go", Text: "look again"}}))
	assert.Equal(t, withNote, IntentHash(items, []db.ReviewNote{{ID: 9, TreeSHA: "t", Kind: "note", Path: "x.go", Text: "look"}}))
}
