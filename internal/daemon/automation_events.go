package daemon

import (
	"context"
	"time"

	"watchtower/internal/automations"
)

// AutomationEvents is the event bus of the event automations (spec
// 2026-10-14 §8; *automations.Bus): runSync begins it once per cycle, the
// observed sync phases publish content-free events into it, and one Flush
// per cycle queues at most one event run per automation.
type AutomationEvents interface {
	Begin() error
	Wants(eventType string) bool
	Publish(events ...automations.Event)
	Flush(cycleID string) (automations.FlushReport, error)
}

// SetAutomationEvents attaches the event bus; nil = no event automations
// (not wired: the upgrade step failed closed, or a test).
func (d *Daemon) SetAutomationEvents(ev AutomationEvents) {
	d.automationEvents = ev
}

// HasAutomationEvents reports whether an event bus is wired —
// cmd/automations_daemon.go's wireAutomations attaches one whenever it wires
// automations.
func (d *Daemon) HasAutomationEvents() bool {
	return d.automationEvents != nil
}

// beginAutomationEvents starts the cycle's events: the bus, or nil when none
// is wired, there is no database, or Begin failed (logged; no events this
// cycle).
func (d *Daemon) beginAutomationEvents() AutomationEvents {
	if d.automationEvents == nil || d.db == nil {
		return nil
	}
	if err := d.automationEvents.Begin(); err != nil {
		d.logger.Printf("automations: event bus: %v; no events this cycle", err)
		return nil
	}
	return d.automationEvents
}

// observePhase runs phase between src's Before snapshot and its After diff
// and publishes the diff's events — only when this cycle's bus wants
// src.Type(), otherwise it just runs phase. A snapshot or diff error is
// logged and never skips the phase. The snapshot reads ignore ctx's
// cancellation, so a shutdown mid-phase still publishes what the phase
// wrote (the cycle's Flush runs on a cancelled ctx too).
func (d *Daemon) observePhase(ctx context.Context, src automations.EventSource, phase func()) {
	ev := d.cycleEvents
	if ev == nil || !ev.Wants(src.Type()) {
		phase()
		return
	}
	readCtx := context.WithoutCancel(ctx)
	diff, err := src.Before(readCtx)
	if err != nil {
		d.logger.Printf("automations: %s events: %v", src.Type(), err)
		phase()
		return
	}
	phase()
	events, err := diff.After(readCtx)
	if err != nil {
		d.logger.Printf("automations: %s events: %v", src.Type(), err)
		return
	}
	ev.Publish(events...)
}

// flushAutomationEvents queues the cycle's event runs, cycle id = syncStart
// in RFC 3339 UTC with nanoseconds (two cycles in one second never share an
// id), and ends the cycle's events. The bus logs each
// automation's error itself; this logs one summary line.
func (d *Daemon) flushAutomationEvents(syncStart time.Time) {
	ev := d.cycleEvents
	d.cycleEvents = nil
	if ev == nil {
		return
	}
	cycleID := syncStart.UTC().Format(time.RFC3339Nano)
	rep, err := ev.Flush(cycleID)
	if err == nil && rep.Queued+rep.Merged+rep.Coalesced == 0 {
		return
	}
	failed := ""
	if err != nil {
		failed = "; some automations failed (logged above)"
	}
	d.logger.Printf("automations: event cycle %s: %d queued, %d merged, %d already queued%s",
		cycleID, rep.Queued, rep.Merged, rep.Coalesced, failed)
}
