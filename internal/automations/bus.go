package automations

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"slices"
	"sync"

	"watchtower/internal/db"
)

// Bus collects one sync cycle's events for the event automations (spec §8):
// Begin loads the subscriptions, the sync phases Publish, and Flush queues at
// most one event run per automation for the cycle — it only queues, the
// executor runs them. Publish and Wants are safe for concurrent callers.
type Bus struct {
	db     *db.DB
	clock  Clock
	wake   func()
	logger *log.Logger

	mu   sync.Mutex
	subs []*subscription

	// beforeMerge runs between Flush's enqueue and its merge into the
	// coalesced run (tests).
	beforeMerge func(runID int64)
}

// subscription is one runnable event automation and this cycle's matches.
type subscription struct {
	automationID int64
	trigger      EventTrigger
	events       []json.RawMessage // the first MaxEventsPerRun matches
	count        int               // every match
}

// FlushReport counts Flush's outcomes: runs inserted, cycles merged into a
// queued run of an earlier cycle, and subscriptions whose cycle a run already
// carried (delivered before; nothing written).
type FlushReport struct {
	Queued, Merged, Coalesced int
}

// NewBus returns a bus over d; wake is called after a Flush that queued or
// merged anything (the executor's wake), logger receives per-automation
// errors (nil = log.Default()).
func NewBus(d *db.DB, clock Clock, wake func(), logger *log.Logger) *Bus {
	if logger == nil {
		logger = log.Default()
	}
	return &Bus{db: d, clock: clock, wake: wake, logger: logger}
}

// Begin loads the subscriptions of the runnable event automations and drops
// the previous cycle's matches. On an error the bus has no subscriptions.
func (b *Bus) Begin() error {
	rows, err := b.db.ListAutomations(db.AutomationFilter{TriggerKind: string(TriggerEvent), RunnableOnly: true})
	var subs []*subscription
	if err == nil {
		subs = b.subscriptionsOf(rows)
	}
	b.mu.Lock()
	b.subs = subs
	b.mu.Unlock()
	if err != nil {
		return fmt.Errorf("loading event subscriptions: %w", err)
	}
	return nil
}

// subscriptionsOf decodes each row's trigger_spec; a row that does not decode
// to an event trigger is logged and skipped.
func (b *Bus) subscriptionsOf(rows []db.Automation) []*subscription {
	subs := make([]*subscription, 0, len(rows))
	for _, a := range rows {
		var spec triggerSpec
		if err := json.Unmarshal([]byte(a.TriggerSpec), &spec); err != nil || spec.Event == nil {
			b.logger.Printf("automations: event bus: automation %d has no event trigger in its trigger_spec (%v)", a.ID, err)
			continue
		}
		subs = append(subs, &subscription{automationID: a.ID,
			trigger: EventTrigger{Type: spec.Event.Type, Where: spec.Event.Where}})
	}
	return subs
}

// Wants reports whether any subscription is of eventType, so a source can
// skip building events nobody listens to.
func (b *Bus) Wants(eventType string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return slices.ContainsFunc(b.subs, func(s *subscription) bool { return s.trigger.Type == eventType })
}

// Publish matches events against the subscriptions: each subscription of an
// event's type whose where matches counts it and keeps it while it holds
// fewer than MaxEventsPerRun. An event that does not encode is logged and
// dropped.
func (b *Bus) Publish(events ...Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, e := range events {
		raw, err := json.Marshal(e)
		if err != nil {
			b.logger.Printf("automations: event bus: %v", err)
			continue
		}
		for _, s := range b.subs {
			if s.trigger.Type != e.Type || !MatchWhere(s.trigger.Where, e) {
				continue
			}
			s.count++
			if len(s.events) < MaxEventsPerRun {
				s.events = append(s.events, raw)
			}
		}
	}
}

// pending is one subscription's matches taken out of the bus by Flush.
type pending struct {
	automationID int64
	events       []json.RawMessage
	count        int
}

// takeMatches returns the subscriptions with at least one match and clears
// every subscription's matches.
func (b *Bus) takeMatches() []pending {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []pending
	for _, s := range b.subs {
		if s.count > 0 {
			out = append(out, pending{automationID: s.automationID, events: s.events, count: s.count})
		}
		s.events, s.count = nil, 0
	}
	return out
}

// flushOutcome is what Flush did for one subscription.
type flushOutcome int

const (
	outcomeQueued flushOutcome = iota
	outcomeMerged
	outcomeCoalesced
)

// Flush queues the cycle's runs: per subscription with a match, one event run
// carrying cycleID — a new queued row, or the cycle merged into the queued run
// of an earlier cycle, or nothing when a run already carries cycleID. One
// automation's error is logged and does not stop the others; the errors are
// also returned joined. wake is called once when anything was queued or
// merged. The matches are cleared.
func (b *Bus) Flush(cycleID string) (FlushReport, error) {
	var (
		rep  FlushReport
		errs []error
	)
	for _, p := range b.takeMatches() {
		outcome, err := b.flushOne(cycleID, p)
		if err != nil {
			err = fmt.Errorf("queueing the event run of automation %d for cycle %s: %w", p.automationID, cycleID, err)
			b.logger.Printf("automations: event bus: %v", err)
			errs = append(errs, err)
			continue
		}
		switch outcome {
		case outcomeQueued:
			rep.Queued++
		case outcomeMerged:
			rep.Merged++
		case outcomeCoalesced:
			rep.Coalesced++
		}
	}
	if rep.Queued+rep.Merged > 0 && b.wake != nil {
		b.wake()
	}
	return rep, errors.Join(errs...)
}

// flushOne enqueues p's run; on coalescing it leaves a run that already
// carries cycleID alone and merges into a queued run of another cycle. A
// merge refused because that run was claimed meanwhile enqueues once more.
func (b *Bus) flushOne(cycleID string, p pending) (flushOutcome, error) {
	payload, err := json.Marshal(db.AutomationEventPayload{Cycles: []string{cycleID}, Events: p.events,
		Count: p.count, Truncated: p.count > len(p.events)})
	if err != nil {
		return 0, fmt.Errorf("encoding the events: %w", err)
	}
	req := db.EnqueueRequest{AutomationID: p.automationID, Trigger: db.TriggerEvent, EventCycle: cycleID,
		EventJSON: string(payload), Now: b.clock.Now()}
	for range 2 {
		runID, coalesced, err := b.db.EnqueueAutomationRun(req)
		if err != nil {
			return 0, err
		}
		if !coalesced {
			return outcomeQueued, nil
		}
		carries, err := b.runCarriesCycle(runID, cycleID)
		if err != nil || carries {
			return outcomeCoalesced, err
		}
		if b.beforeMerge != nil {
			b.beforeMerge(runID)
		}
		merged, err := b.db.MergeQueuedAutomationRunEvents(runID, cycleID, p.events, p.count, MaxEventsPerRun)
		if err != nil || merged {
			return outcomeMerged, err
		}
	}
	return 0, errors.New("the queued run was claimed before each merge")
}

// runCarriesCycle reports whether run runID already lists cycleID, in its
// event_cycle or its event_json cycles.
func (b *Bus) runCarriesCycle(runID int64, cycleID string) (bool, error) {
	r, err := b.db.GetAutomationRun(runID)
	if err != nil {
		return false, err
	}
	if r.EventCycle == cycleID {
		return true, nil
	}
	var p db.AutomationEventPayload
	if r.EventJSON != "" {
		if err := json.Unmarshal([]byte(r.EventJSON), &p); err != nil {
			return false, fmt.Errorf("decoding run %d event_json: %w", runID, err)
		}
	}
	return slices.Contains(p.Cycles, cycleID), nil
}
