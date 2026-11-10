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
// with " · " in the order they are given (stage order, then slot order);
// lines print by ascending Line, whatever order the stages ran in. Label
// (e.g. "Daemon: ") is printed before the part's text, including a
// replacement `unknown (internal error)` / `unknown (timed out)`.
type Slot struct {
	Line  int
	Label string
	Part  Part
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
	return func(ctx context.Context) (text, reason string) {
		defer func() {
			if recover() != nil {
				text, reason = UnknownInternal, ""
			}
		}()
		return p(ctx)
	}
}

type slotResult struct {
	text, reason string
	done         bool
}

// Run builds the report lines in a worker goroutine, running the stages in
// order. It stops waiting at b.HardStop (or when ctx ends): every slot not
// finished by then prints `unknown (timed out)` and the report gains the
// `timed out at 8 s` reason; a part still running is abandoned and dies
// with the process. Reasons are collected once each, in the fixed order.
// Run fills Lines and Reasons only.
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
			runStage(workCtx, st, func(text, reason string) bool {
				mu.Lock()
				defer mu.Unlock()
				if stopped {
					return false
				}
				results[i] = slotResult{text: text, reason: reason, done: true}
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
func runStage(ctx context.Context, st Stage, deliver func(text, reason string) bool) {
	sctx := ctx
	if st.Deadline > 0 {
		var cancel context.CancelFunc
		sctx, cancel = context.WithTimeout(ctx, st.Deadline)
		defer cancel()
	}
	for _, sl := range st.Parts {
		text, reason := SafeLine(sl.Part)(sctx)
		if !deliver(text, reason) {
			return
		}
	}
}

func assemble(slots []Slot, results []slotResult) Report {
	parts := map[int][]string{}
	var reasons []string
	for i, sl := range slots {
		res := results[i]
		if !res.done {
			res = slotResult{text: UnknownTimedOut, reason: ReasonTimedOut}
		}
		if res.reason != "" {
			reasons = append(reasons, res.reason)
		}
		if res.text != "" {
			parts[sl.Line] = append(parts[sl.Line], sl.Label+res.text)
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
