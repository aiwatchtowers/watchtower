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

func TestSlackLive_EventRunsSkippedWithinHour(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seedText(t, "live", liveRecipe(`return "ran"`), false)
	plain := f.seed(t, "plain", `return "ran"`, false)

	first := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerEvent, EventCycle: "c1", EventJSON: eventPayload(t)})
	f.step(t, 1)
	f.wantRun(t, first, db.RunSucceeded, "")

	f.clock.Advance(20 * time.Minute)
	second := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerEvent, EventCycle: "c2", EventJSON: eventPayload(t)})
	other := f.enqueue(t, plain, db.TriggerManual)
	f.step(t, 1) // the plain recipe's run starts; the Live one is limited
	r := f.wantRun(t, second, db.RunCancelled, db.ErrKindNotRunnable)
	if r.Error != automations.LiveSlackLimitedError || r.StartedAt != nil {
		t.Fatalf("limited run = %q started %v; want %q, never started", r.Error, r.StartedAt, automations.LiveSlackLimitedError)
	}
	f.wantRun(t, other, db.RunSucceeded, "")

	// A dry run is limited too (every trigger, D15).
	dry := f.enqueue(t, a, db.TriggerDryRun)
	got, err := f.e.ExecuteInline(t.Context(), dry)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != db.RunCancelled || got.Error != automations.LiveSlackLimitedError {
		t.Fatalf("dry run = %s (%s); want limited", got.Status, got.Error)
	}

	// An hour after the first run's start, the next run starts; the limited
	// runs never counted.
	f.clock.Set(exStart.Add(time.Hour))
	third := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, third, db.RunSucceeded, "")
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
