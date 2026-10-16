package automations_test

import (
	"encoding/json"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
)

// TestTemplates_RunE2E runs the three personal templates for real: confirmed,
// enabled and run by the executor over the seeded fixtures, FakeGenerator
// answering llm(). The workbench templates' real runs are pinned by
// TestPRReviewRounds_E2E and TestRelease_E2E.
func TestTemplates_RunE2E(t *testing.T) {
	t.Run("new-mail-summary", func(t *testing.T) {
		f := newTplFixture(t, &automationstest.FakeGenerator{Replies: []string{"- colleague C wants a contract review by Friday"}})
		a := f.installTemplate(t, "new-mail-summary", nil)

		first := f.mailEvent(t, a, "c1")
		f.step(t, 1)
		f.wantRun(t, first, db.RunSucceeded, "")
		outs := f.outputs(t)
		if len(outs) != 1 || outs[0].Kind != "inbox" || outs[0].Title != "New mail in work: 3 messages" ||
			outs[0].Body != "- colleague C wants a contract review by Friday" {
			t.Fatalf("outputs = %+v; want one inbox summary of the 3 messages", outs)
		}
		newest := f.newestMail(t)
		if got := f.mailCursor(t, a); got != newest {
			t.Fatalf("work cursor = %q; want the newest message's date %q", got, newest)
		}
		state := f.stateDump(t)

		second := f.mailEvent(t, a, "c2")
		f.step(t, 1)
		f.wantRun(t, second, db.RunSucceeded, "")
		if n := len(f.outputs(t)); n != 1 {
			t.Fatalf("outputs after a run without newer mail = %d; want still 1", n)
		}
		if got := f.stateDump(t); got != state {
			t.Fatalf("state after a run without newer mail = %q; want unchanged %q", got, state)
		}
		reads := f.toolSteps(t, second, "list_emails")
		if len(reads) != 1 || !strings.Contains(reads[0].ArgsJSON, `"since":"`+newest+`"`) {
			t.Fatalf("second list_emails steps = %+v; want one with since = the cursor %s", reads, newest)
		}
	})

	// A burst over list_emails' page: the newest 200 are summed up, the
	// summary says older new messages were left out, and the cursor is the
	// newest message.
	t.Run("new-mail-summary burst", func(t *testing.T) {
		gen := &automationstest.FakeGenerator{Replies: []string{"- a burst"}}
		f := newTplFixture(t, gen)
		if _, err := f.d.Exec(`WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 205)
			INSERT INTO gmail_messages (account_id, id, from_email, subject, internal_date)
			SELECT 1, 'burst-' || i, 'bot@example.com', 'Alert ' || i, strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || (i + 10) || ' minutes')
			FROM n`); err != nil {
			t.Fatal(err)
		}
		a := f.installTemplate(t, "new-mail-summary", nil)
		id := f.mailEvent(t, a, "c1")
		f.step(t, 1)
		f.wantRun(t, id, db.RunSucceeded, "")

		reads := f.toolSteps(t, id, "list_emails")
		if len(reads) != 1 || !strings.Contains(reads[0].ArgsJSON, `"limit":200`) {
			t.Fatalf("list_emails steps = %+v; want one asking for list_emails' largest page (200)", reads)
		}
		outs := f.outputs(t)
		if len(outs) != 1 || outs[0].Title != "New mail in work: 200+ messages" {
			t.Fatalf("outputs = %+v; want one summary titled 200+ messages", outs)
		}
		mustContain(t, "summary body", outs[0].Body, "Only the newest 200 new messages are summed up; older new messages were left out.")
		var input []map[string]any
		if err := json.Unmarshal([]byte(llmInputOf(t, gen.Snapshot()[0].UserMessage)), &input); err != nil || len(input) != 200 {
			t.Fatalf("llm() input = %d messages (%v); want 200", len(input), err)
		}
		if got, newest := f.mailCursor(t, a), f.newestMail(t); got != newest {
			t.Fatalf("work cursor = %q; want the newest message's date %q", got, newest)
		}
	})

	t.Run("jira-state-report", func(t *testing.T) {
		gen := &automationstest.FakeGenerator{Replies: []string{"## Summary\nPAY-5 is blocked.", "- PAY-5 blocked"}}
		f := newTplFixture(t, gen)
		a := f.installTemplate(t, "jira-state-report", map[string]string{"PROJECT": "PAY"})
		id := f.enqueue(t, a, db.TriggerSchedule)
		f.step(t, 1)
		f.wantRun(t, id, db.RunSucceeded, "")

		outs := f.outputs(t)
		if len(outs) != 2 || outs[0].Kind != "report" || outs[0].Title != "Jira PAY state" || outs[0].Body != "## Summary\nPAY-5 is blocked." ||
			outs[1].Kind != "briefing" || outs[1].Title != "Jira PAY this week" || outs[1].Body != "- PAY-5 blocked" {
			t.Fatalf("outputs = %+v; want the PAY report and its briefing", outs)
		}
		calls := gen.Snapshot()
		if len(calls) != 2 || calls[0].Source != automations.SourceLLMStrong {
			t.Fatalf("llm() calls = %+v; want two, the report on the strong tier", calls)
		}
		mustContain(t, "report input", calls[0].UserMessage, "PAY-5")
		mustContain(t, "briefing input", calls[1].UserMessage, "PAY-5 is blocked.")
	})

	t.Run("team-performance-report", func(t *testing.T) {
		gen := &automationstest.FakeGenerator{Replies: []string{"## Summary\nA steady week."}}
		f := newTplFixture(t, gen)
		a := f.installTemplate(t, "team-performance-report", nil)
		id := f.enqueue(t, a, db.TriggerSchedule)
		f.step(t, 1)
		f.wantRun(t, id, db.RunSucceeded, "")

		outs := f.outputs(t)
		if len(outs) != 1 || outs[0].Kind != "report" || outs[0].Title != "Team week" || outs[0].Body != "## Summary\nA steady week." {
			t.Fatalf("outputs = %+v; want one Team week report", outs)
		}
		calls := gen.Snapshot()
		if len(calls) != 1 || calls[0].Source != automations.SourceLLMStrong {
			t.Fatalf("llm() calls = %+v; want one on the strong tier", calls)
		}
		for _, want := range []string{"PAY-3", "Owns payouts", "Rolling 1.4 to production tomorrow"} {
			mustContain(t, "report input", calls[0].UserMessage, want)
		}
	})
}

// mailEvent queues an event run of a for one gmail.new_messages{account:
// work} event of cycle.
func (f *exFixture) mailEvent(t *testing.T, a db.Automation, cycle string) int64 {
	t.Helper()
	return f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerEvent, EventCycle: cycle,
		EventJSON: workEvent(t, cycle)})
}

// outputs is every committed output, oldest first.
func (f *exFixture) outputs(t *testing.T) []db.AutomationOutput {
	t.Helper()
	outs, err := f.d.ListAutomationOutputs("", 0)
	if err != nil {
		t.Fatal(err)
	}
	for i, j := 0, len(outs)-1; i < j; i, j = i+1, j-1 {
		outs[i], outs[j] = outs[j], outs[i]
	}
	return outs
}

func (f *exFixture) newestMail(t *testing.T) string {
	t.Helper()
	var newest string
	if err := f.d.QueryRow(`SELECT MAX(internal_date) FROM gmail_messages WHERE account_id = 1`).Scan(&newest); err != nil {
		t.Fatal(err)
	}
	return newest
}

// mailCursor is new-mail-summary's committed since cursor of "work".
func (f *exFixture) mailCursor(t *testing.T, a db.Automation) string {
	t.Helper()
	raw, err := f.d.GetAutomationState(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	var state struct {
		Since map[string]string `json:"since"`
	}
	if err := json.Unmarshal(raw, &state); err != nil {
		t.Fatalf("state %s: %v", raw, err)
	}
	return state.Since["work"]
}

func (f *exFixture) toolSteps(t *testing.T, runID int64, name string) []db.AutomationRunStep {
	t.Helper()
	var out []db.AutomationRunStep
	for _, s := range f.steps(t, runID) {
		if s.Kind == automations.StepKindTool && s.Name == name {
			out = append(out, s)
		}
	}
	return out
}

// llmInputOf is the JSON input llm() appended to its user message.
func llmInputOf(t *testing.T, user string) string {
	t.Helper()
	_, input, ok := strings.Cut(user, "\n\nInput (JSON):\n")
	if !ok {
		t.Fatalf("llm() user message carries no input:\n%s", user)
	}
	return input
}
