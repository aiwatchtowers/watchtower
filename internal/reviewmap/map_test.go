package reviewmap

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
)

type goldenChapter struct {
	Key          string   `json:"key"`
	Title        string   `json:"title"`
	Paths        []string `json:"paths"`
	ChangedLines int      `json:"changed_lines"`
	Core         bool     `json:"core"`
}

// TestChaptersGolden: the agent and "dir:" chapters equal, byte for byte,
// what the Desktop's ReviewChapters.resolve builds today (the same file is
// asserted by ReviewChaptersGoldenTests on the Swift side), so saved
// agent:/dir: keys keep matching after the Swift builder is removed.
func TestChaptersGolden(t *testing.T) {
	raw, err := os.ReadFile("testdata/chapters_golden.json")
	require.NoError(t, err)
	var golden struct {
		Cases []struct {
			Name  string `json:"name"`
			Files []struct {
				Path            string  `json:"path"`
				Additions       int     `json:"additions"`
				Deletions       int     `json:"deletions"`
				CollapsedReason *string `json:"collapsed_reason"`
			} `json:"files"`
			Agent []struct {
				Title string   `json:"title"`
				Paths []string `json:"paths"`
				Core  bool     `json:"core"`
			} `json:"agent"`
			Chapters []goldenChapter `json:"chapters"`
		} `json:"cases"`
	}
	require.NoError(t, json.Unmarshal(raw, &golden))
	require.GreaterOrEqual(t, len(golden.Cases), 5)
	for _, c := range golden.Cases {
		t.Run(c.Name, func(t *testing.T) {
			var in Input
			for _, f := range c.Files {
				df := reviewdiff.File{Path: f.Path, Status: "modified", Additions: f.Additions, Deletions: f.Deletions}
				// Swift zeroes a file's cost from collapsed_reason, Go from
				// IsNoise: a case is valid only where the two agree.
				require.Equal(t, f.CollapsedReason != nil, IsNoise(df, Patterns{}), "noise rule disagrees on %s", f.Path)
				in.Diff.Files = append(in.Diff.Files, df)
			}
			for _, a := range c.Agent {
				in.AgentChapters = append(in.AgentChapters, db.ReviewNote{Kind: "chapter", Text: a.Title, Paths: a.Paths, Core: a.Core})
			}
			var got []goldenChapter
			for _, ch := range buildChapters(in) {
				got = append(got, goldenChapter{
					Key: ch.Key, Title: ch.Title, Paths: ch.Paths, ChangedLines: ch.ChangedLines, Core: ch.Core,
				})
			}
			assert.Equal(t, c.Chapters, got)
			assertEveryFileOnce(t, in, Build(in))
		})
	}
}

// assertEveryFileOnce: every diff file is in exactly one chapter, and its
// FileInfo names that chapter.
func assertEveryFileOnce(t *testing.T, in Input, m Map) {
	t.Helper()
	owner := map[string]string{}
	for _, ch := range m.Chapters {
		for _, p := range ch.Paths {
			_, dup := owner[p]
			require.False(t, dup, "%s is in two chapters", p)
			owner[p] = ch.Key
		}
	}
	require.Len(t, owner, len(in.Diff.Files))
	for _, f := range m.Files {
		require.NotEmpty(t, f.Chapter, f.Path)
		require.Equal(t, owner[f.Path], f.Chapter, f.Path)
	}
}

func file(p string, lines int) reviewdiff.File {
	return reviewdiff.File{Path: p, Status: "modified", Additions: lines}
}

func keys(m Map) []string {
	out := make([]string, 0, len(m.Chapters))
	for _, c := range m.Chapters {
		out = append(out, c.Key)
	}
	return out
}

func chapter(t *testing.T, m Map, key string) Chapter {
	t.Helper()
	for _, c := range m.Chapters {
		if c.Key == key {
			return c
		}
	}
	t.Fatalf("no chapter %q in %v", key, keys(m))
	return Chapter{}
}

func TestBuild_AgentNumberingSkipsOtherKindsAndKeepsGaps(t *testing.T) {
	m := Build(Input{
		Diff: reviewdiff.Diff{Files: []reviewdiff.File{file("a/x.go", 10), file("b/y.go", 10)}},
		AgentChapters: []db.ReviewNote{
			{Kind: "chapter", Text: "Gone", Paths: []string{"nope.go"}},
			{Kind: "note", Text: "a note", Path: "a/x.go"},
			{Kind: "chapter", Text: "Y", Paths: []string{"b/y.go"}, Core: true},
		},
	})
	assert.Equal(t, []string{"agent:2", "dir:a"}, keys(m))
	assert.True(t, m.Chapters[0].Core)
	assert.Equal(t, "Y", m.Chapters[0].Title)
}

func TestBuild_NoiseIsCanSkipLast(t *testing.T) {
	m := Build(Input{Diff: reviewdiff.Diff{Files: []reviewdiff.File{
		file("go.sum", 500),
		file("internal/x/testdata/big.json", 900),
		file("internal/x/a.go", 5),
		{Path: "assets/logo.png", Status: "added", Binary: true},
		file("vendor/lib.go", 50),
	}}, Patterns: ParsePatterns("## Can skip\n- vendor/**\n")})
	assert.Equal(t, []string{"dir:internal/x", "collapsed"}, keys(m))
	skip := chapter(t, m, "collapsed")
	assert.Equal(t, "Can skip", skip.Title)
	assert.Equal(t, []string{"go.sum", "internal/x/testdata/big.json", "assets/logo.png", "vendor/lib.go"}, skip.Paths)
	assert.Equal(t, 1450, skip.ChangedLines)
	assert.False(t, skip.Core)
}

func TestBuild_NoiseNamedByTheAgentStaysInItsChapterAtNoCost(t *testing.T) {
	m := Build(Input{
		Diff:          reviewdiff.Diff{Files: []reviewdiff.File{file("go.sum", 500), file("a/x.go", 7)}},
		AgentChapters: []db.ReviewNote{{Kind: "chapter", Text: "Deps", Paths: []string{"a/x.go", "go.sum"}}},
	})
	assert.Equal(t, []string{"agent:1"}, keys(m))
	assert.Equal(t, 7, m.Chapters[0].ChangedLines)
}

func TestBuild_LaneChapters(t *testing.T) {
	var files []reviewdiff.File
	fileLane := map[string]string{}
	add := func(p string, lines int, lane string) {
		files = append(files, file(p, lines))
		if lane != "" {
			fileLane[p] = lane
		}
	}
	// A small lane: one chapter, tests beside their subject.
	add("internal/a/a.go", 40, "feat/small")
	add("internal/a/a_test.go", 30, "feat/small")
	add("cmd/a.go", 10, "feat/small")
	// A big lane: split by directory, a directory over 400 lines in parts,
	// the test with its subject.
	add("internal/big/p.go", 300, "feat/big")
	add("internal/big/p_test.go", 50, "feat/big")
	add("internal/big/q.go", 200, "feat/big")
	add("docs/big.md", 20, "feat/big")
	// No lane: package chapters.
	add("internal/rest/r.go", 15, "")
	m := Build(Input{
		Diff: reviewdiff.Diff{Files: files},
		Attribution: Attribution{
			FileLane: fileLane,
			Also:     map[string][]string{"cmd/a.go": {"feat/big"}},
			Lanes: map[string]Lane{
				"feat/small": {Name: "feat/small", Branch: "feat/small", Title: "Small thing", TargetID: 12},
				"feat/big":   {Name: "feat/big", Branch: "feat/big", Title: "Big thing", JiraKey: "ACME-7"},
			},
		},
	})
	assert.Equal(t, []string{
		"lane:feat/big/internal/big", "lane:feat/big/internal/big#2", "lane:feat/small",
		"lane:feat/big/docs", "dir:internal/rest",
	}, keys(m))

	small := chapter(t, m, "lane:feat/small")
	assert.Equal(t, "Small thing", small.Title)
	assert.Equal(t, []string{"cmd/a.go", "internal/a/a_test.go", "internal/a/a.go"}, small.Paths)
	assert.Equal(t, 80, small.ChangedLines)
	assert.Equal(t, "feat/small", small.Lane)
	assert.Equal(t, int64(12), small.TargetID)

	big := chapter(t, m, "lane:feat/big/internal/big")
	assert.Equal(t, "Big thing · internal/big", big.Title)
	assert.Equal(t, []string{"internal/big/p_test.go", "internal/big/p.go"}, big.Paths)
	assert.Equal(t, "ACME-7", big.JiraKey)
	assert.Equal(t, "Big thing · internal/big (2)", chapter(t, m, "lane:feat/big/internal/big#2").Title)
	assert.Equal(t, "Big thing · docs", chapter(t, m, "lane:feat/big/docs").Title)

	byPath := map[string]FileInfo{}
	for _, f := range m.Files {
		byPath[f.Path] = f
	}
	assert.Equal(t, "lane:feat/small", byPath["cmd/a.go"].Chapter)
	assert.Equal(t, "feat/small", byPath["cmd/a.go"].Lane)
	assert.Equal(t, []string{"feat/big"}, byPath["cmd/a.go"].Also)
	assert.Equal(t, "dir:internal/rest", byPath["internal/rest/r.go"].Chapter)
	assert.Empty(t, byPath["internal/rest/r.go"].Lane)
}

func TestBuild_ReadingOrder(t *testing.T) {
	m := Build(Input{
		Diff: reviewdiff.Diff{Files: []reviewdiff.File{
			file("small/a.go", 5),
			file("large/a.go", 300),
			file("agent/a.go", 2),
			file("go.mod", 1),                           // dependency: significant
			file("internal/db/migrations/00001.sql", 1), // migration edited: breaking
			file("package-lock.json", 999),              // noise
			file("mid/a.go", 50),
		}},
		AgentChapters: []db.ReviewNote{{Kind: "chapter", Text: "Agent", Paths: []string{"agent/a.go"}}},
	})
	assert.Equal(t, []string{
		"dir:internal/db/migrations", "dir:", "agent:1", "dir:large", "dir:mid", "dir:small", "collapsed",
	}, keys(m))
	assert.Equal(t, Breaking, m.Chapters[0].Level)
	assert.True(t, m.Chapters[0].Core, "a breaking chapter is core")
	assert.Equal(t, map[string]int{"migration_edited": 1}, m.Chapters[0].SignalsSummary)
	assert.Equal(t, Significant, m.Chapters[1].Level)
	assert.False(t, m.Chapters[1].Core)
	assert.False(t, m.Chapters[2].Core)
}

func TestBuild_Flags(t *testing.T) {
	p := ParsePatterns("stray line\n")
	require.NotEmpty(t, p.Notes)
	m := Build(Input{
		Diff:        reviewdiff.Diff{Files: []reviewdiff.File{file("a.go", 1)}, Truncated: true},
		Attribution: Attribution{Partial: true},
		Patterns:    p,
	})
	assert.True(t, m.DiffTruncated)
	assert.True(t, m.LanesPartial)
	assert.Equal(t, p.Notes, m.Notes)
}

func TestMap_JSONKeys(t *testing.T) {
	m := Build(Input{
		Diff: reviewdiff.Diff{Files: []reviewdiff.File{
			file("internal/auth/token.go", 3), file("b/plain.go", 1),
		}},
		Attribution: Attribution{
			FileLane: map[string]string{"internal/auth/token.go": "feat/x"},
			Also:     map[string][]string{"internal/auth/token.go": {"feat/y"}},
			Lanes:    map[string]Lane{"feat/x": {Name: "feat/x", Title: "X", TargetID: 4, JiraKey: "ACME-1"}},
		},
	})
	raw, err := json.Marshal(m)
	require.NoError(t, err)
	var got map[string]any
	require.NoError(t, json.Unmarshal(raw, &got))
	assert.ElementsMatch(t, []string{"chapters", "files", "lanes", "lanes_partial", "diff_truncated", "notes"}, mapKeys(got))
	assert.Equal(t, []any{}, got["notes"])
	lanes := got["lanes"].([]any)
	require.Len(t, lanes, 1)
	assert.ElementsMatch(t, []string{"name", "title", "target_id", "jira_key"}, mapKeys(lanes[0].(map[string]any)))

	chapters := got["chapters"].([]any)
	require.Len(t, chapters, 2)
	lane := chapters[0].(map[string]any)
	assert.ElementsMatch(t, []string{"key", "title", "level", "core", "paths", "changed_lines", "lane", "target_id",
		"jira_key", "signals_summary"}, mapKeys(lane))
	assert.Equal(t, "significant", lane["level"])
	assert.Equal(t, map[string]any{"security_path": float64(1)}, lane["signals_summary"])
	plain := chapters[1].(map[string]any)
	assert.ElementsMatch(t, []string{"key", "title", "level", "core", "paths", "changed_lines", "signals_summary"},
		mapKeys(plain), "lane, target_id and jira_key are left out when unset")
	assert.Equal(t, "normal", plain["level"])
	assert.Equal(t, map[string]any{}, plain["signals_summary"])

	files := got["files"].([]any)
	attributed := files[0].(map[string]any)
	assert.ElementsMatch(t, []string{"path", "chapter", "level", "signals", "lane", "also"}, mapKeys(attributed))
	unattributed := files[1].(map[string]any)
	assert.ElementsMatch(t, []string{"path", "chapter", "level", "signals"}, mapKeys(unattributed))
	assert.Equal(t, []any{}, unattributed["signals"])
}

func mapKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func TestBuild_CanSkipIsNormalWhateverItsFiles(t *testing.T) {
	m := Build(Input{Diff: reviewdiff.Diff{Files: []reviewdiff.File{
		{Path: "internal/x/testdata/old_test.go", Status: "deleted", Deletions: 30},
		file("internal/x/a.go", 5),
	}}})
	assert.Equal(t, []string{"dir:internal/x", "collapsed"}, keys(m))
	skip := chapter(t, m, "collapsed")
	assert.Equal(t, Normal, skip.Level)
	assert.False(t, skip.Core)
	assert.Equal(t, map[string]int{"test_deleted": 1}, skip.SignalsSummary)
	assert.Equal(t, "collapsed", m.Files[0].Chapter)
	assert.Equal(t, Breaking, m.Files[0].Level)
	assert.Equal(t, []string{"test_deleted"}, m.Files[0].Signals)
}

func ExampleBuild() {
	m := Build(Input{Diff: reviewdiff.Diff{Files: []reviewdiff.File{
		{Path: "internal/db/migrations/00001_init.sql", Status: "modified", Additions: 2},
		{Path: "README.md", Status: "modified", Additions: 40},
	}}})
	for _, c := range m.Chapters {
		fmt.Println(c.Key, c.Level, c.Core)
	}
	// Output:
	// dir:internal/db/migrations breaking true
	// dir: normal false
}

// Every lane the attribution found is in Lanes, by name, also one whose
// files all went to the agent's chapters (no lane chapter of its own); an
// empty attribution gives an empty list, never null.
func TestMap_LanesOutsideChapters(t *testing.T) {
	m := Build(Input{
		Diff: reviewdiff.Diff{Files: []reviewdiff.File{file("pay/pay.go", 3), file("login/auth.go", 2)}},
		AgentChapters: []db.ReviewNote{{Kind: "chapter", Text: "Payments", Paths: []string{"pay/pay.go"}}},
		Attribution: Attribution{
			FileLane: map[string]string{"pay/pay.go": "task-b", "login/auth.go": "ABC-1-login"},
			Lanes: map[string]Lane{
				"task-b":      {Name: "task-b", Title: "Payments lane", TargetID: 7},
				"ABC-1-login": {Name: "ABC-1-login", JiraKey: "ABC-1"},
			},
		},
	})
	for _, ch := range m.Chapters {
		assert.NotEqual(t, "task-b", ch.Lane, "task-b's only file went to the agent's chapter")
	}
	assert.Equal(t, []LaneInfo{
		{Name: "ABC-1-login", Title: "ABC-1-login", JiraKey: "ABC-1"},
		{Name: "task-b", Title: "Payments lane", TargetID: 7},
	}, m.Lanes)
	assert.Equal(t, []LaneInfo{}, Build(Input{}).Lanes)
}
