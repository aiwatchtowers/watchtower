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
	// The replay log (Replay): replayOff once the run is not resumable (a
	// record too large, the clock reads overflowed); replayBytes is what the
	// log holds so far.
	replayOff   bool
	replayBytes int
	// waitRecorded: the open waiting step's pending replay row is written.
	waitRecorded bool
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
	// rec is the step's replay row (a live, recorded run); recDone once the
	// call's outcome is in it.
	rec     *db.AutomationRunReplay
	recDone bool
	adopted bool // a resumed run's open waiting step (adopt)
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

// appendStored adds a step a resumed run's replay answered: the stored row,
// in memory only (AUTO-11: the call already has its one step).
func (j *Journal) appendStored(row db.AutomationRunStep) {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.steps = append(j.steps, row)
	if j.kinds == nil {
		j.kinds = map[string]int{}
	}
	j.kinds[row.Kind]++
	addUsage(&j.totals, db.RunUsage{InputTokens: row.InputTokens, OutputTokens: row.OutputTokens,
		Estimated: row.TokensEstimated, ReportedCostUSD: row.ReportedCostUSD})
}

// adopt takes over a resumed run's open waiting step: the call re-enters its
// wait on this step (its links, its start), and its replay row is rec.
func (j *Journal) adopt(row db.AutomationRunStep, rec db.AutomationRunReplay) *Step {
	j.appendStored(row)
	j.mu.Lock()
	defer j.mu.Unlock()
	return &Step{j: j, idx: len(j.steps) - 1, id: row.ID, started: row.StartedAt, rec: &rec, adopted: true}
}

// Resumed returns the links of a resumed run's adopted waiting step (the
// ask, action or session its call waits on), ok false for any other step:
// the call re-enters its wait on them instead of filing a new one.
func (s *Step) Resumed() (link db.StepFinish, ok bool) {
	if !s.adopted {
		return db.StepFinish{}, false
	}
	s.j.mu.Lock()
	defer s.j.mu.Unlock()
	row := s.j.steps[s.idx]
	return db.StepFinish{ActionID: row.ActionID, AskID: row.AskID, SessionID: row.SessionID}, true
}

// record starts the step's replay row: its args hash and the clock reads
// before it. ok false (the reads overflowed) makes the run not resumable.
func (s *Step) record(hash, clock string, ok bool) {
	j := s.j
	j.mu.Lock()
	defer j.mu.Unlock()
	if !ok {
		j.stopReplayLocked()
	}
	if j.replayOff {
		return
	}
	row := j.steps[s.idx]
	s.rec = &db.AutomationRunReplay{RunID: j.runID, Seq: row.Seq, Kind: row.Kind, Name: row.Name,
		ArgsHash: hash, ClockJSON: clock}
}

// recordOutcome puts the call's outcome in the step's replay row: the
// result the script got or the error it threw. A result past
// MaxReplayResultBytes, or a log past MaxReplayLogBytes, makes the run not
// resumable.
func (s *Step) recordOutcome(v any, err error) {
	j := s.j
	j.mu.Lock()
	defer j.mu.Unlock()
	if s.rec == nil || j.replayOff {
		return
	}
	s.rec.Pending, s.rec.ResultJSON, s.rec.ErrorJSON = false, nil, ""
	size := len(s.rec.ClockJSON)
	switch {
	case err != nil:
		s.rec.ErrorJSON = errorRecord(err)
		size += len(s.rec.ErrorJSON)
	case v != nil:
		text := marshalForStep(v)
		if len(text) > MaxReplayResultBytes {
			j.stopReplayLocked()
			return
		}
		s.rec.ResultJSON = &text
		size += len(text)
	}
	if j.replayBytes+size > MaxReplayLogBytes {
		j.stopReplayLocked()
		return
	}
	j.replayBytes += size
	s.recDone = true
}

// stopReplayLocked makes the run not resumable (once); the caller holds mu.
func (j *Journal) stopReplayLocked() {
	if j.replayOff {
		return
	}
	j.replayOff = true
	if j.db != nil && !j.dryRun {
		j.keepErr(j.db.SetAutomationRunNotResumable(j.runID))
	}
}

// replayRowLocked is the step's replay row to write with its close (done)
// or its waiting mark (pending), or nil; the caller holds mu.
func (s *Step) replayRowLocked(pending bool) *db.AutomationRunReplay {
	if s.rec == nil || s.j.replayOff || (!pending && !s.recDone) {
		return nil
	}
	row := *s.rec
	if pending {
		row.Pending, row.ResultJSON, row.ErrorJSON = true, nil, ""
	}
	return &row
}

// waitingResumable reports whether the run could resume at its current
// wait: it records its log, the log is complete, and its last step is open
// and waiting with a replay row.
func (j *Journal) waitingResumable() bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.db == nil || j.dryRun || j.replayOff || len(j.steps) == 0 {
		return false
	}
	last := j.steps[len(j.steps)-1]
	return last.FinishedAt == nil && last.Status == StepWaiting && j.waitRecorded
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

// dropHold ends the hold without writing anything (the daemon is stopping
// while the call waits: its step stays open for the resume).
func (s *Step) dropHold() {
	s.j.mu.Lock()
	defer s.j.mu.Unlock()
	s.hold, s.pending = false, nil
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
		if status == StepWaiting {
			link.Replay = s.replayRowLocked(true)
		}
		if err := j.db.MarkAutomationRunStep(s.id, status, link); err != nil {
			return fmt.Errorf("marking automation run %d step %d %s: %w", j.runID, s.id, status, err)
		}
		j.waitRecorded = link.Replay != nil
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
// adds them to the run's counters at once (they count even if the run never
// finishes). reportedUSD is nil when the provider
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
		f.Replay = s.replayRowLocked(false)
		j.keepErr(j.db.FinishAutomationRunStep(s.id, f))
	}
	j.waitRecorded = false
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
// json.RawMessage and an encodedResult (Env.Call's already-serialised
// result) as is, anything else as JSON.
func marshalForStep(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case json.RawMessage:
		return string(x)
	case encodedResult:
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
