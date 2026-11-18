package watchman

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/instructions"
	"watchtower/internal/pricing"
	"watchtower/internal/prompts"
)

// Backtest bars (spec 2026-11-16-watchman-design §9).
const (
	// HiddenPerCategory is how many of a category's newest decisions are
	// hidden and re-decided; a category with fewer is not measured.
	HiddenPerCategory = 30
	// StrongMaxBad is the largest share of bad decisions of a strong
	// category; a strong category also has no bad decision taken at high
	// confidence (ask #1423).
	StrongMaxBad = 0.05
	// MinScored is the fewest scored decisions (handed ones are not scored)
	// a category with its 30 hidden needs to be measured, so handing back
	// cannot make a category strong (spec §9.1, D41).
	MinScored = 20
)

// Backtest row statuses and verdicts.
const (
	BacktestStrong      = "strong"
	BacktestWeak        = "weak"
	BacktestNotMeasured = "not_measured"
	VerdictGo           = "go"
	VerdictStop         = "stop"
)

// ErrBusy reports that another process holds the Watchman lock: a backtest
// is already running.
var ErrBusy = errors.New("watchman: a backtest is already running")

// BacktestStampPath is the file a finished backtest of a workbench stamps
// (unix seconds) in the workspace folder; the daemon's weekly launch reads it.
func BacktestStampPath(workspaceDir string, workbenchID int64) string {
	return filepath.Join(workspaceDir, "last_watchman_backtest_"+strconv.FormatInt(workbenchID, 10)+".txt")
}

// BacktestReportPath is the run report of backtest backtestID in the
// workspace folder: one JSON line per hidden item with its grades and the
// judge's reasons, no situation or answer fields; the judge's reasons are
// redacted and clipped. Local workspace data.
func BacktestReportPath(workspaceDir string, backtestID int64) string {
	return filepath.Join(workspaceDir, "watchman", "backtest-"+strconv.FormatInt(backtestID, 10)+".jsonl")
}

// BacktestResult is a run's id and its report: ReportPath is the written
// report, "" when none was asked for (no workspace folder) or it could not be
// written, and then ReportError says why.
type BacktestResult struct {
	ID                      int64
	ReportPath, ReportError string
}

// backtestClock stamps finished_at (the run is long; started_at is the
// caller's now). Tests replace it.
var backtestClock = time.Now

// Backtest re-decides each category's newest 30 owner decisions with the
// twin, hidden from it, and stores how the judge graded its decisions (spec
// §9, ask #1423): same as the owner's, acceptable, or bad. Nothing the
// twin sees postdates an item: retrieval is cut at the item's own time with
// every hidden decision excluded, and the profile and instructions are cut at
// the category's oldest hidden decision — the profile is rebuilt from the 60
// precedents before it (a stored or pinned profile may have been written
// after), and only owner_instructions rows updated before it are passed
// (the workbench's own texts carry no edit time, so they are left out).
// Only decisions whose situation does not give the answer away are hidden:
// a review round's outcome (its situation counts the round's comments), an
// undone hunk (only ever "undid hunk") and the git items (a merge is only
// ever "merged", a rewrite only ever "rewrote") are not measured in phase 1;
// they stay retrievable for the other items. Items with fixed options (asks with
// options, permissions, review lessons) are same on an exact match; every
// other item, a different fixed option included, goes to the judge with the
// situation. An ask with several questions is graded per question, each one
// scored decision. An item the twin hands to the owner (HandoffOwnerOnly)
// always goes to the judge, which rules on the handoff: justified hands the
// item (one handed item, its questions not scored), unjustified is one
// bad decision for the whole item, never bad while sure (§9.1, D40). A
// category with fewer than MinScored scored decisions is not measured. A
// reply the twin cannot get right (ErrBadReply) is bad;
// a failed call, or a judge reply that cannot be read, is tried once more
// and then fails the run. The run holds
// LockPath (ErrBusy when held), closes any running row left by a dead
// process, writes a row per finished category and progress after each item;
// an error leaves the row failed with its message and the finished rows
// kept. With a workspaceDir it writes the run report (BacktestReportPath)
// item by item; a report that cannot be written never fails the run (see
// backtestReport).
func Backtest(ctx context.Context, d *db.DB, gen digest.Generator, judge Judge, store *prompts.Store, workbenchID int64,
	workspaceDir string, now time.Time) (BacktestResult, error) {
	unlock, err := lockBacktest(d)
	if err != nil {
		return BacktestResult{}, err
	}
	defer unlock()
	// A running row while the lock is free belongs to a process that died.
	if _, err := d.FailRunningWatchmanBacktests(workbenchID, "interrupted", now); err != nil {
		return BacktestResult{}, err
	}
	id, err := d.InsertWatchmanBacktest(db.WatchmanBacktest{WorkbenchID: workbenchID, StartedAt: now, Status: "running"})
	if err != nil {
		return BacktestResult{}, err
	}
	report := openBacktestReport(workspaceDir, id)
	err = backtestRun{ctx: ctx, d: d, gen: gen, judge: judge, store: store, wb: workbenchID, id: id, report: report}.run()
	res := BacktestResult{ID: id}
	res.ReportPath, res.ReportError = report.close()
	return res, err
}

// run measures every category and finishes the run's row.
func (bt backtestRun) run() error {
	var rows []db.WatchmanBacktestRow
	var cost float64
	for k, c := range Categories {
		row, err := bt.category(c, k)
		cost += row.CostUSD
		if err == nil {
			err = bt.d.AddWatchmanBacktestRow(bt.id, row)
		}
		if err != nil {
			err = fmt.Errorf("watchman backtest, category %s: %w", c, err)
			if ferr := bt.d.FinishWatchmanBacktest(bt.id, "failed", "", err.Error(), cost, backtestClock()); ferr != nil {
				err = errors.Join(err, ferr)
			}
			return err
		}
		rows = append(rows, row)
	}
	return bt.d.FinishWatchmanBacktest(bt.id, "done", Verdict(rows), "", cost, backtestClock())
}

// lockBacktest takes LockPath next to the database file. An in-memory
// database has no file and is private to this process: nothing to lock.
func lockBacktest(d *db.DB) (func(), error) {
	var file string
	if err := d.QueryRow(`SELECT file FROM pragma_database_list WHERE name = 'main'`).Scan(&file); err != nil {
		return nil, fmt.Errorf("watchman backtest: locating the database: %w", err)
	}
	if file == "" {
		return func() {}, nil
	}
	unlock, ok, err := fsutil.TryLockFile(LockPath(filepath.Dir(file)))
	if err != nil {
		return nil, fmt.Errorf("watchman backtest: %w", err)
	}
	if !ok {
		return nil, ErrBusy
	}
	return unlock, nil
}

type backtestRun struct {
	ctx    context.Context
	d      *db.DB
	gen    digest.Generator
	judge  Judge
	store  *prompts.Store
	wb     int64
	id     int64
	report *backtestReport
}

// category measures one category; k is how many categories are done. The
// returned row carries the cost spent so far even with an error.
func (bt backtestRun) category(c string, k int) (db.WatchmanBacktestRow, error) {
	row := db.WatchmanBacktestRow{Category: c}
	if err := bt.ctx.Err(); err != nil {
		return row, err
	}
	hidden, err := bt.d.WatchmanBacktestCandidates(bt.wb, c, HiddenPerCategory)
	if err != nil {
		return row, err
	}
	if len(hidden) < HiddenPerCategory {
		// Total is what there is, so the owner sees how far from 30 it is.
		row.Total, row.Status = len(hidden), BacktestNotMeasured
		return row, nil
	}
	// Grouped by the hidden decision's own category, never the twin's label
	// of it: the model may relabel.
	cutoff := hidden[len(hidden)-1].DecidedAt // newest first: the last is the oldest
	exclude := make([]int64, len(hidden))
	for i, p := range hidden {
		exclude[i] = p.ID
	}
	profile, err := bt.profile(c, cutoff, &row)
	if err != nil {
		return row, err
	}
	g, err := bt.d.OwnerInstructionsBefore(cutoff)
	if err != nil {
		return row, err
	}
	instr := renderInstructions(instructions.Texts{Global: g})
	opts := make([][]string, len(hidden))
	asked := make([]askedQuestions, len(hidden))
	for i, p := range hidden {
		if opts[i], err = backtestOptions(bt.d, p); err != nil {
			return row, err
		}
		if asked[i], err = backtestQuestions(bt.d, p); err != nil {
			return row, err
		}
	}
	row.Baseline = baseline(hidden, opts)
	recPicks, decisions := 0, 0
	for i, p := range hidden {
		o, err := bt.item(c, p, opts[i], asked[i].questions, exclude, profile, instr, &row)
		if err != nil {
			return row, err
		}
		for _, g := range o.grades {
			if g == gradeHanded {
				row.Handed++ // one handed item, counted apart, not scored
				continue
			}
			row.Total++
			switch g {
			case GradeSame:
				row.Agree++
			case GradeAcceptable:
				row.Acceptable++
			case gradeOmitted:
				row.Bad++ // not the twin's confidence at fault: never bad while sure
			default:
				row.Bad++
				if o.high {
					row.WrongHigh++
				}
			}
		}
		bt.report.write(backtestReportLine{Category: c, Source: p.Source, SourceKey: p.SourceKey, Handoff: o.handoff,
			Grades: o.grades, HandoffVerdict: o.verdict, Why: reportReasons(o.why, len(o.grades)), Confidence: o.confidence})
		recPicks += asked[i].recommendedPicks
		decisions += max(1, len(asked[i].questions))
		if err := bt.d.SetWatchmanBacktestProgress(bt.id,
			fmt.Sprintf("%s, %d of %d · %d of %d categories done", c, i+1, len(hidden), k, len(Categories))); err != nil {
			return row, err
		}
	}
	// Over the owner's decisions, handed ones included: it describes him,
	// not the twin.
	row.RecBaseline = float64(recPicks) / float64(decisions)
	row.Status = rowStatus(row)
	return row, nil
}

// profile builds the backtest-local profile of category c from the newest 60
// precedents decided before cutoff ("" with fewer than 5, as the live
// rebuild would have none). It is never stored.
func (bt backtestRun) profile(c string, cutoff time.Time, row *db.WatchmanBacktestRow) (string, error) {
	ps, err := bt.d.WatchmanPrecedentsBefore(bt.wb, c, cutoff, profilePrecedents)
	if err != nil || len(ps) < profileMinPrecedents {
		return "", err
	}
	var text string
	err = bt.retryOnce(func() error {
		t, usage, err := ProfileText(bt.ctx, bt.gen, bt.store, c, ps)
		row.CostUSD += usageCost(usage)
		text = t
		return err
	})
	return text, err
}

// retryOnce runs call and, when it fails while the run is not cancelled,
// once more: one transient failure does not cost the whole run.
func (bt backtestRun) retryOnce(call func() error) error {
	err := call()
	if err == nil || bt.ctx.Err() != nil {
		return err
	}
	return call()
}

// gradeOmitted marks a question the judge left ungraded: counted bad, never
// bad while sure (the twin's confidence did not cause it).
const gradeOmitted = "omitted"

// gradeHanded marks an item the twin justly handed to the owner: one handed
// item, however many questions it has, none of them scored (so the handed
// count never exceeds the 30 hidden). The judge never gives it.
const gradeHanded = "handed"

// itemOutcome is one hidden item's grades (one per question, or one for a
// handoff), whether the twin was sure (confidence high; never
// for an unjustified handoff), and what the run report shows of it: the
// twin's handoff and confidence, the judge's handoff verdict and reasons.
type itemOutcome struct {
	grades, why                  []string
	high                         bool
	handoff, verdict, confidence string
}

// item re-decides one hidden precedent and grades it (questions nil: one
// decision).
func (bt backtestRun) item(c string, p db.WatchmanPrecedent, opts, questions []string, exclude []int64, profile, instr string,
	row *db.WatchmanBacktestRow) (itemOutcome, error) {
	n := max(1, len(questions))
	var dec Decision
	unusable := false
	err := bt.retryOnce(func() error {
		var err error
		dec, err = Decide(bt.ctx, bt.d, bt.gen, bt.store, Item{
			WorkbenchID: bt.wb, Category: c, Situation: p.Situation, Options: opts,
			DecidedBefore: p.DecidedAt, Exclude: exclude, Profile: profile, Instructions: instr,
		})
		row.CostUSD += usageCost(dec.Usage)
		if unusable = errors.Is(err, ErrBadReply); unusable {
			return nil // the model's answer, not a failed call: scored below, not retried
		}
		return err
	})
	switch {
	case err != nil:
		return itemOutcome{}, err
	case unusable:
		// The twin gave no usable decision: bad, with no confidence to be sure of.
		return itemOutcome{grades: slices.Repeat([]string{GradeBad}, n), why: []string{}}, nil
	}
	o := itemOutcome{handoff: dec.Handoff, confidence: dec.Confidence, high: dec.Confidence == "high", why: []string{}}
	handed := dec.Handoff == HandoffOwnerOnly
	if !handed && len(opts) > 0 && dec.Choice == p.Choice {
		o.grades = []string{GradeSame}
		return o, nil
	}
	var res JudgeResult
	err = bt.retryOnce(func() error {
		r, usage, err := bt.judge.Grade(bt.ctx, JudgeInput{Situation: p.Situation, Owner: ownerAnswer(p), Twin: twinAnswer(dec),
			Questions: questions, Handoff: handed})
		row.CostUSD += usageCost(usage)
		res = r
		return err
	})
	if err != nil {
		return itemOutcome{}, err
	}
	if handed {
		o.verdict, o.why = res.Handoff, []string{res.HandoffWhy}
		if res.Handoff == HandoffJustified {
			o.grades = []string{gradeHanded}
			return o, nil
		}
		// One wrong handoff is one bad decision however many questions the
		// item has, and not the twin's confidence at fault.
		o.grades, o.high = []string{GradeBad}, false
		return o, nil
	}
	// A grade the judge left out is bad (not bad while sure); an extra one
	// is ignored. The reasons are lined up with the grades.
	o.grades = slices.Repeat([]string{gradeOmitted}, n)
	copy(o.grades, res.Grades)
	o.why = make([]string, n)
	copy(o.why, res.Why)
	return o, nil
}

// backtestOptions returns the options the owner chose among, when the
// precedent's source had fixed ones: a permission (allow/deny), a review
// lesson (accepted/dismissed), a review ask's verdict, or an ask with one
// single-choice question with options.
// nil means a free answer (the judge scores it). The option texts go through
// the same clean as the stored choice, so an exact match is meaningful.
//
// When the owner's choice is none of the options (an ask answered with
// "Other"), it is nil too: an exact match could never agree.
func backtestOptions(d *db.DB, p db.WatchmanPrecedent) ([]string, error) {
	opts, err := fixedOptions(d, p)
	if err != nil || slices.Contains(opts, p.Choice) {
		return opts, err
	}
	return nil, nil
}

func fixedOptions(d *db.DB, p db.WatchmanPrecedent) ([]string, error) {
	switch p.Source {
	case SourcePermission:
		return []string{"allow", "deny"}, nil
	case SourceReview:
		// Round outcomes and undone hunks are never hidden (Backtest).
		if strings.HasPrefix(p.SourceKey, db.WatchmanReviewLesson+":") {
			return []string{"accepted", "dismissed"}, nil
		}
		return nil, nil
	case SourceAsk:
		return askOptions(d, p)
	}
	return nil, nil
}

func askOptions(d *db.DB, p db.WatchmanPrecedent) ([]string, error) {
	id, err := strconv.ParseInt(p.SourceKey, 10, 64)
	if err != nil {
		return nil, nil //nolint:nilerr // not an ask id: score it as a free answer
	}
	a, err := d.GetOwnerAsk(p.WorkbenchID, id)
	if errors.Is(err, db.ErrAskNotFound) {
		return nil, nil // the ask is gone: score it as a free answer
	}
	if err != nil {
		return nil, err
	}
	switch a.Kind {
	case asks.KindReview:
		return []string{asks.VerdictApproved, asks.VerdictChanges}, nil
	case asks.KindCheck:
		return nil, nil
	}
	var payload asks.Payload
	if err := json.Unmarshal([]byte(a.Payload), &payload); err != nil || len(payload.Questions) != 1 {
		return nil, nil //nolint:nilerr // the source already skipped an unreadable payload; several questions are a free answer
	}
	q := payload.Questions[0]
	if q.Multi || len(q.Options) == 0 {
		return nil, nil
	}
	out := make([]string, 0, len(q.Options))
	for _, o := range q.Options {
		out = append(out, clean(o.Label))
	}
	return out, nil
}

// askedQuestions is how a hidden item is scored as questions: questions
// lists an ask's questions when it has several (each graded on its own; nil
// is one decision), recommendedPicks counts the scored decisions where the
// owner picked an option the agent marked recommended.
type askedQuestions struct {
	questions        []string
	recommendedPicks int
}

// backtestQuestions reads the question ask behind p; any other item is one
// decision with no recommended option.
func backtestQuestions(d *db.DB, p db.WatchmanPrecedent) (askedQuestions, error) {
	if p.Source != SourceAsk {
		return askedQuestions{}, nil
	}
	id, err := strconv.ParseInt(p.SourceKey, 10, 64)
	if err != nil {
		return askedQuestions{}, nil //nolint:nilerr // not an ask id: one decision
	}
	a, err := d.GetOwnerAsk(p.WorkbenchID, id)
	if errors.Is(err, db.ErrAskNotFound) {
		return askedQuestions{}, nil // the ask is gone: one decision
	}
	if err != nil {
		return askedQuestions{}, err
	}
	if a.Kind == asks.KindReview || a.Kind == asks.KindCheck {
		return askedQuestions{}, nil
	}
	var payload asks.Payload
	if err := json.Unmarshal([]byte(a.Payload), &payload); err != nil {
		return askedQuestions{}, nil //nolint:nilerr // the source already skipped an unreadable payload
	}
	answer, err := asks.ParseAnswer([]byte(a.Answer))
	if err != nil {
		return askedQuestions{}, nil //nolint:nilerr // likewise an unreadable answer
	}
	picked := map[string][]string{}
	for _, qa := range answer.Answers {
		picked[qa.ID] = qa.Labels
	}
	var out askedQuestions
	for _, q := range payload.Questions {
		if len(payload.Questions) > 1 {
			out.questions = append(out.questions, q.Question)
		}
		if pickedRecommended(q, picked[q.ID]) {
			out.recommendedPicks++
		}
	}
	return out, nil
}

// pickedRecommended reports whether labels hold an option of q the agent
// marked recommended.
func pickedRecommended(q asks.Question, labels []string) bool {
	for _, o := range q.Options {
		if o.Recommended && slices.ContainsFunc(labels, func(l string) bool { return strings.TrimSpace(l) == strings.TrimSpace(o.Label) }) {
			return true
		}
	}
	return false
}

// ownerAnswer and twinAnswer are the two texts the judge compares.
// An empty choice leaves its line out.
func ownerAnswer(p db.WatchmanPrecedent) string {
	return joinNonEmpty("\n", wordsLine("Choice: ", p.Choice), wordsLine("Owner's words: ", p.OwnerWords))
}

func twinAnswer(dec Decision) string {
	return joinNonEmpty("\n", wordsLine("Choice: ", dec.Choice), wordsLine("Reasoning: ", dec.Rationale),
		wordsLine("Confidence: ", dec.Confidence))
}

func wordsLine(head, s string) string {
	if strings.TrimSpace(s) == "" {
		return ""
	}
	return head + s
}

// baseline is the share of the hidden items that always giving the owner's
// most common choice would get right: the items scored on fixed options
// (opts[i] non-nil) with that choice, over all hidden items. A free answer
// is scored by the judge on its substance, not its choice label (every
// review comment's choice is "comment"), so it never counts as a constant
// answer's win.
func baseline(hidden []db.WatchmanPrecedent, opts [][]string) float64 {
	if len(hidden) == 0 {
		return 0
	}
	counts := map[string]int{}
	top := 0
	for i, p := range hidden {
		if opts[i] == nil {
			continue
		}
		counts[p.Choice]++
		top = max(top, counts[p.Choice])
	}
	return float64(top) / float64(len(hidden))
}

// rowStatus applies the bar to a row of 30 hidden (ask #1423, §9.1): not
// measured with fewer than MinScored scored decisions, else strong when at
// most StrongMaxBad of its scored decisions are bad and none of them was
// taken at high confidence. Agreement and the base rates are reported, not
// gated on: a different but reasonable decision is no failure.
func rowStatus(r db.WatchmanBacktestRow) string {
	if r.Total < MinScored {
		return BacktestNotMeasured
	}
	if float64(r.Bad)/float64(r.Total) <= StrongMaxBad && r.WrongHigh == 0 {
		return BacktestStrong
	}
	return BacktestWeak
}

// Verdict is the phase-1 exit (spec §9, ask #1422): go when at least 3
// categories are strong and permission, design or scope is one of them,
// else stop.
func Verdict(rows []db.WatchmanBacktestRow) string {
	strong, key := 0, false
	for _, r := range rows {
		if r.Status != BacktestStrong {
			continue
		}
		strong++
		switch r.Category {
		case CategoryPermission, CategoryDesign, CategoryScope:
			key = true
		}
	}
	if strong >= 3 && key {
		return VerdictGo
	}
	return VerdictStop
}

// usageCost is a call's reported cost, else its estimate from the token
// counts (the Anthropic table, then the Codex one), else 0 for a model with
// no price — never guessed.
func usageCost(u *digest.Usage) float64 {
	if u == nil {
		return 0
	}
	if u.ReportedCostUSD != nil {
		return *u.ReportedCostUSD
	}
	if usd, ok := pricing.Cost(pricing.Resolve(u.Model), "", u.Input, u.Output, u.CacheRead, u.CacheWrite5m, u.CacheWrite1h); ok {
		return usd
	}
	usd, _ := pricing.CodexCost(u.Model, u.Input, u.Output, u.CacheRead, u.CacheWrite())
	return usd
}

// reportReasonMax is the most runes of one judge reason in the run report.
const reportReasonMax = 200

// reportReasons lines the judge's reasons up with n grades ("" for a grade
// with none: an exact match, an unusable reply), each redacted and clipped:
// the reasons are the model's free text and may quote the situation.
func reportReasons(why []string, n int) []string {
	out := make([]string, n)
	for i := range min(n, len(why)) {
		out[i] = Clip(Redact(why[i]), reportReasonMax)
	}
	return out
}

// backtestReportLine is one hidden item in the run report (keys read by the
// owner; no situation or answer fields).
type backtestReportLine struct {
	Category       string   `json:"category"`
	Source         string   `json:"source"`
	SourceKey      string   `json:"source_key"`
	Handoff        string   `json:"handoff"`
	Grades         []string `json:"grades"`
	HandoffVerdict string   `json:"handoff_verdict"`
	Why            []string `json:"why"`
	Confidence     string   `json:"confidence"`
}

// backtestReport writes the run report line by line. Writing it never fails
// or discards the paid run: on the first error (the folder cannot be made,
// the file cannot be created, a write fails) the report is abandoned — a
// file this run created is removed, one log line with the stage and the
// count written — and close reports why. A nil report (no workspace folder)
// writes nothing.
type backtestReport struct {
	f       *os.File
	path    string
	created bool // this run created the file: only then is it removed
	lines   int
	err     error
}

func openBacktestReport(workspaceDir string, backtestID int64) *backtestReport {
	if workspaceDir == "" {
		return nil
	}
	r := &backtestReport{path: BacktestReportPath(workspaceDir, backtestID)}
	if err := os.MkdirAll(filepath.Dir(r.path), 0o700); err != nil {
		r.abandon("making its folder", err)
		return r
	}
	// O_EXCL: a run id is fresh, so anything already at the path is not
	// this run's and is never truncated or removed.
	f, err := os.OpenFile(r.path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		r.abandon("creating it", err)
		return r
	}
	r.f, r.created = f, true
	return r
}

func (r *backtestReport) write(line backtestReportLine) {
	if r == nil || r.err != nil {
		return
	}
	b, err := json.Marshal(line)
	if err == nil {
		_, err = r.f.Write(append(b, '\n'))
	}
	if err != nil {
		r.abandon("writing a line", err)
		return
	}
	r.lines++
}

// abandon drops the report after err at stage: the file is closed and, when
// this run created it, removed. The log line carries the stage and the
// count only (no path, no error text); close hands the error to the owner.
func (r *backtestReport) abandon(stage string, err error) {
	r.err = fmt.Errorf("writing the backtest report (%s): %w", stage, err)
	if r.f != nil {
		_ = r.f.Close() // known-safe ignore: the file is removed next
		r.f = nil
	}
	if r.created {
		_ = os.Remove(r.path) // known-safe ignore: best effort; the error is reported
	}
	log.Printf("watchman backtest: run report abandoned while %s after %d lines", stage, r.lines)
}

// close finishes the report: its path, or "" and why it was abandoned.
func (r *backtestReport) close() (path, errText string) {
	if r == nil {
		return "", ""
	}
	if f := r.f; f != nil {
		r.f = nil
		if err := f.Close(); err != nil {
			r.abandon("closing it", err)
		}
	}
	if r.err != nil {
		return "", r.err.Error()
	}
	return r.path, ""
}
