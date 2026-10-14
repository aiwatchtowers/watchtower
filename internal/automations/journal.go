package automations

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// Step statuses the journal writes (automation_run_steps.status).
const (
	StepOK      = "ok"
	StepError   = "error"
	StepDenied  = "denied"
	StepWaiting = "waiting"
	StepDryRun  = "dry_run"
)

// Journal records one step per SDK call (spec §5, AUTO-11). A DB journal
// writes each step's row when the call starts and closes it when the call
// ends; a memory journal (NewMemoryJournal) keeps the rows only in memory.
// Both keep a copy of every step for Steps.
//
// A DB write failure does not stop the script; the first one is kept and
// returned by Err, which the executor checks when the run ends.
type Journal struct {
	mu     sync.Mutex
	db     *db.DB // nil = memory journal
	runID  int64
	dryRun bool
	clock  Clock // nil = RealClock until UseClock/adoptClock
	steps  []db.AutomationRunStep
	kinds  map[string]int // steps begun per kind
	totals db.RunUsage
	err    error
}

// NewJournal records the steps of run runID in d.
func NewJournal(d *db.DB, runID int64, dryRun bool) *Journal {
	return &Journal{db: d, runID: runID, dryRun: dryRun}
}

// NewMemoryJournal records steps in memory only (a dry run that must write
// nothing); a step's ID is its seq.
func NewMemoryJournal() *Journal {
	return &Journal{dryRun: true}
}

// UseClock sets the clock that stamps steps (the executor passes its own);
// it returns j.
func (j *Journal) UseClock(c Clock) *Journal {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.clock = c
	return j
}

// adoptClock sets c unless UseClock already chose one.
func (j *Journal) adoptClock(c Clock) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.clock == nil {
		j.clock = c
	}
}

// nowLocked is the journal's time; the caller holds mu.
func (j *Journal) nowLocked() time.Time {
	if j.clock == nil {
		return time.Now().UTC()
	}
	return j.clock.Now().UTC()
}

// DryRun reports whether the journal belongs to a dry run.
func (j *Journal) DryRun() bool { return j.dryRun }

// Step is one journaled SDK call.
type Step struct {
	j          *Journal
	idx        int
	id         int64
	started    time.Time
	permission string
	usage      db.RunUsage
	hold       bool           // Env.Call: a close by the SDK function waits for the result's encoding
	pending    *db.StepFinish // the close held while hold is set
}

// Begin records the start of a call; args is stored as JSON clipped to
// StepClipBytes. The row's status is "ok" while finished_at is NULL: an open
// step is one without finished_at.
func (j *Journal) Begin(kind, name string, args any) *Step {
	j.mu.Lock()
	defer j.mu.Unlock()
	now := j.nowLocked()
	row := db.AutomationRunStep{
		RunID: j.runID, Seq: len(j.steps) + 1, Kind: kind, Name: name,
		ArgsJSON: clipUTF8(marshalForStep(args), StepClipBytes), Status: StepOK, StartedAt: now,
	}
	row.ID = int64(row.Seq)
	if j.db != nil {
		id, err := j.db.AppendAutomationRunStep(row)
		j.keepErr(err)
		row.ID = id
	}
	j.steps = append(j.steps, row)
	if j.kinds == nil {
		j.kinds = map[string]int{}
	}
	j.kinds[kind]++
	return &Step{j: j, idx: len(j.steps) - 1, id: row.ID, started: now}
}

// keepErr keeps the first write error; the caller holds mu.
func (j *Journal) keepErr(err error) {
	if err != nil && j.err == nil {
		j.err = err
	}
}

// Err is the first DB write error, or nil.
func (j *Journal) Err() error {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.err
}

// Count is the number of steps begun.
func (j *Journal) Count() int {
	j.mu.Lock()
	defer j.mu.Unlock()
	return len(j.steps)
}

// CountKind is the number of steps of kind begun (log() enforces its
// per-run cap with it).
func (j *Journal) CountKind(kind string) int {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.kinds[kind]
}

// Steps returns the recorded steps in seq order, as they stand now.
func (j *Journal) Steps() []db.AutomationRunStep {
	j.mu.Lock()
	defer j.mu.Unlock()
	out := make([]db.AutomationRunStep, len(j.steps))
	copy(out, j.steps)
	return out
}

// Totals is the usage every step reported.
func (j *Journal) Totals() db.RunUsage {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.totals
}

// ID is the step's row id (its seq for a memory journal; 0 when a DB journal
// could not write the row — see Journal.Err).
func (s *Step) ID() int64 { return s.id }

// Finished reports whether the step is closed (or its close is held).
func (s *Step) Finished() bool {
	s.j.mu.Lock()
	defer s.j.mu.Unlock()
	return s.pending != nil || s.j.steps[s.idx].FinishedAt != nil
}

// holdFinish makes the next close wait for releaseFinish.
func (s *Step) holdFinish() {
	s.j.mu.Lock()
	defer s.j.mu.Unlock()
	s.hold = true
}

// releaseFinish ends the hold. It reports whether a close was held; that
// close is written now — as error with override's message when override is
// set (the result failed to encode after the SDK function closed the step),
// keeping its links and tokens.
func (s *Step) releaseFinish(override error) bool {
	s.j.mu.Lock()
	s.hold = false
	f := s.pending
	s.pending = nil
	s.j.mu.Unlock()
	if f == nil {
		return false
	}
	if override != nil {
		f.Status, f.Error, f.ResultSummary = StepError, override.Error(), ""
	}
	s.Finish(*f)
	return true
}

// SetPermission records the manifest entry that admitted the call.
func (s *Step) SetPermission(entry string) { s.permission = entry }

// Mark is the one non-final update (a call that waits): it sets status and,
// from link, only the non-zero ActionID/AskID/SessionID; the step stays open.
func (s *Step) Mark(status string, link db.StepFinish) error {
	j := s.j
	j.mu.Lock()
	defer j.mu.Unlock()
	row := &j.steps[s.idx]
	if row.FinishedAt != nil {
		return fmt.Errorf("automation run step %d: %w", s.id, db.ErrStepFinished)
	}
	if j.db != nil && s.id != 0 {
		if err := j.db.MarkAutomationRunStep(s.id, status, link); err != nil {
			return fmt.Errorf("marking automation run %d step %d %s: %w", j.runID, s.id, status, err)
		}
	}
	row.Status = status
	applyStepLinks(row, link)
	return nil
}

func applyStepLinks(row *db.AutomationRunStep, link db.StepFinish) {
	if link.ActionID != 0 {
		row.ActionID = link.ActionID
	}
	if link.AskID != 0 {
		row.AskID = link.AskID
	}
	if link.SessionID != 0 {
		row.SessionID = link.SessionID
	}
}

// Usage records one model call's tokens on the step and, for a DB journal,
// adds them to the run's counters at once (they count toward the daily cap
// even if the run never finishes). reportedUSD is nil when the provider
// reported no cost.
func (s *Step) Usage(in, out int64, estimated bool, reportedUSD *float64) {
	j := s.j
	j.mu.Lock()
	defer j.mu.Unlock()
	u := db.RunUsage{InputTokens: in, OutputTokens: out, Estimated: estimated, ReportedCostUSD: reportedUSD}
	addUsage(&s.usage, u)
	addUsage(&j.totals, u)
	if j.db != nil {
		j.keepErr(j.db.AddAutomationRunUsage(j.runID, u))
	}
}

func addUsage(dst *db.RunUsage, u db.RunUsage) {
	dst.InputTokens += u.InputTokens
	dst.OutputTokens += u.OutputTokens
	dst.Estimated = dst.Estimated || u.Estimated
	if u.ReportedCostUSD != nil {
		sum := *u.ReportedCostUSD
		if dst.ReportedCostUSD != nil {
			sum += *dst.ReportedCostUSD
		}
		dst.ReportedCostUSD = &sum
	}
}

// OK closes the step as ok with result summarised (clipped JSON).
func (s *Step) OK(result any) {
	s.Finish(db.StepFinish{Status: StepOK, ResultSummary: marshalForStep(result)})
}

// Fail closes the step as error with err's message.
func (s *Step) Fail(err error) {
	msg := "unknown error"
	if err != nil {
		msg = err.Error()
	}
	s.Finish(db.StepFinish{Status: StepError, Error: msg})
}

// Denied closes the step as denied; needed is the entry the call lacked.
func (s *Step) Denied(needed string) {
	msg := "permission denied"
	if needed != "" {
		msg = "permission denied: the recipe needs " + needed
	}
	s.Finish(db.StepFinish{Status: StepDenied, Permission: needed, Error: msg})
}

// Finish closes the step with f. Now and DurationMS default to the journal's
// clock; tokens default to what Usage recorded; Permission defaults to
// SetPermission's entry. Summary and error are clipped to StepClipBytes.
func (s *Step) Finish(f db.StepFinish) {
	j := s.j
	j.mu.Lock()
	defer j.mu.Unlock()
	row := &j.steps[s.idx]
	if row.FinishedAt != nil || s.pending != nil {
		j.keepErr(fmt.Errorf("automation run step %d: %w", s.id, db.ErrStepFinished))
		return
	}
	s.fillFinish(&f)
	if s.hold {
		s.pending = &f
		return
	}
	if j.db != nil && s.id != 0 {
		j.keepErr(j.db.FinishAutomationRunStep(s.id, f))
	}
	applyFinish(row, f)
}

func (s *Step) fillFinish(f *db.StepFinish) {
	if f.Now.IsZero() {
		f.Now = s.j.nowLocked()
	}
	if f.DurationMS == 0 {
		f.DurationMS = f.Now.Sub(s.started).Milliseconds()
	}
	if f.InputTokens == 0 && f.OutputTokens == 0 {
		f.InputTokens, f.OutputTokens = s.usage.InputTokens, s.usage.OutputTokens
		f.TokensEstimated = f.TokensEstimated || s.usage.Estimated
		if f.ReportedCostUSD == nil {
			f.ReportedCostUSD = s.usage.ReportedCostUSD
		}
	}
	if f.Permission == "" {
		f.Permission = s.permission
	}
	f.ResultSummary = clipUTF8(f.ResultSummary, StepClipBytes)
	f.Error = clipUTF8(f.Error, StepClipBytes)
}

func applyFinish(row *db.AutomationRunStep, f db.StepFinish) {
	finished := f.Now
	row.Status, row.ResultSummary, row.Error, row.Auto = f.Status, f.ResultSummary, f.Error, f.Auto
	if f.Permission != "" {
		row.Permission = f.Permission
	}
	applyStepLinks(row, f)
	row.InputTokens, row.OutputTokens, row.TokensEstimated = f.InputTokens, f.OutputTokens, f.TokensEstimated
	row.ReportedCostUSD, row.DurationMS, row.FinishedAt = f.ReportedCostUSD, f.DurationMS, &finished
}

// marshalForStep renders v for args_json/result_summary: strings as is,
// json.RawMessage as is, anything else as JSON.
func marshalForStep(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case json.RawMessage:
		return string(x)
	}
	b, err := json.Marshal(v)
	if err != nil {
		return "<unserialisable: " + err.Error() + ">"
	}
	return string(b)
}

// clipUTF8 cuts s to at most n bytes on a rune boundary (tools.ClipUTF8Bytes,
// the one copy of the rule, without the truncated flag).
func clipUTF8(s string, n int) string {
	out, _ := tools.ClipUTF8Bytes(s, n)
	return out
}
