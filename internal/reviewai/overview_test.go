package reviewai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/reviewmap"
)

func fileOf(path string, lines int) reviewdiff.File {
	ls := make([]string, lines)
	for i := range ls {
		ls[i] = "+line"
	}
	return reviewdiff.File{Path: path, Status: "modified", Additions: lines,
		Hunks: []reviewdiff.Hunk{{ID: "0123456789abcdef", Header: "@@ -1 +1 @@", Lines: ls}}}
}

func okIntent() []IntentItem {
	return []IntentItem{{Text: "Add a greeting endpoint"}, {Text: "Document the endpoint"}}
}

func okDiff() reviewdiff.Diff {
	return reviewdiff.Diff{Files: []reviewdiff.File{fileOf("server/greet.go", 3), fileOf("server/greet_test.go", 2), fileOf("scripts/cleanup.sh", 1)}}
}

// okBatch is the 3-file diff's map packed: one batch.
func okBatch(t *testing.T) Batch {
	t.Helper()
	d := okDiff()
	bs := Pack(reviewmap.Build(reviewmap.Input{Diff: d}), d, nil)
	require.Len(t, bs, 1)
	return bs[0]
}

// countGen answers every call with out (or a reply picked by system
// prompt) and records the calls.
type countGen struct {
	mu      sync.Mutex
	calls   int
	sources []string
	users   []string
	systems []string
	out     map[string]string // source → reply
}

func (g *countGen) Generate(ctx context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	src, _ := digest.SourceFromContext(ctx)
	g.calls++
	g.sources = append(g.sources, src)
	g.users = append(g.users, user)
	g.systems = append(g.systems, system)
	return g.out[src], &digest.Usage{}, "", nil
}

func TestParseOverview_ValidFixture(t *testing.T) {
	raw, err := os.ReadFile("testdata/overview_ok.json")
	require.NoError(t, err)
	descs, sum, err := ParseOverview(string(raw), okBatch(t), okIntent())
	require.NoError(t, err)
	assert.Contains(t, sum.Summary, "greeting endpoint")
	require.Len(t, sum.Coverage, 2)
	assert.Equal(t, Coverage{Index: 1, Item: "Add a greeting endpoint", Status: "done", Where: []string{"server/greet.go"}, Source: SourceSession}, sum.Coverage[0])
	assert.Equal(t, "not_found", sum.Coverage[1].Status)
	assert.Equal(t, []string{"scripts/cleanup.sh"}, sum.OutOfScope)
	assert.Equal(t, []string{}, sum.NotCovered)
	require.Len(t, descs, 2)
	assert.Equal(t, ChapterDesc{Key: "dir:server", What: "The greeting endpoint and its test.",
		Risks: []Risk{{Path: "server/greet.go", Level: "medium", Why: "new public handler"}}}, descs["dir:server"])
	assert.Equal(t, "high", descs["dir:scripts"].Risks[0].Level)
}

func TestParseOverview_DropsUnknownKeysPathsAndEnums(t *testing.T) {
	raw := "```json\n" + `{"summary":"s",
	 "coverage":[{"index":1,"item":"a","status":"done","where":["server/greet.go","ghost.go"]},{"index":2,"item":"b","status":"great","where":[]}],
	 "out_of_scope":["ghost.go","scripts/cleanup.sh"],
	 "chapters":[
	  {"key":"dir:server","what":"w","risks":[{"path":"server/greet.go","level":"critical","why":"x"},{"path":"scripts/cleanup.sh","level":"low","why":"other chapter"},{"path":"server/greet_test.go","level":"low","why":"y"}]},
	  {"key":"ai:1","what":"invented","risks":[]},
	  {"key":"dir:server","what":"again","risks":[]},
	  {"key":"dir:scripts","what":"  ","risks":[]}]}` + "\n```"
	descs, sum, err := ParseOverview(raw, okBatch(t), okIntent())
	require.NoError(t, err)
	require.Len(t, sum.Coverage, 1)
	assert.Equal(t, []string{"server/greet.go"}, sum.Coverage[0].Where)
	assert.Equal(t, []string{"scripts/cleanup.sh"}, sum.OutOfScope)
	require.Len(t, descs, 1)
	assert.Equal(t, "w", descs["dir:server"].What)
	assert.Equal(t, []Risk{{Path: "server/greet_test.go", Level: "low", Why: "y"}}, descs["dir:server"].Risks)
}

func TestParseOverview_DropsBadCoverageIndex(t *testing.T) {
	raw := `{"summary":"s","chapters":[{"key":"dir:server","what":"w"}],"coverage":[
	 {"index":2,"item":"Docs, reworded","status":"not_found","where":[]},
	 {"index":0,"item":"zero","status":"done","where":[]},
	 {"index":3,"item":"past the end","status":"done","where":[]},
	 {"item":"no index","status":"done","where":[]},
	 {"index":2,"item":"again","status":"done","where":[]},
	 {"index":1,"item":"Greeting","status":"done","where":["server/greet.go"]}]}`
	intent := okIntent()
	intent[1].Source = SourceLane
	_, sum, err := ParseOverview(raw, okBatch(t), intent)
	require.NoError(t, err)
	assert.Equal(t, []Coverage{
		{Index: 2, Item: "Docs, reworded", Status: "not_found", Where: []string{}, Source: SourceLane},
		{Index: 1, Item: "Greeting", Status: "done", Where: []string{"server/greet.go"}, Source: SourceSession},
	}, sum.Coverage)
}

func TestParseOverview_RejectsInvalid(t *testing.T) {
	for name, raw := range map[string]string{
		"not json":           "I could not do that",
		"array root":         `[{"summary":"s"}]`,
		"empty summary":      `{"summary":"  ","coverage":[],"chapters":[{"key":"dir:server","what":"w"}]}`,
		"no own chapter":     `{"summary":"s","chapters":[{"key":"dir:elsewhere","what":"w"}]}`,
		"no chapters at all": `{"summary":"s"}`,
	} {
		_, _, err := ParseOverview(raw, okBatch(t), okIntent())
		assert.ErrorIs(t, err, ErrParse, name)
	}
}

func TestParseOverview_ProseBracketsAreFine(t *testing.T) {
	_, sum, err := ParseOverview(`Here [1] is the result: {"summary":"ok","chapters":[{"key":"dir:server","what":"w"}]}`, okBatch(t), okIntent())
	require.NoError(t, err)
	assert.Equal(t, "ok", sum.Summary)
}

func TestOverview_SmallDiffIsOneCallWithSummary(t *testing.T) {
	raw, err := os.ReadFile("testdata/overview_ok.json")
	require.NoError(t, err)
	g := &countGen{out: map[string]string{prompts.ReviewOverview: string(raw)}}
	d := okDiff()
	o, err := New(g).Run(context.Background(), newMemStore(), reviewmap.Build(reviewmap.Input{Diff: d}), d, okIntent(), nil, RunOptions{})
	require.NoError(t, err)
	assert.Equal(t, 1, g.calls)
	assert.Equal(t, []string{prompts.ReviewOverview}, g.sources)
	assert.Equal(t, prompts.Defaults[prompts.ReviewOverview], g.systems[0])
	assert.Contains(t, g.users[0], "1. Add a greeting endpoint")
	assert.Contains(t, g.users[0], "key: dir:server")
	assert.Contains(t, o.Summary, "greeting endpoint")
	require.Len(t, o.Chapters, 2)
	assert.Equal(t, []string{"server/greet_test.go", "server/greet.go"}, o.Chapters[0].Paths)
	assert.Len(t, o.Risk, 2)
}

func TestDescribeBatch_UsesPromptStore(t *testing.T) {
	g := &countGen{out: map[string]string{prompts.ReviewChapters: `{"chapters":[{"key":"dir:server","what":"w"}]}`}}
	p := New(g)
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	store := prompts.New(database, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(prompts.ReviewChapters, "custom chapters template", "test"))
	p.SetPromptStore(store)
	descs, sum, err := p.DescribeBatch(context.Background(), okBatch(t), false, []IntentItem{{Text: "ignored"}}, nil)
	require.NoError(t, err)
	assert.Nil(t, sum)
	assert.Len(t, descs, 1)
	assert.Equal(t, "custom chapters template", g.systems[0])
	assert.Equal(t, prompts.ReviewChapters, g.sources[0])
	assert.NotContains(t, g.users[0], "=== INTENT ===")
	assert.NotContains(t, g.users[0], "ignored")
}

// The mode is the explicit flag: a full call with no intent at all is
// still the one full call and returns a summary.
func TestDescribeBatch_FullWithNilIntent(t *testing.T) {
	raw, err := os.ReadFile("testdata/overview_ok.json")
	require.NoError(t, err)
	g := &countGen{out: map[string]string{prompts.ReviewOverview: string(raw)}}
	descs, sum, err := New(g).DescribeBatch(context.Background(), okBatch(t), true, nil, nil)
	require.NoError(t, err)
	require.NotNil(t, sum)
	assert.Empty(t, sum.Coverage)
	assert.NotEmpty(t, descs)
	assert.Equal(t, prompts.ReviewOverview, g.sources[0])
	assert.Contains(t, g.users[0], "(none given)")
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

// Session-only intent hashes the bytes it hashed before lane items existed,
// so overviews cached today stay valid.
func TestIntentHash_SessionOnlyUnchanged(t *testing.T) {
	sha := func(s string) string { sum := sha256.Sum256([]byte(s)); return hex.EncodeToString(sum[:]) }
	assert.Equal(t, sha(`{"Items":[{"Text":"a","Intent":"i","Task":"t"}],"Notes":[]}`),
		IntentHash([]IntentItem{{Text: "a", Intent: "i", Task: "t"}}, nil))
	assert.Equal(t, sha(`{"Items":[{"Text":"a","Intent":"","Task":""}],"Notes":[]}`),
		IntentHash([]IntentItem{{Text: "a", Source: SourceSession}}, nil))
	assert.Equal(t, sha(`{"Items":null,"Notes":[]}`), IntentHash(nil, nil))
}

func TestIntentHash_CoversLaneItems(t *testing.T) {
	session := []IntentItem{{Text: "a"}}
	withLane := append(session[:1:1], IntentItem{Text: "PROJ-1 ticket", Source: SourceLane})
	assert.NotEqual(t, IntentHash(session, nil), IntentHash(withLane, nil))
	other := append(session[:1:1], IntentItem{Text: "PROJ-2 ticket", Source: SourceLane})
	assert.NotEqual(t, IntentHash(withLane, nil), IntentHash(other, nil))
	// A lane item is not a session item with the same text.
	assert.NotEqual(t, IntentHash([]IntentItem{{Text: "x"}}, nil), IntentHash([]IntentItem{{Text: "x", Source: SourceLane}}, nil))
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

func TestParseOverview_EmptySummaryNamesTheOverviewReply(t *testing.T) {
	_, _, err := ParseOverview(`{"summary":" ","chapters":[{"key":"dir:server","what":"w"}]}`, okBatch(t), okIntent())
	require.ErrorIs(t, err, ErrParse)
	assert.Contains(t, err.Error(), "overview reply")
	assert.NotContains(t, err.Error(), "summary reply")
}
