package reviewai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"slices"
	"sync"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/logredact"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewdiff"
	"watchtower/internal/reviewmap"
)

// Chapter states of a run (tech spec §3.5).
const (
	StateCached     = "cached"
	StateOK         = "ok"
	StateFailed     = "failed"
	StateNotStarted = "not_started"
)

// Error classes of a run (tech spec §3.6); ClassMissingParts is the
// refusal of a summary-only run with an undescribed chapter.
const (
	ClassTimeout      = "timeout"
	ClassProvider     = "provider"
	ClassParse        = "parse"
	ClassCancelled    = "cancelled"
	ClassTooLarge     = "too_large"
	ClassBusy         = "busy"
	ClassMissingParts = "missing_parts"
)

// CancelledText is the owner's text of a cancelled run.
const CancelledText = "The overview was stopped."

// Owner texts of the failures without a chapter title.
const (
	tooLargeText     = "No chapter has a diff the AI can read: its files are binary or past the diff's size limit."
	missingPartsText = "Some chapters have no description yet; run the overview to describe them first."
	summaryTitle     = "the summary"
)

// RunError is a failed chapter, summary or run: its class, the owner's
// sentence and the provider's own text (Detail), which goes to the
// envelope and stderr, never to the log. Error() is the owner's sentence:
// it names a chapter title, so it is never logged either (FILES-01).
type RunError struct {
	Class  string `json:"class"`
	Text   string `json:"text"`
	Detail string `json:"detail,omitempty"`
}

func (e *RunError) Error() string { return e.Text }

// EventChapter is a chapter event's description.
type EventChapter struct {
	What  string `json:"what"`
	Risks []Risk `json:"risks"`
}

// Event is one line of the streamed form (tech spec §3.5): map, waiting,
// tick, chapter (Key, State, the description or Error) or summary (State,
// the summary part or Error).
type Event struct {
	Event string         `json:"event"`
	Key   string         `json:"key,omitempty"`
	State string         `json:"state,omitempty"`
	By    string         `json:"by,omitempty"`
	Map   *reviewmap.Map `json:"map,omitempty"`
	*EventChapter
	*Summary
	Error *RunError `json:"error,omitempty"`
}

// PartStore is where a run keeps its chapter descriptions and the
// assembled overview: *db.DB.
type PartStore interface {
	ReviewOverviewParts(projectID int64, hashes []string) (map[string]db.ReviewOverviewPart, error)
	PutReviewOverviewPart(p db.ReviewOverviewPart, now time.Time) error
	PutReviewOverview(projectID int64, tree, base, intentHash, js, model string) error
}

// RunOptions shape a run. ProjectID, Tree and Base key its rows; Model is
// stored with them. Chapters (the --chapter form) redoes only those
// chapters, ignoring their part rows; SummaryOnly redoes only the summary
// from the part rows. Emit receives every event (serialized; nil drops
// them), Now stamps the part rows, Stderr gets the provider's own text.
type RunOptions struct {
	ProjectID   int64
	Tree, Base  string
	Model       string
	Chapters    []string
	SummaryOnly bool
	Emit        func(Event)
	Now         func() time.Time
	Stderr      io.Writer
}

// PartHash is a chapter's cache key (tech spec §3.3): its key, each of its
// files' (path, old blob, new blob), the agent's line notes on those files
// and the prompt that describes it. No intent and no other notes.
func PartHash(ch reviewmap.Chapter, files []reviewdiff.File, notes []db.ReviewNote, promptID string, promptVersion int) string {
	type file struct{ Path, OldPath, OldBlob, NewBlob string }
	type note struct {
		Path               string
		StartLine, EndLine int
		Quote, Text        string
	}
	in := map[string]bool{}
	fs := make([]file, 0, len(files))
	for _, f := range files {
		in[f.Path] = true
		fs = append(fs, file{f.Path, f.OldPath, f.OldBlob, f.NewBlob})
	}
	ns := []note{}
	for _, n := range notes {
		if n.Kind != "chapter" && in[n.Path] {
			ns = append(ns, note{n.Path, n.StartLine, n.EndLine, n.Quote, n.Text})
		}
	}
	b, _ := json.Marshal(struct {
		Key     string
		Files   []file
		Notes   []note
		Prompt  string
		Version int
	}{ch.Key, fs, ns, promptID, promptVersion})
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// promptVersion is the version of prompt id the run uses: the store's, or
// the built-in default's.
func (p *Pipeline) promptVersion(id string) int {
	if _, v, err := prompts.Resolve(p.store, id, ""); err == nil && v > 0 {
		return v
	}
	return prompts.DefaultVersions[id]
}

// run is one Run's shared state; mu guards every field below it.
type run struct {
	p      *Pipeline
	store  PartStore
	opt    RunOptions
	m      reviewmap.Map
	intent []IntentItem
	notes  []db.ReviewNote
	root   context.Context // the caller's: done = cancelled
	hashes map[string]string

	mu       sync.Mutex
	descs    map[string]ChapterDesc // described: cached, ok and not shown
	failures map[string]*RunError   // key → its failure
	sum      *Summary               // from the one full call
	sumErr   *RunError
}

// Run makes the AI overview of map m over diff d (tech spec §3.1–§3.3):
// chapters with a part row are reused, the rest packed into batches called
// in parallel, each under its own CallBudget and the whole run under
// RunCeiling; every described chapter is written as its own part row at
// once. A map that fits one batch is always the one full call
// (review.overview); otherwise the summary (review.summary) runs over
// whatever was described, never waiting for every chapter. With a summary
// the assembled overview is written to review_overviews, Incomplete naming
// the chapters it could not see. No summary (zero chapters described, the
// summary failed, a cancel) returns a *RunError; the part rows written
// stay.
func (p *Pipeline) Run(ctx context.Context, store PartStore, m reviewmap.Map, d reviewdiff.Diff, intent []IntentItem,
	notes []db.ReviewNote, opt RunOptions) (Overview, error) {
	if opt.Now == nil {
		opt.Now = time.Now
	}
	if opt.Stderr == nil {
		opt.Stderr = io.Discard
	}
	opt.Stderr = &lockedWriter{w: opt.Stderr} // batch calls write in parallel
	r := &run{p: p, store: store, opt: opt, m: m, intent: intent, notes: notes, root: ctx,
		descs: NotShown(m, d), failures: map[string]*RunError{}}
	if emit := opt.Emit; emit != nil {
		var emitMu sync.Mutex
		r.opt.Emit = func(e Event) {
			emitMu.Lock()
			defer emitMu.Unlock()
			emit(e)
		}
	} else {
		r.opt.Emit = func(Event) {}
	}
	units, single := planUnits(m, d)
	if len(units) == 0 {
		return Overview{}, &RunError{Class: ClassTooLarge, Text: tooLargeText}
	}
	todo, err := r.plan(units, single)
	if err != nil {
		return Overview{}, err
	}
	batches := firstFit(todo, m)
	full := single && len(todo) == len(units)
	if full {
		batches[0].others = leftOut(m, d, batches[0])
		batches[0].truncated = m.DiffTruncated
	}
	r.describe(batches, full)
	if ctx.Err() != nil {
		log.Printf("reviewai: overview run cancelled (%d of %d chapters described)", r.described(), len(units))
		return Overview{}, &RunError{Class: ClassCancelled, Text: CancelledText}
	}
	if r.described() == 0 {
		return Overview{}, r.firstFailure()
	}
	sum, rerr := r.summary(ctx, batches, full)
	if rerr != nil {
		r.opt.Emit(Event{Event: "summary", State: StateFailed, Error: rerr})
		return Overview{}, rerr
	}
	r.opt.Emit(Event{Event: "summary", State: StateOK, Summary: &sum})
	return r.assemble(sum), nil
}

// plan reads the part rows of the packable units, emits the cached ones
// and returns the units to describe: all of them for a map that fits one
// batch (a small change is never judged from descriptions alone), the
// requested ones for the --chapter form, none for the summary-only form
// (refused when a unit has no part row), else those without a part row.
func (r *run) plan(units []unit, single bool) ([]unit, error) {
	r.hashes = r.p.unitHashes(units, single, r.notes)
	cached, err := readCached(r.store, r.opt.ProjectID, units, r.hashes)
	if err != nil {
		return nil, err
	}
	var todo []unit
	switch {
	case r.opt.SummaryOnly:
		if len(cached) < len(units) {
			return nil, &RunError{Class: ClassMissingParts, Text: missingPartsText}
		}
	case single:
		todo = units
	case len(r.opt.Chapters) > 0:
		todo = slices.DeleteFunc(slices.Clone(units), func(u unit) bool { return !slices.Contains(r.opt.Chapters, u.ch.Key) })
	default:
		todo = slices.DeleteFunc(slices.Clone(units), func(u unit) bool { _, ok := cached[u.ch.Key]; return ok })
	}
	redo := map[string]bool{}
	for _, u := range todo {
		redo[u.ch.Key] = true
	}
	for _, ch := range r.m.Chapters {
		_, packable := r.hashes[ch.Key]
		if desc, ok := cached[ch.Key]; ok && !redo[ch.Key] {
			r.descs[ch.Key] = desc
			r.opt.Emit(ChapterEvent(StateCached, desc))
		} else if desc, ok := r.descs[ch.Key]; ok { // not shown: described without a call
			r.opt.Emit(ChapterEvent(StateOK, desc))
		} else if packable && !redo[ch.Key] { // the --chapter form left it undescribed
			r.opt.Emit(Event{Event: "chapter", Key: ch.Key, State: StateNotStarted})
		}
	}
	return todo, nil
}

// unitHashes is each unit's part hash (by chapter key) under the prompt a
// run over units uses: review.overview for a map that fits one batch, else
// review.chapters.
func (p *Pipeline) unitHashes(units []unit, single bool, notes []db.ReviewNote) map[string]string {
	prompt := prompts.ReviewChapters
	if single {
		prompt = prompts.ReviewOverview
	}
	version := p.promptVersion(prompt)
	hashes := make(map[string]string, len(units))
	for _, u := range units {
		hashes[u.ch.Key] = PartHash(u.ch, u.files, notes, prompt, version)
	}
	return hashes
}

// readCached is the readable part row of each unit, by chapter key.
func readCached(store PartStore, projectID int64, units []unit, hashes map[string]string) (map[string]ChapterDesc, error) {
	list := make([]string, 0, len(units))
	for _, u := range units {
		list = append(list, hashes[u.ch.Key])
	}
	rows, err := store.ReviewOverviewParts(projectID, list)
	if err != nil {
		log.Printf("reviewai: overview parts not read (%d chapters)", len(units))
		return nil, fmt.Errorf("reading the overview's chapter parts: %w", err)
	}
	cached := map[string]ChapterDesc{}
	for _, u := range units {
		row, ok := rows[hashes[u.ch.Key]]
		var desc ChapterDesc
		if ok && json.Unmarshal([]byte(row.JSON), &desc) == nil && desc.What != "" {
			desc.Key = u.ch.Key
			cached[u.ch.Key] = desc
		}
	}
	return cached, nil
}

// CachedChapters is the description a run over map m and diff d would
// reuse for each chapter, by key: what a run waiting for another run's
// lock shows as cached (tech spec §3.7).
func (p *Pipeline) CachedChapters(store PartStore, projectID int64, m reviewmap.Map, d reviewdiff.Diff,
	notes []db.ReviewNote) (map[string]ChapterDesc, error) {
	units, single := planUnits(m, d)
	if len(units) == 0 {
		return map[string]ChapterDesc{}, nil
	}
	return readCached(store, projectID, units, p.unitHashes(units, single, notes))
}

// planUnits is the units a run over map m and diff d describes, and
// whether they fit one batch (single: the review.overview prompt).
func planUnits(m reviewmap.Map, d reviewdiff.Diff) (units []unit, single bool) {
	units = packUnits(m, d)
	return units, len(units) > 0 && len(firstFit(units, m)) == 1
}

// describe calls the batches, Parallel at a time, each under its
// CallBudget, all under the run's ceiling less the summary's budget; a
// batch not started before that ceiling is not_started.
func (r *run) describe(batches []Batch, full bool) {
	if len(batches) == 0 {
		return
	}
	summary := r.p.summaryLimit()
	ctx, cancel := context.WithTimeout(r.root, runCeiling(batches, r.p.budgetFor, summary)-summary)
	defer cancel()
	next := make(chan int)
	var wg sync.WaitGroup
	for range Parallel(len(batches)) {
		wg.Go(func() {
			for i := range next {
				r.callBatch(ctx, i, len(batches), batches[i], full)
			}
		})
	}
	for i := range batches {
		next <- i
	}
	close(next)
	wg.Wait()
}

// callBatch makes batch i's call and records its chapters.
func (r *run) callBatch(ctx context.Context, i, n int, b Batch, full bool) {
	if ctx.Err() != nil {
		log.Printf("reviewai: overview batch %d of %d not started (%d chapters)", i+1, n, len(b.Chapters))
		for _, ch := range b.Chapters {
			r.opt.Emit(Event{Event: "chapter", Key: ch.Key, State: StateNotStarted})
		}
		return
	}
	budget := r.p.budgetFor(b.Lines)
	callCtx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	descs, sum, err := r.p.DescribeBatch(callCtx, b, full, r.intent, r.notes)
	class := ""
	if err != nil {
		class = r.classify(callCtx, err)
		fmt.Fprintf(r.opt.Stderr, "review overview: batch %d of %d: %s\n", i+1, n, logredact.Full(err))
		log.Printf("reviewai: overview batch %d of %d: %s (%d chapters, %d described)", i+1, n, class, len(b.Chapters), len(descs))
	}
	now := r.opt.Now()
	for _, ch := range b.Chapters {
		desc, ok := descs[ch.Key]
		if !ok {
			fail := failure(class, ch.Title, budget, err)
			if descs != nil { // the reply was read but left this chapter out
				fail = failure(ClassParse, ch.Title, budget, nil)
			}
			r.fail(ch.Key, fail)
			continue
		}
		r.keep(ch.Key, desc, now)
	}
	if full {
		r.mu.Lock()
		defer r.mu.Unlock()
		if sum != nil {
			r.sum = sum
		} else {
			r.sumErr = failure(class, summaryTitle, budget, err)
		}
	}
}

// keep writes desc as chapter key's part row and records it.
func (r *run) keep(key string, desc ChapterDesc, now time.Time) {
	js, err := json.Marshal(desc)
	if err == nil {
		err = r.store.PutReviewOverviewPart(db.ReviewOverviewPart{ProjectID: r.opt.ProjectID, Hash: r.hashes[key],
			JSON: string(js), Model: r.opt.Model}, now)
	}
	if err != nil { // described all the same; only the next run redoes it
		fmt.Fprintf(r.opt.Stderr, "review overview: caching a chapter failed: %v\n", err)
		log.Printf("reviewai: overview chapter part not cached")
	}
	r.mu.Lock()
	r.descs[key] = desc
	r.mu.Unlock()
	r.opt.Emit(ChapterEvent(StateOK, desc))
}

// fail records chapter key's failure.
func (r *run) fail(key string, e *RunError) {
	r.mu.Lock()
	r.failures[key] = e
	r.mu.Unlock()
	r.opt.Emit(Event{Event: "chapter", Key: key, State: StateFailed, Error: e})
}

// classify is a failed call's error class: a cancelled run, the call's own
// budget (or the run's ceiling), an unreadable reply, else the provider.
func (r *run) classify(callCtx context.Context, err error) string {
	switch {
	case r.root.Err() != nil:
		return ClassCancelled
	case callCtx.Err() != nil:
		return ClassTimeout
	case errors.Is(err, ErrParse):
		return ClassParse
	}
	return ClassProvider
}

// failure is the owner's sentence for class on title (tech spec §3.6);
// budget is the call's, cause the provider's error: Detail is its full
// text (logredact.Full), the owner's to read.
func failure(class, title string, budget time.Duration, cause error) *RunError {
	e := &RunError{Class: class, Detail: logredact.Full(cause)}
	named := "“" + title + "”"
	if title == summaryTitle {
		named = title
	}
	switch class {
	case ClassTimeout:
		e.Text = fmt.Sprintf("The overview of %s did not finish in %d min.", named, int(math.Ceil(budget.Minutes())))
	case ClassParse:
		e.Text = fmt.Sprintf("The AI answer for %s could not be read.", named)
	case ClassCancelled:
		e.Text = CancelledText
	default:
		e.Class = ClassProvider
		e.Text = fmt.Sprintf("The AI provider failed on %s.", named)
	}
	return e
}

// ChapterEvent is the chapter event of description d in state.
func ChapterEvent(state string, d ChapterDesc) Event {
	risks := d.Risks
	if risks == nil {
		risks = []Risk{}
	}
	return Event{Event: "chapter", Key: d.Key, State: state, EventChapter: &EventChapter{What: d.What, Risks: risks}}
}

// described counts the chapters with a description of the model's (cached
// or made now); "not shown" descriptions do not count.
func (r *run) described() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for k := range r.descs {
		if _, ok := r.hashes[k]; ok {
			n++
		}
	}
	return n
}

// firstFailure is the failure of the first failed chapter in reading
// order: the run's error when nothing was described.
func (r *run) firstFailure() *RunError {
	for _, ch := range r.m.Chapters {
		if e, ok := r.failures[ch.Key]; ok {
			return e
		}
	}
	return &RunError{Class: ClassMissingParts, Text: missingPartsText}
}

// summary is the run's summary part: the one full call's, else a
// review.summary call under SummaryBudget over every description made.
func (r *run) summary(ctx context.Context, batches []Batch, full bool) (Summary, *RunError) {
	if full {
		if r.sum != nil {
			return *r.sum, nil
		}
		return Summary{}, r.sumErr
	}
	budget := r.p.summaryLimit()
	sumCtx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	sum, err := r.p.Summarize(sumCtx, SummaryInput{Intent: r.intent, Map: r.m, Described: r.descs})
	if err != nil {
		class := r.classify(sumCtx, err)
		fmt.Fprintf(r.opt.Stderr, "review overview: summary: %s\n", logredact.Full(err))
		log.Printf("reviewai: overview summary: %s (%d batches)", class, len(batches))
		return Summary{}, failure(class, summaryTitle, budget, err)
	}
	return sum, nil
}

// assemble builds the overview from the summary and the map's chapters and
// writes it to review_overviews; a failed write still answers it.
func (r *run) assemble(sum Summary) Overview {
	o := Overview{Summary: sum.Summary, Coverage: sum.Coverage, OutOfScope: sum.OutOfScope,
		Risk: []Risk{}, Chapters: []Chapter{}, Incomplete: []string{}}
	for _, ch := range r.m.Chapters {
		d, ok := r.descs[ch.Key]
		if !ok && ch.Key != collapsedKey {
			o.Incomplete = append(o.Incomplete, ch.Key)
		}
		o.Chapters = append(o.Chapters, Chapter{Key: ch.Key, Title: ch.Title, Level: ch.Level.String(),
			Paths: ch.Paths, Core: ch.Core, What: d.What})
		o.Risk = append(o.Risk, d.Risks...)
	}
	js, err := json.Marshal(o)
	if err == nil {
		err = r.store.PutReviewOverview(r.opt.ProjectID, r.opt.Tree, r.opt.Base, IntentHash(r.intent, r.notes), string(js), r.opt.Model)
	}
	if err != nil { // the overview is paid for: answer it; the next open asks again
		fmt.Fprintf(r.opt.Stderr, "review overview: caching failed: %v\n", err)
		log.Printf("reviewai: assembled overview not cached (%d chapters)", len(o.Chapters))
	}
	return o
}

// lockedWriter serializes the parallel batch calls' writes.
type lockedWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}
