package automations

import (
	"sync"
	"time"
)

// Meter tracks one run's token budget, the daily remainder and the deadline of
// active time (spec §7.5, §7.6). Time paused on the owner or the app
// (PauseActive … ResumeActive) does not count toward budget.minutes. It is
// safe for concurrent use: the script goroutine debits and pauses, the
// sandbox's deadline watcher reads Deadline.
type Meter struct {
	mu             sync.Mutex
	clock          Clock
	budget         Budget
	start          time.Time
	pausedTotal    time.Duration
	pausedAt       time.Time // zero = not paused
	runRemaining   int64
	dailyRemaining int64
	crossed        InterruptReason
	rearm          chan struct{}
}

// NewMeter starts the meter now. dailyRemaining is the day's cap minus the
// tokens already spent today; pass math.MaxInt64 for no daily cap.
func NewMeter(budget Budget, dailyRemaining int64, clock Clock) *Meter {
	if clock == nil {
		clock = RealClock{}
	}
	return &Meter{
		clock:          clock,
		budget:         budget,
		start:          clock.Now(),
		runRemaining:   int64(budget.Tokens),
		dailyRemaining: dailyRemaining,
		rearm:          make(chan struct{}, 1),
	}
}

// BeforeCall is checked before every model call: a spent run budget is a
// BudgetExceeded SDK error, a spent daily cap a *RunInterrupted
// (InterruptDailyCap). Either also flags the run for interruption (Crossed),
// so a script that catches the error still stops.
func (m *Meter) BeforeCall() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.runRemaining <= 0 {
		m.flag(InterruptBudget)
		return &SDKError{Name: ErrNameBudget, Message: "the run's token budget is spent"}
	}
	if m.dailyRemaining <= 0 {
		m.flag(InterruptDailyCap)
		return &RunInterrupted{Reason: InterruptDailyCap}
	}
	return nil
}

// Debit charges one model call's tokens. It returns the interrupt the call
// crossed into (InterruptBudget before InterruptDailyCap), or "".
func (m *Meter) Debit(in, out int64) (crossed InterruptReason) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := in + out
	m.runRemaining -= n
	m.dailyRemaining -= n
	switch {
	case m.runRemaining <= 0:
		crossed = InterruptBudget
	case m.dailyRemaining <= 0:
		crossed = InterruptDailyCap
	}
	if crossed != "" {
		m.flag(crossed)
	}
	return crossed
}

// flag records the first interrupt reason; the caller holds mu.
func (m *Meter) flag(r InterruptReason) {
	if m.crossed == "" {
		m.crossed = r
	}
}

// Crossed is the interrupt a debit or a refused call flagged, or "". The
// sandbox checks it after every SDK call.
func (m *Meter) Crossed() InterruptReason {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.crossed
}

// PauseActive stops the active-time clock (a wait on the owner or the app).
// A second call while paused is a no-op.
func (m *Meter) PauseActive() {
	m.mu.Lock()
	if m.pausedAt.IsZero() {
		m.pausedAt = m.clock.Now()
	}
	m.mu.Unlock()
	m.signalRearm()
}

// ResumeActive restarts the active-time clock; the deadline moves by the
// pause. A call while not paused is a no-op.
func (m *Meter) ResumeActive() {
	m.mu.Lock()
	if !m.pausedAt.IsZero() {
		if d := m.clock.Now().Sub(m.pausedAt); d > 0 {
			m.pausedTotal += d
		}
		m.pausedAt = time.Time{}
	}
	m.mu.Unlock()
	m.signalRearm()
}

func (m *Meter) signalRearm() {
	select {
	case m.rearm <- struct{}{}:
	default:
	}
}

// Paused reports whether active time is stopped.
func (m *Meter) Paused() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return !m.pausedAt.IsZero()
}

// Deadline is start + budget.minutes + every pause so far (a pause still in
// progress counts up to now).
func (m *Meter) Deadline() time.Time {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.deadlineLocked()
}

func (m *Meter) deadlineLocked() time.Time {
	paused := m.pausedTotal
	if !m.pausedAt.IsZero() {
		if d := m.clock.Now().Sub(m.pausedAt); d > 0 {
			paused += d
		}
	}
	return m.start.Add(time.Duration(m.budget.Minutes)*time.Minute + paused)
}

// ActiveMS is the active time spent so far, in milliseconds.
func (m *Meter) ActiveMS() int64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	budget := time.Duration(m.budget.Minutes) * time.Minute
	left := m.deadlineLocked().Sub(m.clock.Now())
	return (budget - left).Milliseconds()
}

// Remaining is what is left of the run's budget: tokens and whole minutes of
// active time, never negative (P6's agent() carves its budget from it).
func (m *Meter) Remaining() Budget {
	m.mu.Lock()
	defer m.mu.Unlock()
	tokens := max(m.runRemaining, 0)
	left := max(m.deadlineLocked().Sub(m.clock.Now()), 0)
	return Budget{Tokens: int(tokens), Minutes: int(left / time.Minute)}
}
