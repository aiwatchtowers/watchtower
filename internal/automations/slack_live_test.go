package automations_test

import (
	"encoding/json"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
)

// liveRecipe is a manual slack:live recipe whose script is SCRIPT.
func liveRecipe(script string) string {
	return "---\nname: Live test\ntrigger:\n  manual: true\npermissions:\n  - slack:live\n  - agent:run\n  - llm:light\n" +
		"outputs: [inbox]\n---\nA Live Slack recipe.\n\n```js\n" + script + "\n```\n"
}

// liveRunAt enqueues a run of a with trigger (scheduled for sched when not
// zero) and runs one poll at claim; it returns the stored run.
func liveRunAt(t *testing.T, f *exFixture, a db.Automation, trigger string, sched, claim time.Time, cycle string) *db.AutomationRun {
	t.Helper()
	f.clock.Set(claim)
	req := db.EnqueueRequest{AutomationID: a.ID, Trigger: trigger}
	if !sched.IsZero() {
		req.ScheduledFor = &sched
	}
	if trigger == db.TriggerEvent {
		req.EventCycle, req.EventJSON = cycle, eventPayload(t)
	}
	id := f.enqueueReq(t, req)
	if _, err := f.e.Step(t.Context()); err != nil {
		t.Fatal(err)
	}
	f.e.Wait()
	return f.run(t, id)
}

func wantLimited(t *testing.T, r *db.AutomationRun, limited bool) {
	t.Helper()
	got := r.Status == db.RunCancelled && r.ErrorKind == db.ErrKindNotRunnable && r.Error == automations.LiveSlackLimitedError
	if got != limited || (limited && r.StartedAt != nil) || (!limited && r.Status != db.RunSucceeded) {
		t.Fatalf("run %d (%s at %v) = %s/%s %q started %v; want limited=%v", r.ID, r.Trigger, r.ScheduledFor,
			r.Status, r.ErrorKind, r.Error, r.StartedAt, limited)
	}
}

func TestSlackLive_EventRunsSkippedWithinHour(t *testing.T) {
	at := func(h, m, s int) time.Time { return time.Date(2026, 10, 14, h, m, s, 0, time.UTC) }
	var zero time.Time

	t.Run("scheduled runs compare scheduled_for, not claim jitter", func(t *testing.T) {
		f := newExFixture(t, exOpts{})
		a := f.seedText(t, "live", liveRecipe(`return "ran"`), false)
		wantLimited(t, liveRunAt(t, f, a, db.TriggerSchedule, at(10, 0, 0), at(10, 0, 8), ""), false)
		wantLimited(t, liveRunAt(t, f, a, db.TriggerSchedule, at(11, 0, 0), at(11, 0, 2), ""), false)
	})
	t.Run("a late catch-up and the next scheduled run both run", func(t *testing.T) {
		f := newExFixture(t, exOpts{})
		a := f.seedText(t, "live", liveRecipe(`return "ran"`), false)
		wantLimited(t, liveRunAt(t, f, a, db.TriggerCatchUp, at(10, 0, 0), at(10, 40, 0), ""), false)
		wantLimited(t, liveRunAt(t, f, a, db.TriggerSchedule, at(11, 0, 0), at(11, 0, 1), ""), false)
	})
	t.Run("event runs compare start times with a 2-minute tolerance", func(t *testing.T) {
		f := newExFixture(t, exOpts{})
		a := f.seedText(t, "live", liveRecipe(`return "ran"`), false)
		plain := f.seed(t, "plain", `return "ran"`, false)
		wantLimited(t, liveRunAt(t, f, a, db.TriggerEvent, zero, at(10, 0, 0), "c1"), false)
		wantLimited(t, liveRunAt(t, f, a, db.TriggerEvent, zero, at(10, 20, 0), "c2"), true)
		wantLimited(t, liveRunAt(t, f, a, db.TriggerEvent, zero, at(10, 57, 59), "c3"), true)
		// A recipe without slack:live is never limited.
		wantLimited(t, liveRunAt(t, f, plain, db.TriggerManual, zero, at(10, 57, 59), ""), false)
		// A dry run is limited too (every trigger, D15).
		f.clock.Set(at(10, 57, 30))
		dry := f.enqueue(t, a, db.TriggerDryRun)
		got, err := f.e.ExecuteInline(t.Context(), dry)
		if err != nil {
			t.Fatal(err)
		}
		wantLimited(t, got, true)
		// 58 min after the last start is far enough; the limited runs never counted.
		wantLimited(t, liveRunAt(t, f, a, db.TriggerEvent, zero, at(10, 58, 30), "c4"), false)
	})
	t.Run("a scheduled run after an event run compares start times", func(t *testing.T) {
		f := newExFixture(t, exOpts{})
		a := f.seedText(t, "live", liveRecipe(`return "ran"`), false)
		wantLimited(t, liveRunAt(t, f, a, db.TriggerEvent, zero, at(10, 30, 0), "c1"), false)
		wantLimited(t, liveRunAt(t, f, a, db.TriggerSchedule, at(11, 0, 0), at(11, 0, 0), ""), true)
	})
}

func TestAgentRun_MarksRunLiveSlack(t *testing.T) {
	agent := &automationstest.FakeAgent{Result: automations.AgentResult{Text: "read it", UsedSlackLive: true}}
	f := newExFixture(t, exOpts{backends: func(_ *exFixture, b *automations.Backends) { b.Agent = agent }})
	a := f.seedText(t, "live", liveRecipe(`const r = agent("read the channel"); output.inbox({title: "t", body: r.text}); return "ok"`), false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	if reqs := agent.Requests(); len(reqs) != 1 || !reqs[0].SlackLive {
		t.Fatalf("agent requests = %+v; want one with SlackLive", reqs)
	}
	var live int
	if err := f.d.QueryRow(`SELECT live_slack FROM automation_runs WHERE id = ?`, id).Scan(&live); err != nil || live != 1 {
		t.Fatalf("live_slack = %d (%v); want 1", live, err)
	}
	// Idempotent.
	if err := f.d.MarkAutomationRunLiveSlack(id); err != nil {
		t.Fatal(err)
	}

	// A run whose agent did not touch Slack stays unmarked.
	agent.Result.UsedSlackLive = false
	f.clock.Advance(2 * time.Hour)
	id2 := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	if err := f.d.QueryRow(`SELECT live_slack FROM automation_runs WHERE id = ?`, id2).Scan(&live); err != nil || live != 0 {
		t.Fatalf("live_slack = %d (%v); want 0", live, err)
	}
}

func TestAgentRun_ConnectorWriteDeniedLogged(t *testing.T) {
	agent := &automationstest.FakeAgent{Result: automations.AgentResult{Text: "could not post",
		UsedSlackLive: true, SlackLiveDenied: []string{"slack_send_message"}}}
	f := newExFixture(t, exOpts{backends: func(_ *exFixture, b *automations.Backends) { b.Agent = agent }})
	a := f.seedText(t, "live", liveRecipe(`return agent("post the summary").text`), false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	steps := f.steps(t, id)
	if len(steps) != 1 || steps[0].Kind != "agent" {
		t.Fatalf("steps = %+v; want the one agent() step", steps)
	}
	var summary struct {
		Denied []struct {
			Tool  string `json:"tool"`
			OK    bool   `json:"ok"`
			Error string `json:"error"`
		} `json:"slack_live_denied"`
	}
	if err := json.Unmarshal([]byte(steps[0].ResultSummary), &summary); err != nil {
		t.Fatal(err)
	}
	if len(summary.Denied) != 1 || summary.Denied[0].Tool != "slack_send_message" || summary.Denied[0].OK ||
		summary.Denied[0].Error != automations.LiveSlackReadOnlyStep {
		t.Fatalf("step summary = %s; want the denied write logged", steps[0].ResultSummary)
	}
}
