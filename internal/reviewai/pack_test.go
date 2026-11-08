package reviewai

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/reviewmap"
)

func TestPack_SmallDiffIsOneBatch(t *testing.T) {
	b := okBatch(t)
	assert.Equal(t, 6, b.Lines)
	assert.Len(t, b.Files, 3)
	var keys []string
	for _, ch := range b.Chapters {
		keys = append(keys, ch.Key)
	}
	assert.ElementsMatch(t, []string{"dir:server", "dir:scripts"}, keys)
}

// bigBranch is a synthetic 700-file branch: 61 directories of 10 files of
// 40 lines, 80 noise files, an agent chapter over the batch budget with a
// dangerous migration and files over the per-file cap, and a directory of
// files past the diff's size cap.
func bigBranch() reviewdiff.Diff {
	var d reviewdiff.Diff
	for i := range 61 {
		for j := range 10 {
			d.Files = append(d.Files, fileOf(fmt.Sprintf("pkg%02d/f%d.go", i, j), 40))
		}
	}
	for i := range 80 {
		d.Files = append(d.Files, fileOf(fmt.Sprintf("pkg%02d/testdata/fixture%d.json", i%60, i), 30))
	}
	for j := range 9 {
		d.Files = append(d.Files, fileOf(fmt.Sprintf("huge/h%d.go", j), 350))
	}
	mig := fileOf("huge/migrations/0001_init.sql", 120)
	d.Files = append(d.Files, mig)
	for j := range 2 {
		d.Files = append(d.Files, reviewdiff.File{Path: fmt.Sprintf("assets/big%d.go", j), Status: "modified", Additions: 90000, CollapsedReason: "too_large"})
	}
	return d
}

// bigNotes: the agent made the huge/ files one chapter.
func bigNotes(d reviewdiff.Diff) []db.ReviewNote {
	var huge []string
	for _, f := range d.Files {
		if strings.HasPrefix(f.Path, "huge/") {
			huge = append(huge, f.Path)
		}
	}
	return []db.ReviewNote{{Kind: "chapter", Text: "Huge", Paths: huge}}
}

func bigMap(d reviewdiff.Diff) reviewmap.Map {
	return reviewmap.Build(reviewmap.Input{Diff: d, AgentChapters: bigNotes(d)})
}

func TestPack_BigBranch(t *testing.T) {
	d := bigBranch()
	require.GreaterOrEqual(t, len(d.Files), 700)
	m := bigMap(d)
	bs := Pack(m, d, nil)
	require.Greater(t, len(bs), 1)

	seen := map[string]int{}
	for _, b := range bs {
		assert.LessOrEqual(t, b.Lines, MaxBatchLines)
		assert.NotEmpty(t, b.Chapters)
		for _, ch := range b.Chapters {
			seen[ch.Key]++
		}
		for _, f := range b.Files {
			assert.NotContains(t, f.Path, "/testdata/", "noise sent to the model")
			assert.LessOrEqual(t, fileLines(f), MaxOverviewFileLines)
		}
	}
	notShown := NotShown(m, d)
	for _, ch := range m.Chapters {
		switch {
		case ch.Key == collapsedKey:
			assert.Zero(t, seen[ch.Key])
		case notShown[ch.Key].Key != "":
			assert.Zero(t, seen[ch.Key], ch.Key)
		default:
			assert.Equal(t, 1, seen[ch.Key], "chapter %s packed once", ch.Key)
		}
	}
}

func TestPack_OversizedChapterIsCutDangerFirst(t *testing.T) {
	d := bigBranch()
	m := bigMap(d)
	var huge *Batch
	bs := Pack(m, d, nil)
	for i, b := range bs {
		for _, f := range b.Files {
			if strings.HasPrefix(f.Path, "huge/") {
				huge = &bs[i]
			}
		}
	}
	require.NotNil(t, huge)
	require.Len(t, huge.Chapters, 1, "an oversized chapter has its batch alone")
	assert.Equal(t, MaxBatchLines, huge.Lines)
	assert.Equal(t, "huge/migrations/0001_init.sql", huge.Files[0].Path, "the dangerous file comes first")
	assert.Equal(t, "huge/h0.go", huge.Files[1].Path)

	out := BuildChaptersUser(*huge, nil)
	assert.Contains(t, out, "(+50 lines not shown)", "a 350-line file shows 300")
	// 120 + 7×300 = 2220 lines; h7 shows 280, h8 nothing.
	assert.Contains(t, out, "--- huge/h7.go")
	assert.Contains(t, out, "(+70 lines not shown)")
	assert.Contains(t, out, "huge/h8.go (+350 −0) — not shown [chapter ")
	assert.Contains(t, out, "— not shown [chapter "+huge.Chapters[0].Key+"]\n(+350 lines not shown)",
		"a file the budget cut to nothing says so, unlike a binary one")
}

func TestPack_UnshownChapterIsNotPackedButDescribed(t *testing.T) {
	d := bigBranch()
	m := bigMap(d)
	for _, b := range Pack(m, d, nil) {
		for _, f := range b.Files {
			assert.NotContains(t, f.Path, "assets/")
		}
	}
	ns := NotShown(m, d)
	require.NotEmpty(t, ns)
	for key, desc := range ns {
		assert.True(t, strings.HasPrefix(key, "dir:assets"), key)
		assert.Equal(t, notShownWhat, desc.What)
	}
}

func TestPack_HaveSkipsDescribedChaptersOnlyWhenMultiBatch(t *testing.T) {
	d := okDiff()
	m := bigMap(d)
	bs := Pack(m, d, map[string]bool{"dir:server": true})
	require.Len(t, bs, 1)
	assert.Len(t, bs[0].Chapters, 2, "a small change is always the one full call")

	d = bigBranch()
	m = bigMap(d)
	have := map[string]bool{}
	all := 0
	for _, b := range Pack(m, d, nil) {
		all += len(b.Chapters)
		for _, ch := range b.Chapters[1:] {
			have[ch.Key] = true
		}
	}
	left := 0
	for _, b := range Pack(m, d, have) {
		for _, ch := range b.Chapters {
			assert.False(t, have[ch.Key])
			left++
		}
	}
	assert.Equal(t, all-len(have), left)
}

func TestPack_NothingToShow(t *testing.T) {
	d := reviewdiff.Diff{Files: []reviewdiff.File{{Path: "package-lock.json", Additions: 9, CollapsedReason: "lockfile"}}}
	assert.Empty(t, Pack(reviewmap.Build(reviewmap.Input{Diff: d}), d, nil))
	_, err := New(&countGen{}).Overview(context.Background(), Input{Diff: d})
	assert.Error(t, err)
}

func TestOverview_BigBranchCallsPerBatchThenSummary(t *testing.T) {
	d := bigBranch()
	m := bigMap(d)
	bs := Pack(m, d, nil)
	// Every batch reply describes the first chapter of every batch; the
	// parser keeps only the batch's own.
	var parts []string
	for _, b := range bs {
		parts = append(parts, fmt.Sprintf(`{"key":%q,"what":"w"}`, b.Chapters[0].Key))
	}
	g := &countGen{out: map[string]string{
		"review.chapters": `{"chapters":[` + strings.Join(parts, ",") + `]}`,
		"review.summary":  `{"summary":"big","coverage":[],"out_of_scope":[],"not_covered":[]}`,
	}}
	o, err := New(g).Overview(context.Background(), Input{Diff: d, Notes: bigNotes(d)})
	require.NoError(t, err)
	assert.Equal(t, len(bs)+1, g.calls)
	assert.Equal(t, "review.summary", g.sources[len(g.sources)-1])
	assert.NotContains(t, g.users[len(g.users)-1], "+line", "the summary sees no diff")
	assert.Equal(t, "big", o.Summary)
}

// The one full call still names the files of the chapters Pack leaves out
// (a binary-only chapter, the diff's size cap), and its summary may cite
// them.
func TestPack_OneBatchListsLeftOutFiles(t *testing.T) {
	d := okDiff()
	d.Files = append(d.Files, reviewdiff.File{Path: "assets/logo.png", Status: "modified", Binary: true})
	d.Truncated = true
	m := reviewmap.Build(reviewmap.Input{Diff: d})
	bs := Pack(m, d, nil)
	require.Len(t, bs, 1)
	assert.NotContains(t, bs[0].paths(), "assets/logo.png")

	user := BuildOverviewUser(bs[0], okIntent(), nil)
	assert.Contains(t, user, "=== OTHER CHANGED FILES (not shown) ===\nassets/logo.png (+0 −0) — not shown")
	assert.Contains(t, user, "the diff itself was truncated")
	assert.NotContains(t, BuildChaptersUser(bs[0], nil), "OTHER CHANGED FILES")

	raw := `{"summary":"s","coverage":[{"index":1,"item":"logo","status":"done","where":["assets/logo.png"]}],` +
		`"out_of_scope":["assets/logo.png"],"chapters":[{"key":"dir:server","what":"w"}]}`
	_, sum, err := ParseOverview(raw, bs[0], okIntent())
	require.NoError(t, err)
	require.Len(t, sum.Coverage, 1)
	assert.Equal(t, []string{"assets/logo.png"}, sum.Coverage[0].Where)
	assert.Equal(t, []string{"assets/logo.png"}, sum.OutOfScope)
}

// Pack's collapsedKey is the map's "Can skip" chapter key (reviewmap keeps
// its own copy unexported): the two must not drift apart.
func TestPack_CollapsedKeyMatchesTheMap(t *testing.T) {
	d := okDiff()
	d.Files = append(d.Files, reviewdiff.File{Path: "go.sum", Status: "modified", Additions: 40, CollapsedReason: "lockfile"})
	m := reviewmap.Build(reviewmap.Input{Diff: d})
	var keys []string
	for _, ch := range m.Chapters {
		if ch.Title == "Can skip" {
			keys = append(keys, ch.Key)
		}
	}
	require.Len(t, keys, 1)
	assert.Equal(t, collapsedKey, keys[0])
}
