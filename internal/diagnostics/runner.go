package diagnostics

import (
	"context"
	"slices"
	"sync"
	"time"
)

// Budgets are the command's time limits (spec "Time budget"): one database
// deadline started before the open, the stop-waiting fallback for a
// database call that ignores its context, the crash scan's budget for all
// three logs, the hard stop for the whole report, and the per-statement
// busy timeout.
type Budgets struct {
	DB, DBFallback, LogScan, HardStop, Busy time.Duration
}

// DefaultBudgets are 4 s + 4.5 s fallback, 2 s log scan, 8 s hard stop,
// 500 ms busy timeout — the report ends inside the Desktop's 10 s.
var DefaultBudgets = Budgets{
	DB:         4 * time.Second,
	DBFallback: 4500 * time.Millisecond,
	LogScan:    2 * time.Second,
	HardStop:   8 * time.Second,
	Busy:       500 * time.Millisecond,
}

// Part computes one part of a line. reason is "" or one of the Reason*
// constants; text "" leaves the part out.
type Part func(ctx context.Context) (text string, reason string)

// Slot places a part on an output line. Slots sharing a Line are joined
// with " · " by ascending Pos, ties in the order they are given (stage
// order, then slot order); lines print by ascending Line, whatever order
// the stages ran in. Label (e.g. "Daemon: ") is printed before the part's
// text, including a replacement `unknown (internal error)` / `unknown
// (timed out)`; StopLabel, when set, replaces Label before such a
// replacement only (a block whose own text carries its title).
type Slot struct {
	Line      int
	Pos       int
	Label     string
	StopLabel string
	Part      Part
}

// Stage is a group of slots run one after another. A Deadline > 0 gives
// the stage's parts a context with that timeout.
type Stage struct {
	Name     string
	Deadline time.Duration
	Parts    []Slot
}

// SafeLine runs p and turns a panic into `unknown (internal error)` for
// that part only.
func SafeLine(p Part) Part {
	return func(ctx context.Context) (string, string) {
		text, reason, _ := runPart(ctx, p)
		return text, reason
	}
}

type slotResult struct {
	text, reason string
	done         bool
	replaced     bool // the runner's text, not the part's (a panic)
}

// Run builds the report lines in a worker goroutine, running the stages in
// order. It stops waiting at b.HardStop: every slot not finished by then
// prints `unknown (timed out)` and the report gains the `timed out at 8 s`
// reason; a part still running is abandoned and dies with the process, and
// whatever it returns later never reaches the returned Report. A cancelled
// parent ctx is treated as the hard stop: the same `unknown (timed out)`
// slots and the same reason. Reasons are collected once each, in the fixed
// order. Run fills Lines and Reasons only.
func Run(ctx context.Context, b Budgets, stages []Stage) Report {
	var slots []Slot
	for _, st := range stages {
		slots = append(slots, st.Parts...)
	}
	results := make([]slotResult, len(slots))
	var mu sync.Mutex
	stopped := false

	workCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		i := 0
		for _, st := range stages {
			runStage(workCtx, st, func(text, reason string, replaced bool) bool {
				mu.Lock()
				defer mu.Unlock()
				if stopped {
					return false
				}
				results[i] = slotResult{text: text, reason: reason, done: true, replaced: replaced}
				i++
				return true
			})
			if workCtx.Err() != nil {
				return
			}
		}
	}()

	timer := time.NewTimer(b.HardStop)
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
	case <-ctx.Done():
	}
	mu.Lock()
	stopped = true
	final := slices.Clone(results)
	mu.Unlock()

	return assemble(slots, final)
}

// runStage runs the stage's parts in order and hands each result to
// deliver; it stops when deliver refuses (the hard stop has passed).
func runStage(ctx context.Context, st Stage, deliver func(text, reason string, replaced bool) bool) {
	sctx := ctx
	if st.Deadline > 0 {
		var cancel context.CancelFunc
		sctx, cancel = context.WithTimeout(ctx, st.Deadline)
		defer cancel()
	}
	for _, sl := range st.Parts {
		text, reason, panicked := runPart(sctx, sl.Part)
		if !deliver(text, reason, panicked) {
			return
		}
	}
}

// runPart is SafeLine that also says whether the part panicked.
func runPart(ctx context.Context, p Part) (text, reason string, panicked bool) {
	defer func() {
		if recover() != nil {
			text, reason, panicked = UnknownInternal, "", true
		}
	}()
	text, reason = p(ctx)
	return text, reason, false
}

type placedPart struct {
	pos  int
	text string
}

func assemble(slots []Slot, results []slotResult) Report {
	placed := map[int][]placedPart{}
	var reasons []string
	for i, sl := range slots {
		res := results[i]
		if !res.done {
			res = slotResult{text: UnknownTimedOut, reason: ReasonTimedOut, replaced: true}
		}
		if res.reason != "" {
			reasons = append(reasons, res.reason)
		}
		label := sl.Label
		if res.replaced && sl.StopLabel != "" {
			label = sl.StopLabel
		}
		if res.text != "" {
			placed[sl.Line] = append(placed[sl.Line], placedPart{pos: sl.Pos, text: label + res.text})
		}
	}
	parts := map[int][]string{}
	for line, ps := range placed {
		slices.SortStableFunc(ps, func(a, b placedPart) int { return a.pos - b.pos })
		for _, p := range ps {
			parts[line] = append(parts[line], p.text)
		}
	}
	positions := make([]int, 0, len(parts))
	for line := range parts {
		positions = append(positions, line)
	}
	slices.Sort(positions)
	lines := make([]string, 0, len(positions))
	for _, line := range positions {
		lines = append(lines, JoinParts(parts[line]...))
	}
	return Report{Lines: lines, Reasons: orderedReasons(reasons)}
}
