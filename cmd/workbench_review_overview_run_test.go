package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/tools"
)

// Board #1025: the overview run — per-chapter parts, the streamed form,
// --chapter / --summary / --continue, lane intent items.

// keyReviewGen answers from the chapter keys of each prompt: "about <key>"
// and a low risk on its first file per chapter, a done coverage entry per
// intent item on a full call or the summary. A batch holding a key in fail
// errors, a key in skip is left out of the reply; with release set, every
// call waits for it (started is closed at the first call).
type keyReviewGen struct {
	mu      sync.Mutex
	calls   int
	sources []string
	users   []string
	batches [][]string
	fail    map[string]bool
	skip    map[string]bool
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

func (g *keyReviewGen) Generate(ctx context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	src, _ := digest.SourceFromContext(ctx)
	keys := reviewPromptKeys(user)
	g.mu.Lock()
	g.calls++
	g.sources = append(g.sources, src)
	g.users = append(g.users, user)
	if src != prompts.ReviewSummary {
		g.batches = append(g.batches, keys)
	}
	g.mu.Unlock()
	if g.release != nil {
		g.once.Do(func() { close(g.started) })
		select {
		case <-g.release:
		case <-ctx.Done():
			return "", nil, "", ctx.Err()
		}
	}
	reply := map[string]any{}
	if src == prompts.ReviewSummary || src == prompts.ReviewOverview {
		var cov []map[string]any
		for i := range reviewPromptIntentItems(user) {
			cov = append(cov, map[string]any{"index": i + 1, "item": fmt.Sprintf("item %d", i+1), "status": "done", "where": []string{}})
		}
		reply["summary"], reply["coverage"], reply["out_of_scope"], reply["not_covered"] = "the summary", cov, []string{}, []string{}
	}
	if src != prompts.ReviewSummary {
		var chs []map[string]any
		for _, k := range keys {
			if g.fail[k] {
				return "", nil, "", errors.New("boom")
			}
			if g.skip[k] {
				continue
			}
			chs = append(chs, map[string]any{"key": k, "what": "about " + k,
				"risks": []any{map[string]any{"path": reviewPromptFirstFile(user, k), "level": "low", "why": "check " + k}}})
		}
		reply["chapters"] = chs
	}
	js, _ := json.Marshal(reply)
	return string(js), &digest.Usage{}, "", nil
}

func (g *keyReviewGen) count() (int, [][]string, []string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.calls, g.batches, g.sources
}

func reviewPromptKeys(user string) []string {
	var keys []string
	for line := range strings.SplitSeq(user, "\n") {
		if k, ok := strings.CutPrefix(line, "key: "); ok {
			keys = append(keys, k)
		}
	}
	return keys
}

// reviewPromptFirstFile is the first file of chapter key in a prompt.
func reviewPromptFirstFile(user, key string) string {
	_, rest, _ := strings.Cut(user, "key: "+key+"\n")
	_, files, _ := strings.Cut(rest, "files: ")
	line, _, _ := strings.Cut(files, "\n")
	first, _, _ := strings.Cut(line, ", ")
	return first
}

// reviewPromptIntentItems is the numbered items of a prompt's INTENT block.
func reviewPromptIntentItems(user string) []string {
	_, rest, ok := strings.Cut(user, "=== INTENT ===\n")
	if !ok {
		return nil
	}
	block, _, _ := strings.Cut(rest, "===")
	var items []string
	for line := range strings.SplitSeq(block, "\n") {
		if n, text, ok := strings.Cut(line, ". "); ok && n != "" && strings.Trim(n, "0123456789") == "" {
			items = append(items, text)
		}
	}
	return items
}

// bigOverviewRound: twelve uncommitted 300-line files in directories of
// their own (twelve chapters, two batches) and an open round.
func bigOverviewRound(t *testing.T) (database *db.DB, wb, session int64, round, repo string) {
	t.Helper()
	database, wb, session, repo = reviewFixture(t)
	for i := range 12 {
		writeRepoFile(t, repo, fmt.Sprintf("d%02d/f.go", i), strings.Repeat(fmt.Sprintf("line %d\n", i), 300))
	}
	r := startRound(t, wb, session)
	return database, wb, session, itoa(int64(r["id"].(float64))), repo
}

func strs(v any) []string {
	var out []string
	for _, s := range v.([]any) {
		out = append(out, s.(string))
	}
	return out
}

// A failed batch leaves its chapters incomplete; the summary and the
// assembled row are made over the rest. --chapter redoes only the given
// chapters, --continue the rest, --summary only the summary.
func TestWorkbenchReviewOverview_FailedBatchThenChapterContinueSummary(t *testing.T) {
	database, wb, _, round, _ := bigOverviewRound(t)
	probe := &keyReviewGen{}
	useReviewGenerator(t, probe)
	first := reviewJSON(t, wb, "overview", "--round", round, "--summary")
	assert.Equal(t, false, first["ok"])
	assert.Equal(t, "missing_parts", first["error_class"])
	assert.Zero(t, probe.calls, "--summary with a part missing calls nothing")

	// The batch holding dir:d00 fails at the provider.
	dry := &keyReviewGen{fail: map[string]bool{"dir:d00": true}}
	useReviewGenerator(t, dry)
	out := reviewJSON(t, wb, "overview", "--round", round)
	require.Equal(t, true, out["ok"], out)
	calls, batches, sources := dry.count()
	require.Equal(t, 3, calls, "two batches and the summary")
	assert.Equal(t, prompts.ReviewSummary, sources[2])
	var failedBatch []string
	for _, b := range batches {
		if strings.Contains(strings.Join(b, ","), "dir:d00") {
			failedBatch = b
		}
	}
	require.NotEmpty(t, failedBatch)
	assert.ElementsMatch(t, failedBatch, strs(out["incomplete"]))
	assert.ElementsMatch(t, failedBatch, strs(out["overview"].(map[string]any)["incomplete"]))
	assert.Equal(t, 1, countRows(t, database, "SELECT COUNT(*) FROM review_overviews"), "the assembled overview is written")
	assert.Equal(t, 12-len(failedBatch), countRows(t, database, "SELECT COUNT(*) FROM review_overview_parts"))

	// The same call answers the cached, incomplete overview.
	again := reviewJSON(t, wb, "overview", "--round", round)
	assert.Equal(t, true, again["overview_cached"])
	assert.ElementsMatch(t, failedBatch, strs(again["incomplete"]))

	g := &keyReviewGen{}
	useReviewGenerator(t, g)
	redo := reviewJSON(t, wb, "overview", "--round", round, "--chapter", failedBatch[0], "--chapter", failedBatch[1])
	require.Equal(t, true, redo["ok"], redo)
	calls, batches, sources = g.count()
	require.Equal(t, 2, calls)
	assert.ElementsMatch(t, failedBatch[:2], batches[0])
	assert.Equal(t, prompts.ReviewSummary, sources[1])
	assert.ElementsMatch(t, failedBatch[2:], strs(redo["incomplete"]))

	g = &keyReviewGen{}
	useReviewGenerator(t, g)
	cont := reviewJSON(t, wb, "overview", "--round", round, "--continue")
	require.Equal(t, true, cont["ok"], cont)
	calls, batches, _ = g.count()
	require.Equal(t, 2, calls)
	assert.ElementsMatch(t, failedBatch[2:], batches[0])
	assert.Equal(t, []string(nil), strs(cont["incomplete"]))

	g = &keyReviewGen{}
	useReviewGenerator(t, g)
	done := reviewJSON(t, wb, "overview", "--round", round, "--continue")
	assert.Equal(t, true, done["overview_cached"], "nothing left to continue")
	sum := reviewJSON(t, wb, "overview", "--round", round, "--summary")
	require.Equal(t, true, sum["ok"], sum)
	_, _, sources = g.count()
	assert.Equal(t, []string{prompts.ReviewSummary}, sources)
}

// Refresh after editing one file: only its chapter is described again.
func TestWorkbenchReviewOverview_RefreshRedoesOnlyTheEditedChapter(t *testing.T) {
	_, wb, s, round, repo := bigOverviewRound(t)
	useReviewGenerator(t, &keyReviewGen{})
	require.Equal(t, true, reviewJSON(t, wb, "overview", "--round", round)["ok"])

	writeRepoFile(t, repo, "d03/f.go", strings.Repeat("edited\n", 300))
	reviewJSON(t, wb, "start", "--session", itoa(s), "--refresh")
	g := &keyReviewGen{}
	useReviewGenerator(t, g)
	out := reviewJSON(t, wb, "overview", "--round", round)
	require.Equal(t, true, out["ok"], out)
	calls, batches, _ := g.count()
	require.Equal(t, 2, calls)
	assert.Equal(t, []string{"dir:d03"}, batches[0])
}

func TestWorkbenchReviewOverview_FlagRefusals(t *testing.T) {
	_, wb, _, round := overviewRound(t)
	for _, args := range [][]string{
		{"--summary", "--continue"},
		{"--cached-only", "--chapter", "dir:"},
		{"--caller", "robot"},
	} {
		_, _, err := runWorkbench(t, append([]string{"review", "overview", "--workbench", itoa(wb), "--json", "--round", round}, args...)...)
		resetSetFlags(workbenchReviewCmd.Commands()...)
		assert.Error(t, err, "%v", args)
	}
	_, _, err := runWorkbench(t, "review", "overview", "--workbench", itoa(wb), "--round", round, "--stream")
	resetSetFlags(workbenchReviewCmd.Commands()...)
	require.EqualError(t, err, "--stream needs --json")
}

// Lane tickets join the intent after the session's items, with source
// "lane"; a new lane ticket changes the intent the overview is cached for.
// A round with no session has lane items only.
func TestWorkbenchReviewOverview_LaneIntentItems(t *testing.T) {
	database, wb, s, _, boardTarget := mapFixture(t)
	goal := db.SeedTestWorkbenchTarget(t, database, wb, sql.NullInt64{}, "Session goal")
	require.NoError(t, database.LinkSessionTarget(s, goal))
	r := startRound(t, wb, s)
	round := itoa(int64(r["id"].(float64)))
	g := &keyReviewGen{}
	useReviewGenerator(t, g)

	out := reviewJSON(t, wb, "overview", "--round", round)
	require.Equal(t, true, out["ok"], out)
	items := reviewPromptIntentItems(g.users[0])
	require.Len(t, items, 3, g.users[0])
	assert.Equal(t, "Session goal", items[0])
	assert.ElementsMatch(t, []string{"Payments lane", "ABC-1 Login with a passkey"}, items[1:])
	assert.Equal(t, 2, strings.Count(g.users[0], "From: the ticket of a lane"))
	var sources []string
	for _, c := range out["overview"].(map[string]any)["coverage"].([]any) {
		sources = append(sources, c.(map[string]any)["source"].(string))
	}
	assert.Equal(t, []string{"session", "lane", "lane"}, sources)

	// The board lane loses its ticket, then gets it back: each is a new
	// intent, asked again.
	_, err := database.Exec(`UPDATE targets SET branch = 'elsewhere' WHERE id = ?`, boardTarget)
	require.NoError(t, err)
	assert.NotEqual(t, true, reviewJSON(t, wb, "overview", "--round", round)["overview_cached"])
	_, err = database.Exec(`UPDATE targets SET branch = 'task-b' WHERE id = ?`, boardTarget)
	require.NoError(t, err)
	assert.Equal(t, true, reviewJSON(t, wb, "overview", "--round", round)["overview_cached"])
	assert.Equal(t, 2, g.calls)

	_, err = database.Exec(`UPDATE review_rounds SET session_id = NULL WHERE id = ?`, round)
	require.NoError(t, err)
	lanesOnly := reviewJSON(t, wb, "overview", "--round", round)
	require.Equal(t, true, lanesOnly["ok"], lanesOnly)
	items = reviewPromptIntentItems(g.users[len(g.users)-1])
	assert.ElementsMatch(t, []string{"Payments lane", "ABC-1 Login with a passkey"}, items)
}

// streamLines runs the streamed form and returns its lines.
func overviewStreamLines(t *testing.T, wb int64, args ...string) []string {
	t.Helper()
	out, _, err := runWorkbench(t, append([]string{"review", "overview", "--workbench", itoa(wb), "--json", "--stream"}, args...)...)
	resetSetFlags(workbenchReviewCmd.Commands()...)
	require.NoError(t, err)
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	for _, l := range lines {
		require.True(t, json.Valid([]byte(l)), "not one JSON object per line: %q", l)
	}
	return lines
}

// TestWorkbenchReviewOverview_StreamGolden pins the streamed form
// (testdata/review-overview-stream.jsonl, decoded by WatchtowerCore): the
// map first, a chapter line each (one the reply left out: failed), the
// summary, the envelope last.
func TestWorkbenchReviewOverview_StreamGolden(t *testing.T) {
	_, wb, s, _, _ := mapFixture(t)
	r := startRound(t, wb, s)
	useReviewGenerator(t, &keyReviewGen{skip: map[string]bool{"lane:task-b": true}})
	lines := overviewStreamLines(t, wb, "--round", itoa(int64(r["id"].(float64))))
	out := strings.Join(lines, "\n") + "\n"
	golden := filepath.Join("testdata", "review-overview-stream.jsonl")
	if *updateSessionReportGolden {
		require.NoError(t, os.WriteFile(golden, []byte(out), 0o644))
	}
	want, err := os.ReadFile(golden)
	require.NoError(t, err)
	assert.Equal(t, string(want), out, "the stream changed: re-run with -update and update the Desktop fixture")

	var first, last map[string]any
	require.NoError(t, json.Unmarshal([]byte(lines[0]), &first))
	require.NoError(t, json.Unmarshal([]byte(lines[len(lines)-1]), &last))
	assert.Equal(t, "map", first["event"])
	assert.Equal(t, true, last["ok"])
	assert.Equal(t, []any{"lane:task-b"}, last["incomplete"])
	assert.Contains(t, out, `{"event":"chapter","key":"lane:task-b","state":"failed","error":{"class":"parse","text":"The AI answer for “Payments lane” could not be read."}}`)
	var summary map[string]any
	require.NoError(t, json.Unmarshal([]byte(lines[len(lines)-2]), &summary))
	assert.Equal(t, "summary", summary["event"])
	assert.Equal(t, "ok", summary["state"])

	// A cached answer streams the map and the envelope.
	again := overviewStreamLines(t, wb, "--round", itoa(int64(r["id"].(float64))))
	require.Len(t, again, 2)
	assert.Contains(t, again[1], `"overview_cached":true`)
}

// The streamed form prints a tick every 30 s while a model call is slow.
func TestWorkbenchReviewOverview_StreamTicks(t *testing.T) {
	_, wb, _, round := overviewRound(t)
	ticks := make(chan time.Time)
	old := reviewStreamTicker
	var every time.Duration
	reviewStreamTicker = func(d time.Duration) (<-chan time.Time, func()) { every = d; return ticks, func() {} }
	t.Cleanup(func() { reviewStreamTicker = old })
	g := &keyReviewGen{started: make(chan struct{}), release: make(chan struct{})}
	useReviewGenerator(t, g)

	res := make(chan []string, 1)
	go func() { res <- overviewStreamLines(t, wb, "--round", round) }()
	select {
	case <-g.started:
	case <-time.After(10 * time.Second):
		t.Fatal("the model call never started")
	}
	ticks <- time.Now()
	ticks <- time.Now()
	close(g.release)
	var lines []string
	select {
	case lines = <-res:
	case <-time.After(10 * time.Second):
		t.Fatal("the command did not return")
	}
	assert.Equal(t, 30*time.Second, every)
	var events []string
	for _, l := range lines {
		var e map[string]any
		require.NoError(t, json.Unmarshal([]byte(l), &e))
		ev, _ := e["event"].(string)
		events = append(events, ev)
	}
	assert.Equal(t, []string{"map", "tick", "tick", "chapter", "summary", ""}, events)
}

// The finish gate reads the overview the session form made, lane items and
// all.
func TestWorkbenchReviewOverview_SessionFormKeysTheFinishGate(t *testing.T) {
	database, wb, s, _, _ := mapFixture(t)
	useReviewGenerator(t, &keyReviewGen{})
	out := reviewJSON(t, wb, "overview", "--session", itoa(s))
	require.Equal(t, true, out["ok"], out)
	p, err := database.GetWorkbench(wb)
	require.NoError(t, err)
	snap, err := tools.SnapshotReviewSession(context.Background(), database, p, s)
	require.NoError(t, err)
	lanes, err := sessionLaneIntent(context.Background(), database, p, s, snap)
	require.NoError(t, err)
	assert.Len(t, lanes, 2)
	again := reviewJSON(t, wb, "overview", "--session", itoa(s), "--cached-only")
	assert.Equal(t, true, again["overview_cached"], again)
}
