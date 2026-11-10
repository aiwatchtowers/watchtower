package reviewai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/logcanary"
	"watchtower/internal/logredact"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/reviewmap"
)

// memStore is an in-memory PartStore that counts its writes.
type memStore struct {
	mu        sync.Mutex
	parts     map[string]db.ReviewOverviewPart
	overviews map[string]string // tree|base|hash → json
	partPuts  int
}

func newMemStore() *memStore {
	return &memStore{parts: map[string]db.ReviewOverviewPart{}, overviews: map[string]string{}}
}

func (s *memStore) ReviewOverviewParts(_ int64, hashes []string) (map[string]db.ReviewOverviewPart, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]db.ReviewOverviewPart{}
	for _, h := range hashes {
		if p, ok := s.parts[h]; ok {
			out[h] = p
		}
	}
	return out, nil
}

func (s *memStore) PutReviewOverviewPart(p db.ReviewOverviewPart, _ time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.parts[p.Hash] = p
	s.partPuts++
	return nil
}

func (s *memStore) PutReviewOverview(_ int64, tree, base, hash, js, _ string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.overviews[tree+"|"+base+"|"+hash] = js
	return nil
}

func (s *memStore) overview(t *testing.T) Overview {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	require.Len(t, s.overviews, 1)
	var o Overview
	for _, js := range s.overviews {
		require.NoError(t, json.Unmarshal([]byte(js), &o))
	}
	return o
}

// keyGen answers each call from the chapter keys of its prompt: a
// description per key ("about <key>"), the summary part on a full call. A
// batch holding a key in fail errors, one in hang blocks until its context
// ends, one in slow sleeps ignoring its context; skip leaves a key out of
// the reply. The summary call lists every NOT DESCRIBED chapter as
// not_covered, or fails with sumErr.
type keyGen struct {
	mu            sync.Mutex
	calls         int
	sources       []string
	users         []string
	batchKeys     [][]string // per chapters/overview call
	fail, hang    map[string]bool
	skip          map[string]bool
	slow          time.Duration
	slowKeys      map[string]bool
	sumErr        error
	failErr       error
	badSummary    bool // a full call's summary part is empty
	onBatchReturn func(keys []string)
}

func (g *keyGen) Generate(ctx context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	src, _ := digest.SourceFromContext(ctx)
	keys := promptKeys(user)
	g.mu.Lock()
	g.calls++
	g.sources = append(g.sources, src)
	g.users = append(g.users, user)
	if src != prompts.ReviewSummary {
		g.batchKeys = append(g.batchKeys, keys)
	}
	g.mu.Unlock()
	if src == prompts.ReviewSummary {
		if g.sumErr != nil {
			return "", nil, "", g.sumErr
		}
		var nc []string
		for _, block := range strings.Split(user, "\n\n") {
			if strings.Contains(block, "description: NOT DESCRIBED") {
				nc = append(nc, promptKeys(block)...)
			}
		}
		js, _ := json.Marshal(map[string]any{"summary": "the summary", "coverage": []any{}, "out_of_scope": []any{}, "not_covered": nc})
		return string(js), &digest.Usage{}, "", nil
	}
	defer func() {
		if g.onBatchReturn != nil {
			g.onBatchReturn(keys)
		}
	}()
	for _, k := range keys {
		switch {
		case g.hang[k]:
			<-ctx.Done()
			return "", nil, "", ctx.Err()
		case g.fail[k]:
			err := g.failErr
			if err == nil {
				err = errors.New("provider exploded")
			}
			return "", nil, "", err
		case g.slowKeys[k]:
			time.Sleep(g.slow)
		}
	}
	var chs []map[string]any
	for _, k := range keys {
		if !g.skip[k] {
			chs = append(chs, map[string]any{"key": k, "what": "about " + k, "risks": []any{}})
		}
	}
	reply := map[string]any{"chapters": chs}
	if src == prompts.ReviewOverview {
		reply["summary"], reply["coverage"], reply["out_of_scope"] = "the full summary", []any{}, []any{}
		if g.badSummary {
			reply["summary"] = ""
		}
	}
	js, _ := json.Marshal(reply)
	return string(js), &digest.Usage{}, "", nil
}

// promptKeys is every "key: K" line of a prompt.
func promptKeys(user string) []string {
	var keys []string
	for line := range strings.SplitSeq(user, "\n") {
		if k, ok := strings.CutPrefix(line, "key: "); ok {
			keys = append(keys, k)
		}
	}
	return keys
}

// dirsDiff is n directories of one 300-line file each: one chapter per
// directory, eight chapters per batch.
func dirsDiff(n int) reviewdiff.Diff {
	var d reviewdiff.Diff
	for i := range n {
		f := fileOf(fmt.Sprintf("d%02d/f.go", i), 300)
		f.NewBlob = fmt.Sprintf("blob-%02d", i)
		d.Files = append(d.Files, f)
	}
	return d
}

func dirsMap(d reviewdiff.Diff) reviewmap.Map { return reviewmap.Build(reviewmap.Input{Diff: d}) }

func batchKeysOf(bs []Batch) [][]string {
	var out [][]string
	for _, b := range bs {
		var keys []string
		for _, ch := range b.Chapters {
			keys = append(keys, ch.Key)
		}
		out = append(out, keys)
	}
	return out
}

// events collects a run's events.
type events struct {
	mu  sync.Mutex
	all []Event
}

func (e *events) emit(ev Event) { e.mu.Lock(); e.all = append(e.all, ev); e.mu.Unlock() }

func (e *events) chapterStates() map[string]Event {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := map[string]Event{}
	for _, ev := range e.all {
		if ev.Event == "chapter" {
			out[ev.Key] = ev
		}
	}
	return out
}

func fastPipeline(g digest.Generator) *Pipeline {
	p := New(g)
	p.callBudget = func(int) time.Duration { return 300 * time.Millisecond }
	p.summaryBudget = 5 * time.Second
	return p
}

// One batch fails at the provider and one hangs past its budget: the other
// chapters are described, the summary runs over them with the failed ones
// not covered, and the assembled overview names them incomplete.
func TestRun_FailedAndHungBatchesLeaveTheRest(t *testing.T) {
	d := dirsDiff(20)
	m := dirsMap(d)
	keys := batchKeysOf(Pack(m, d, nil))
	require.Len(t, keys, 3)
	g := &keyGen{fail: map[string]bool{keys[0][0]: true}, hang: map[string]bool{keys[1][0]: true}}
	store, ev := newMemStore(), &events{}
	o, err := fastPipeline(g).Run(context.Background(), store, m, d, okIntent(), nil,
		RunOptions{ProjectID: 1, Tree: "t", Base: "b", Emit: ev.emit})
	require.NoError(t, err)

	failed := append(slices.Clone(keys[0]), keys[1]...)
	assert.ElementsMatch(t, failed, o.Incomplete)
	states := ev.chapterStates()
	for _, k := range keys[0] {
		assert.Equal(t, StateFailed, states[k].State)
		assert.Equal(t, ClassProvider, states[k].Error.Class)
		assert.Equal(t, "provider exploded", states[k].Error.Detail)
	}
	for _, k := range keys[1] {
		assert.Equal(t, ClassTimeout, states[k].Error.Class)
	}
	for _, k := range keys[2] {
		assert.Equal(t, StateOK, states[k].State)
		assert.Equal(t, "about "+k, states[k].What)
	}
	assert.Equal(t, len(keys[2]), store.partPuts, "only described chapters are cached")
	assert.Equal(t, 4, g.calls, "three batches and the summary")
	assert.Equal(t, prompts.ReviewSummary, g.sources[3])
	assert.Equal(t, "the summary", o.Summary)
	last := ev.all[len(ev.all)-1]
	assert.Equal(t, "summary", last.Event)
	assert.Equal(t, StateOK, last.State)
	assert.ElementsMatch(t, failed, last.NotCovered)
	assert.Equal(t, o, store.overview(t), "the assembled overview is written")
}

// Nothing described: no summary call and no assembled overview.
func TestRun_ZeroDescribedNoSummary(t *testing.T) {
	d := dirsDiff(12)
	m := dirsMap(d)
	keys := batchKeysOf(Pack(m, d, nil))
	g := &keyGen{fail: map[string]bool{keys[0][0]: true, keys[1][0]: true}}
	store := newMemStore()
	_, err := fastPipeline(g).Run(context.Background(), store, m, d, nil, nil, RunOptions{})
	var re *RunError
	require.ErrorAs(t, err, &re)
	assert.Equal(t, ClassProvider, re.Class)
	assert.Equal(t, 2, g.calls)
	assert.NotContains(t, g.sources, prompts.ReviewSummary)
	assert.Empty(t, store.overviews)
}

// --chapter redoes only those chapters (ignoring their part rows), then the
// summary.
func TestRun_ChaptersRedoesOnlyThose(t *testing.T) {
	d := dirsDiff(20)
	m := dirsMap(d)
	keys := batchKeysOf(Pack(m, d, nil))
	g := &keyGen{}
	store := newMemStore()
	p := fastPipeline(g)
	_, err := p.Run(context.Background(), store, m, d, nil, nil, RunOptions{})
	require.NoError(t, err)
	require.Equal(t, 4, g.calls)

	g2 := &keyGen{}
	ev := &events{}
	redo := []string{keys[0][1], keys[2][0]}
	o, err := fastPipeline(g2).Run(context.Background(), store, m, d, nil, nil, RunOptions{Chapters: redo, Emit: ev.emit})
	require.NoError(t, err)
	assert.Equal(t, 2, g2.calls, "one batch of the two chapters, then the summary")
	assert.ElementsMatch(t, redo, g2.batchKeys[0])
	assert.Equal(t, prompts.ReviewSummary, g2.sources[1])
	assert.Empty(t, o.Incomplete)
	states := ev.chapterStates()
	assert.Equal(t, StateOK, states[redo[0]].State)
	assert.Equal(t, StateCached, states[keys[1][0]].State)
}

// --chapter: a chapter neither redone nor cached gets a not_started event,
// so a card left from an earlier run is told it has no description.
func TestRun_ChaptersUndescribedOthersNotStarted(t *testing.T) {
	d := dirsDiff(20)
	m := dirsMap(d)
	keys := batchKeysOf(Pack(m, d, nil))
	store := newMemStore()
	_, err := fastPipeline(&keyGen{fail: map[string]bool{keys[0][0]: true}}).Run(context.Background(), store, m, d, nil, nil, RunOptions{})
	require.NoError(t, err)

	ev := &events{}
	o, err := fastPipeline(&keyGen{}).Run(context.Background(), store, m, d, nil, nil,
		RunOptions{Chapters: []string{keys[1][0]}, Emit: ev.emit})
	require.NoError(t, err)
	states := ev.chapterStates()
	for _, k := range keys[0] {
		assert.Equal(t, StateNotStarted, states[k].State, k)
	}
	assert.Equal(t, StateOK, states[keys[1][0]].State)
	assert.Equal(t, StateCached, states[keys[2][0]].State)
	assert.ElementsMatch(t, keys[0], o.Incomplete)
}

// --summary needs every part; with them it makes only the summary call.
func TestRun_SummaryOnly(t *testing.T) {
	d := dirsDiff(12)
	m := dirsMap(d)
	store := newMemStore()
	g := &keyGen{}
	_, err := fastPipeline(g).Run(context.Background(), store, m, d, nil, nil, RunOptions{SummaryOnly: true})
	var re *RunError
	require.ErrorAs(t, err, &re)
	assert.Equal(t, ClassMissingParts, re.Class)
	assert.Zero(t, g.calls)

	_, err = fastPipeline(g).Run(context.Background(), store, m, d, nil, nil, RunOptions{})
	require.NoError(t, err)
	g2 := &keyGen{}
	_, err = fastPipeline(g2).Run(context.Background(), store, m, d, nil, nil, RunOptions{SummaryOnly: true})
	require.NoError(t, err)
	assert.Equal(t, []string{prompts.ReviewSummary}, g2.sources)
}

// A re-run after one file changed calls only for that file's chapter, then
// the summary; an intent change redoes no chapter.
func TestRun_CacheRedoesOnlyTheEditedChapter(t *testing.T) {
	d := dirsDiff(12)
	m := dirsMap(d)
	store := newMemStore()
	_, err := fastPipeline(&keyGen{}).Run(context.Background(), store, m, d, nil, nil, RunOptions{})
	require.NoError(t, err)

	d.Files[3].NewBlob = "edited"
	g := &keyGen{}
	_, err = fastPipeline(g).Run(context.Background(), store, dirsMap(d), d, okIntent(), nil, RunOptions{})
	require.NoError(t, err)
	require.Equal(t, 2, g.calls)
	assert.Equal(t, []string{"dir:d03"}, g.batchKeys[0])

	g2 := &keyGen{}
	_, err = fastPipeline(g2).Run(context.Background(), store, dirsMap(d), d, []IntentItem{{Text: "other"}}, nil, RunOptions{})
	require.NoError(t, err)
	assert.Equal(t, []string{prompts.ReviewSummary}, g2.sources)
}

// A map that fits one batch is always the one full call, part rows or not;
// its descriptions are written as parts.
func TestRun_OneBatchIsAlwaysTheFullCall(t *testing.T) {
	d := okDiff()
	m := reviewmap.Build(reviewmap.Input{Diff: d})
	store := newMemStore()
	for range 2 {
		g := &keyGen{}
		o, err := New(g).Run(context.Background(), store, m, d, okIntent(), nil, RunOptions{})
		require.NoError(t, err)
		assert.Equal(t, []string{prompts.ReviewOverview}, g.sources)
		assert.Equal(t, "the full summary", o.Summary)
		assert.Empty(t, o.Incomplete)
	}
	assert.Equal(t, 4, store.partPuts)
}

// Carry-over: a full call whose summary part is invalid keeps its chapter
// descriptions; the summary fails on its own and nothing is assembled.
func TestRun_FullCallBadSummaryKeepsTheChapters(t *testing.T) {
	d := okDiff()
	m := reviewmap.Build(reviewmap.Input{Diff: d})
	store, ev := newMemStore(), &events{}
	_, err := New(&keyGen{badSummary: true}).Run(context.Background(), store, m, d, okIntent(), nil, RunOptions{Emit: ev.emit})
	var re *RunError
	require.ErrorAs(t, err, &re)
	assert.Equal(t, ClassParse, re.Class)
	assert.Equal(t, "The AI answer for the summary could not be read.", re.Text)
	assert.Equal(t, 2, store.partPuts)
	assert.Empty(t, store.overviews)
	for _, ev := range ev.chapterStates() {
		assert.Equal(t, StateOK, ev.State)
	}
	last := ev.all[len(ev.all)-1]
	assert.Equal(t, "summary", last.Event)
	assert.Equal(t, StateFailed, last.State)

	// --summary then makes the summary from those parts.
	g := &keyGen{}
	o, err := New(g).Run(context.Background(), store, m, d, okIntent(), nil, RunOptions{SummaryOnly: true})
	require.NoError(t, err)
	assert.Equal(t, []string{prompts.ReviewSummary}, g.sources)
	assert.Equal(t, "the summary", o.Summary)
}

// Carry-over: a chapter the reply left out is failed (parse); the rest of
// its batch is described.
func TestRun_ChapterLeftOutOfTheReplyIsParse(t *testing.T) {
	d := dirsDiff(12)
	m := dirsMap(d)
	keys := batchKeysOf(Pack(m, d, nil))
	ev := &events{}
	o, err := fastPipeline(&keyGen{skip: map[string]bool{keys[0][2]: true}}).Run(context.Background(), newMemStore(), m, d, nil, nil,
		RunOptions{Emit: ev.emit})
	require.NoError(t, err)
	assert.Equal(t, []string{keys[0][2]}, o.Incomplete)
	st := ev.chapterStates()[keys[0][2]]
	assert.Equal(t, StateFailed, st.State)
	assert.Equal(t, ClassParse, st.Error.Class)
	assert.Equal(t, StateOK, ev.chapterStates()[keys[0][0]].State)
}

// Batches whose turn comes after the run's ceiling are not_started; the
// summary still runs.
func TestRun_NotStartedPastTheCeiling(t *testing.T) {
	d := dirsDiff(36)
	m := dirsMap(d)
	keys := batchKeysOf(Pack(m, d, nil))
	require.Len(t, keys, 5)
	slow := map[string]bool{}
	for _, b := range keys[:4] {
		slow[b[0]] = true
	}
	p := New(&keyGen{slowKeys: slow, slow: 500 * time.Millisecond})
	p.callBudget = func(int) time.Duration { return 150 * time.Millisecond }
	p.summaryBudget = 5 * time.Second
	ev := &events{}
	o, err := p.Run(context.Background(), newMemStore(), m, d, nil, nil, RunOptions{Emit: ev.emit})
	require.NoError(t, err)
	assert.ElementsMatch(t, keys[4], o.Incomplete)
	for _, k := range keys[4] {
		assert.Equal(t, StateNotStarted, ev.chapterStates()[k].State)
	}
}

// SIGTERM mid-run (a cancelled context): finished parts stay, the run ends
// cancelled, and a re-run calls only for the rest.
func TestRun_CancelKeepsFinishedParts(t *testing.T) {
	d := dirsDiff(12)
	m := dirsMap(d)
	keys := batchKeysOf(Pack(m, d, nil))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	store := newMemStore()
	g := &keyGen{hang: map[string]bool{keys[1][0]: true}}
	g.onBatchReturn = func(k []string) {
		if k[0] == keys[0][0] {
			go cancel() // the first batch is written; stop the run
		}
	}
	p := New(g)
	_, err := p.Run(ctx, store, m, d, nil, nil, RunOptions{})
	var re *RunError
	require.ErrorAs(t, err, &re)
	assert.Equal(t, ClassCancelled, re.Class)
	assert.Equal(t, len(keys[0]), store.partPuts)
	assert.Empty(t, store.overviews)

	g2 := &keyGen{}
	_, err = New(g2).Run(context.Background(), store, m, d, nil, nil, RunOptions{})
	require.NoError(t, err)
	require.Equal(t, 2, g2.calls)
	assert.ElementsMatch(t, keys[1], g2.batchKeys[0])
}

// Parts are database rows: a new handle on the same file reuses them.
func TestRun_PartsSurviveANewDBHandle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.db")
	d := dirsDiff(12)
	m := dirsMap(d)
	open := func() *db.DB {
		database, err := db.Open(path)
		require.NoError(t, err)
		return database
	}
	first := open()
	wb, err := first.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	_, err = fastPipeline(&keyGen{}).Run(context.Background(), first, m, d, nil, nil, RunOptions{ProjectID: wb, Tree: "t", Base: "b"})
	require.NoError(t, err)
	require.NoError(t, first.Close())

	second := open()
	t.Cleanup(func() { _ = second.Close() })
	g := &keyGen{}
	_, err = fastPipeline(g).Run(context.Background(), second, m, d, []IntentItem{{Text: "new"}}, nil, RunOptions{ProjectID: wb, Tree: "t", Base: "b"})
	require.NoError(t, err)
	assert.Equal(t, []string{prompts.ReviewSummary}, g.sources)
}

func TestRun_ErrorTextsVerbatim(t *testing.T) {
	cause := errors.New("x")
	assert.Equal(t, "The overview of “api” did not finish in 5 min.", failure(ClassTimeout, "api", CallBudget(2500), cause).Text)
	assert.Equal(t, "The overview of “api” did not finish in 3 min.", failure(ClassTimeout, "api", CallBudget(1000), cause).Text)
	assert.Equal(t, "The AI provider failed on “api”.", failure(ClassProvider, "api", 0, cause).Text)
	assert.Equal(t, "The AI answer for “api” could not be read.", failure(ClassParse, "api", 0, cause).Text)
	assert.Equal(t, "The overview of the summary did not finish in 2 min.", failure(ClassTimeout, summaryTitle, SummaryBudget, cause).Text)
	assert.Equal(t, "The AI provider failed on the summary.", failure(ClassProvider, summaryTitle, 0, cause).Text)
	assert.Equal(t, "x", failure(ClassProvider, "api", 0, cause).Detail)
	redacted := logredact.Errorf("claude CLI failed: %s", logredact.Text("quota reached"))
	assert.Equal(t, "claude CLI failed: quota reached", failure(ClassProvider, "api", 0, redacted).Detail,
		"detail is the provider's full text, not the fingerprinted Error()")
	assert.Empty(t, failure(ClassParse, "api", 0, nil).Detail)
	// The one full call is the whole overview, not a chapter (carry-over, Task 9).
	assert.Equal(t, "The overview did not finish in 5 min.", failure(ClassTimeout, overviewTitle, CallBudget(2500), cause).Text)
	assert.Equal(t, "The AI provider failed on the overview.", failure(ClassProvider, overviewTitle, 0, cause).Text)
	assert.Equal(t, "The AI answer for the overview could not be read.", failure(ClassParse, overviewTitle, 0, cause).Text)
}

// Carry-over (Task 9): the one full call failing is the run's error, and it
// names the overview, not the first chapter.
func TestRun_FullCallFailureNamesTheOverview(t *testing.T) {
	d := okDiff()
	m := reviewmap.Build(reviewmap.Input{Diff: d})
	keys := batchKeysOf(Pack(m, d, nil))
	require.Len(t, keys, 1)
	store := newMemStore()
	_, err := New(&keyGen{fail: map[string]bool{keys[0][0]: true}}).Run(context.Background(), store, m, d, okIntent(), nil, RunOptions{})
	var re *RunError
	require.ErrorAs(t, err, &re)
	assert.Equal(t, ClassProvider, re.Class)
	assert.Equal(t, "The AI provider failed on the overview.", re.Text)
	assert.Equal(t, "provider exploded", re.Detail)
	assert.Empty(t, store.overviews)
}

// A full call whose reply leaves every chapter out is a parse error of the
// call, so it names the
// overview too, not the first chapter.
func TestRun_FullCallLeavingEveryChapterOutNamesTheOverview(t *testing.T) {
	d := okDiff()
	m := reviewmap.Build(reviewmap.Input{Diff: d})
	keys := batchKeysOf(Pack(m, d, nil))
	require.Len(t, keys, 1)
	skip := map[string]bool{}
	for _, k := range keys[0] {
		skip[k] = true
	}
	_, err := New(&keyGen{skip: skip}).Run(context.Background(), newMemStore(), m, d, okIntent(), nil, RunOptions{})
	var re *RunError
	require.ErrorAs(t, err, &re)
	assert.Equal(t, ClassParse, re.Class)
	assert.Equal(t, "The AI answer for the overview could not be read.", re.Text)
}

// Carry-over (Task 9): a call the run's ceiling cut names the ceiling's
// minutes, not its own budget's.
func TestTimeoutBudget_NamesWhatCutTheCall(t *testing.T) {
	live := context.Background()
	cut, cancel := context.WithCancel(context.Background())
	cancel()
	assert.Equal(t, 3*time.Minute, timeoutBudget(live, 3*time.Minute, 12*time.Minute), "the call's own budget ran out")
	assert.Equal(t, 12*time.Minute, timeoutBudget(cut, 3*time.Minute, 12*time.Minute), "the run's ceiling cut the call")
}

// PartHash covers the chapter's files and its own notes and the prompt,
// never other notes.
func TestPartHash(t *testing.T) {
	ch := reviewmap.Chapter{Key: "dir:a", Paths: []string{"a/x.go"}}
	files := []reviewdiff.File{{Path: "a/x.go", OldBlob: "o", NewBlob: "n"}}
	base := PartHash(ch, files, nil, prompts.ReviewChapters, 1)
	assert.Equal(t, base, PartHash(ch, files, []db.ReviewNote{{Kind: "note", Path: "b/y.go", Text: "elsewhere"}}, prompts.ReviewChapters, 1))
	assert.NotEqual(t, base, PartHash(ch, files, []db.ReviewNote{{Kind: "note", Path: "a/x.go", Text: "here"}}, prompts.ReviewChapters, 1))
	assert.NotEqual(t, base, PartHash(ch, files, nil, prompts.ReviewChapters, 2))
	assert.NotEqual(t, base, PartHash(ch, files, nil, prompts.ReviewOverview, 1))
	edited := []reviewdiff.File{{Path: "a/x.go", OldBlob: "o", NewBlob: "n2"}}
	assert.NotEqual(t, base, PartHash(ch, edited, nil, prompts.ReviewChapters, 1))
	rebased := []reviewdiff.File{{Path: "a/x.go", OldBlob: "o2", NewBlob: "n"}}
	assert.NotEqual(t, base, PartHash(ch, rebased, nil, prompts.ReviewChapters, 1))
	assert.NotEqual(t, base, PartHash(reviewmap.Chapter{Key: "dir:b"}, files, nil, prompts.ReviewChapters, 1))
}

// FILES-01: a run with a failing chapter batch and a failing summary logs
// classes and counts only — no chapter title, path or provider text; the
// provider's text reaches stderr.
func TestFILES01_ReviewOverviewNeverLogsContent(t *testing.T) {
	sink := logcanary.Capture(t)
	dir := logcanary.Text("dir")
	var d reviewdiff.Diff
	for i := range 12 {
		f := fileOf(fmt.Sprintf("%s%02d/f.go", dir, i), 300)
		d.Files = append(d.Files, f)
	}
	m := dirsMap(d)
	keys := batchKeysOf(Pack(m, d, nil))
	g := &keyGen{fail: map[string]bool{keys[0][0]: true}, failErr: errors.New(logcanary.Text("provider")),
		sumErr: errors.New(logcanary.Text("summary-provider"))}
	var stderr bytes.Buffer
	_, err := fastPipeline(g).Run(context.Background(), newMemStore(), m, d, nil, nil, RunOptions{Stderr: &stderr})
	var re *RunError
	require.ErrorAs(t, err, &re)
	sink.AssertClean(t)
	assert.NotEmpty(t, sink.String(), "the failures are logged")
	assert.Contains(t, stderr.String(), logcanary.Text("provider"))
	assert.Contains(t, re.Detail, logcanary.Text("summary-provider"))
}

// A summary that fails after the batches (the multi-batch path): the
// failed summary event is emitted, the run answers the summary's error,
// nothing is assembled, the parts stay, and a summary-only run then makes
// the overview from them without describing anything again (spec frame 2c).
func TestRun_MultiBatchSummaryFailureKeepsPartsAndEmitsFailed(t *testing.T) {
	var d reviewdiff.Diff
	for i := range 12 {
		d.Files = append(d.Files, fileOf(fmt.Sprintf("dir%02d/f.go", i), 300))
	}
	m := dirsMap(d)
	require.Greater(t, len(Pack(m, d, nil)), 1, "the multi-batch path")
	store := newMemStore()
	var events []Event
	var mu sync.Mutex
	g := &keyGen{sumErr: errors.New("HTTP 529")}
	_, err := fastPipeline(g).Run(context.Background(), store, m, d, nil, nil, RunOptions{Stderr: io.Discard,
		Emit: func(e Event) { mu.Lock(); events = append(events, e); mu.Unlock() }})
	var re *RunError
	require.ErrorAs(t, err, &re)
	assert.Contains(t, re.Text, "the summary")
	last := events[len(events)-1]
	assert.Equal(t, "summary", last.Event)
	assert.Equal(t, StateFailed, last.State)
	require.NotNil(t, last.Error)
	assert.Equal(t, re.Text, last.Error.Text)
	assert.Empty(t, store.overviews, "nothing assembled")
	assert.NotZero(t, store.partPuts, "the described chapters are kept")

	g2 := &keyGen{}
	o, err := fastPipeline(g2).Run(context.Background(), store, m, d, nil, nil, RunOptions{SummaryOnly: true, Stderr: io.Discard})
	require.NoError(t, err)
	assert.Equal(t, "the summary", o.Summary)
	assert.Equal(t, 1, g2.calls, "only the summary call")
	assert.Len(t, store.overviews, 1)
}
