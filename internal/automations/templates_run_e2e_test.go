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
	t.Run("new-mail-summary", testRunNewMailSummary)

	// A burst over list_emails' page: every page is drained, all new mail is
	// summed up once, and the cursor is the newest message.
	t.Run("new-mail-summary burst", testRunNewMailBurst)

	// Mail that arrives late at the cursor's second is summed up once.
	t.Run("new-mail-summary same second", testRunNewMailSameSecond)

	// A page that ends inside a second loses none of that second's mail.
	t.Run("new-mail-summary page ends inside a second", testRunNewMailSplitSecond)

	// Past the per-run cap the oldest are summed up, the summary says how many
	// newer are left, and the cursor never passes mail not summed up.
	t.Run("new-mail-summary run cap", testRunNewMailRunCap)

	t.Run("jira-state-report", testRunJiraStateReport)

	t.Run("team-performance-report", testRunTeamPerformanceReport)
}

func testRunNewMailSummary(t *testing.T) {
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
}

// seedMailBurst adds n messages "burst-1" (newest) … "burst-n" to "work",
// one a minute from 201 minutes ago back (older than the seeded mail), with
// subjects "Alert i".
func seedMailBurst(t *testing.T, d *db.DB, n int) {
	t.Helper()
	if _, err := d.Exec(`WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
		INSERT INTO gmail_messages (account_id, id, from_email, subject, internal_date)
		SELECT 1, 'burst-' || i, 'bot@example.com', 'Alert ' || i, strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || (i + 200) || ' minutes')
		FROM n`, n); err != nil {
		t.Fatal(err)
	}
}

// summedSubjects is every subject the llm() calls of gen were given, in call
// order, failing on one summed up twice.
func summedSubjects(t *testing.T, gen *automationstest.FakeGenerator) []string {
	t.Helper()
	var out []string
	seen := map[string]bool{}
	for _, call := range gen.Snapshot() {
		var input []struct {
			Subject string `json:"subject"`
		}
		if err := json.Unmarshal([]byte(llmInputOf(t, call.UserMessage)), &input); err != nil {
			t.Fatalf("llm() input: %v", err)
		}
		for _, m := range input {
			if seen[m.Subject] {
				t.Fatalf("%q summed up twice", m.Subject)
			}
			seen[m.Subject] = true
			out = append(out, m.Subject)
		}
	}
	return out
}

func testRunNewMailBurst(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- a burst"}}
	f := newTplFixture(t, gen)
	seedMailBurst(t, f.d, 450)
	a := f.installTemplate(t, "new-mail-summary", nil)
	id := f.mailEvent(t, a, "c1")
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")

	reads := f.toolSteps(t, id, "list_emails")
	if len(reads) < 3 || !strings.Contains(reads[0].ArgsJSON, `"limit":200`) || !strings.Contains(reads[1].ArgsJSON, `"before":"`) {
		t.Fatalf("list_emails steps = %d (first %s); want pages of 200 walked older with before", len(reads), reads[0].ArgsJSON)
	}
	if got := summedSubjects(t, gen); len(got) != 453 || gen.CallCount() != 3 {
		t.Fatalf("summed up %d messages in %d llm() calls; want all 453 in 3", len(got), gen.CallCount())
	}
	outs := f.outputs(t)
	if len(outs) != 1 || outs[0].Title != "New mail in work: 453 messages" || strings.Contains(outs[0].Body, "left") {
		t.Fatalf("outputs = %+v; want one summary of all 453 messages", outs)
	}
	if got, newest := f.mailCursor(t, a), f.newestMail(t); got != newest {
		t.Fatalf("work cursor = %q; want the newest message's date %q", got, newest)
	}

	second := f.mailEvent(t, a, "c2")
	f.step(t, 1)
	f.wantRun(t, second, db.RunSucceeded, "")
	if n := len(f.outputs(t)); n != 1 {
		t.Fatalf("outputs after a run without newer mail = %d; want still 1", n)
	}
}

func testRunNewMailSameSecond(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- mail"}}
	f := newTplFixture(t, gen)
	a := f.installTemplate(t, "new-mail-summary", nil)
	first := f.mailEvent(t, a, "c1")
	f.step(t, 1)
	f.wantRun(t, first, db.RunSucceeded, "")
	newest := f.newestMail(t)

	// A message synced late with the same second as the cursor.
	if _, err := f.d.Exec(`INSERT INTO gmail_messages (account_id, id, from_email, subject, internal_date)
		VALUES (1, 'm4', 'd@example.com', 'Late at the same second', ?)`, newest); err != nil {
		t.Fatal(err)
	}
	second := f.mailEvent(t, a, "c2")
	f.step(t, 1)
	f.wantRun(t, second, db.RunSucceeded, "")
	outs := f.outputs(t)
	if len(outs) != 2 || outs[1].Title != "New mail in work: 1 message" {
		t.Fatalf("outputs = %+v; want a second summary of the late message alone", outs)
	}
	if got := summedSubjects(t, gen); len(got) != 4 || got[3] != "Late at the same second" {
		t.Fatalf("summed subjects = %v; want the three messages, then the late one once", got)
	}
	if got := f.mailCursor(t, a); got != newest {
		t.Fatalf("work cursor = %q; want still %q", got, newest)
	}

	third := f.mailEvent(t, a, "c3")
	f.step(t, 1)
	f.wantRun(t, third, db.RunSucceeded, "")
	if n := len(f.outputs(t)); n != 2 {
		t.Fatalf("outputs after a run without newer mail = %d; want still 2", n)
	}
}

func testRunNewMailSplitSecond(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- a burst"}}
	f := newTplFixture(t, gen)
	seedMailBurst(t, f.d, 100)
	if _, err := f.d.Exec(`WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 150)
		INSERT INTO gmail_messages (account_id, id, from_email, subject, internal_date)
		SELECT 1, 'tie-' || i, 'bot@example.com', 'Tie ' || i, strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-8 hours')
		FROM n`); err != nil {
		t.Fatal(err)
	}
	a := f.installTemplate(t, "new-mail-summary", nil)
	id := f.mailEvent(t, a, "c1")
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	if got := summedSubjects(t, gen); len(got) != 253 {
		t.Fatalf("summed up %d messages; want all 253, the 150 of one second included", len(got))
	}
}

func testRunNewMailRunCap(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- a burst"}}
	f := newTplFixture(t, gen)
	seedMailBurst(t, f.d, 650)
	a := f.installTemplate(t, "new-mail-summary", nil)
	first := f.mailEvent(t, a, "c1")
	f.step(t, 1)
	f.wantRun(t, first, db.RunSucceeded, "")

	outs := f.outputs(t)
	if len(outs) != 1 || outs[0].Title != "New mail in work: 600 of 653 messages" {
		t.Fatalf("outputs = %+v; want one summary of 600 of the 653 messages", outs)
	}
	mustContain(t, "summary body", outs[0].Body, "53 newer messages are left for the next run.")
	summed := summedSubjects(t, gen)
	if len(summed) != 600 || summed[0] != "Alert 650" || summed[599] != "Alert 51" {
		t.Fatalf("summed up %d messages (%v … %v); want the oldest 600, Alert 650 … Alert 51", len(summed), summed[0], summed[len(summed)-1])
	}
	var alert51 string
	if err := f.d.QueryRow(`SELECT internal_date FROM gmail_messages WHERE id = 'burst-51'`).Scan(&alert51); err != nil {
		t.Fatal(err)
	}
	if got := f.mailCursor(t, a); got != alert51 {
		t.Fatalf("work cursor = %q; want the newest summed-up message's date %q, not past the mail left", got, alert51)
	}

	second := f.mailEvent(t, a, "c2")
	f.step(t, 1)
	f.wantRun(t, second, db.RunSucceeded, "")
	outs = f.outputs(t)
	if len(outs) != 2 || outs[1].Title != "New mail in work: 53 messages" {
		t.Fatalf("outputs = %+v; want a second summary of the 53 left", outs)
	}
	if got := summedSubjects(t, gen); len(got) != 653 {
		t.Fatalf("summed up %d messages over both runs; want each of the 653 once", len(got))
	}
	if got, newest := f.mailCursor(t, a), f.newestMail(t); got != newest {
		t.Fatalf("work cursor = %q; want the newest message's date %q", got, newest)
	}
}

func testRunJiraStateReport(t *testing.T) {
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
}

func testRunTeamPerformanceReport(t *testing.T) {
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

// mailCursor is the date of new-mail-summary's committed cursor of "work".
func (f *exFixture) mailCursor(t *testing.T, a db.Automation) string {
	t.Helper()
	raw, err := f.d.GetAutomationState(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	var state struct {
		Cursors map[string]struct {
			Date string   `json:"date"`
			IDs  []string `json:"ids"`
		} `json:"cursors"`
	}
	if err := json.Unmarshal(raw, &state); err != nil {
		t.Fatalf("state %s: %v", raw, err)
	}
	return state.Cursors["work"].Date
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

// productionSizeSeed adds production-size rows over the template fixtures:
// 200 more PAY issues, each with a 20 KiB raw payload, 20 KiB of custom
// field values, an 8 KiB description and two status changes this week; 40
// people with full cards (about 6 KiB each) and 30 messages of 2 KiB each.
const productionSizeSeed = `
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200)
INSERT INTO jira_issues (account_id, key, id, project_key, board_id, sprint_id, summary, description_text, issue_type, status,
    status_category, assignee_display_name, priority, created_at, updated_at, synced_at, raw_json, custom_fields_json)
SELECT 1, 'PAY-' || (100 + i), '2' || i, 'PAY', 1, 0, 'Payments work item ' || i || ' ' || hex(randomblob(40)),
    hex(randomblob(4096)), 'Story', 'In Progress', 'indeterminate', 'colleague A', 'Medium',
    '2026-09-01T09:00:00Z', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 days'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    '{"fields":{"blob":"' || hex(randomblob(10240)) || '"}}', '{"customfield_10010":"' || hex(randomblob(10240)) || '"}'
FROM n;

INSERT INTO jira_issue_changelog (account_id, issue_key, history_id, field, from_string, to_string, author_display_name, changed_at)
SELECT 1, key, 'h1', 'status', 'To Do', 'In Review', 'colleague A', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-5 days')
FROM jira_issues WHERE key LIKE 'PAY-1__' OR key LIKE 'PAY-2__' OR key LIKE 'PAY-3__';
INSERT INTO jira_issue_changelog (account_id, issue_key, history_id, field, from_string, to_string, author_display_name, changed_at)
SELECT 1, key, 'h2', 'status', 'In Review', 'In Progress', 'colleague A', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-2 days')
FROM jira_issues WHERE key LIKE 'PAY-1__' OR key LIKE 'PAY-2__' OR key LIKE 'PAY-3__';
INSERT INTO jira_changelog_sync (account_id, issue_key, issue_updated_at, synced_at)
SELECT 1, key, updated_at, synced_at FROM jira_issues WHERE key LIKE 'PAY-1__' OR key LIKE 'PAY-2__' OR key LIKE 'PAY-3__';

WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 40)
INSERT INTO users (id, name, display_name, real_name)
SELECT '1:U9' || printf('%07d', i), 'person-' || i, 'person ' || i, 'person ' || i FROM n;

WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 40)
INSERT INTO people_cards (user_id, period_from, period_to, message_count, summary, communication_style, decision_role,
    red_flags, highlights, accomplishments, communication_guide, decision_style, tactics, relationship_context, status)
SELECT '1:U9' || printf('%07d', i), 1759820400, 1760425200 + i, 120, hex(randomblob(512)), 'driver', 'contributor',
    '["' || hex(randomblob(256)) || '"]', '["' || hex(randomblob(256)) || '"]', '["' || hex(randomblob(256)) || '"]',
    hex(randomblob(512)), hex(randomblob(150)), '["' || hex(randomblob(512)) || '"]', hex(randomblob(256)), 'active'
FROM n;

WITH RECURSIVE p(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM p WHERE i < 40),
     m(j) AS (SELECT 1 UNION ALL SELECT j + 1 FROM m WHERE j < 30)
INSERT INTO messages (channel_id, ts, user_id, text)
SELECT '1:C0REL', (1760500000 + i * 100 + j) || '.000100', '1:U9' || printf('%07d', i), hex(randomblob(1024))
FROM p, m;
`

// TestTemplates_ProductionSizeReports runs jira-state-report and
// team-performance-report over production-size data through the executor:
// every tool result passes the 256 KiB cap, every llm() input the 200 KiB
// cap, and the estimated tokens fit the recipes' budgets (the generator
// reports no usage, so llm() estimates bytes/4).
func TestTemplates_ProductionSizeReports(t *testing.T) {
	for _, c := range []struct {
		name   string
		params map[string]string
	}{
		{"jira-state-report", map[string]string{"PROJECT": "PAY"}},
		{"team-performance-report", nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			gen := &automationstest.FakeGenerator{Replies: []string{"## Summary\nA busy week."}}
			f := newTplFixture(t, gen)
			if _, err := f.d.Exec(productionSizeSeed); err != nil {
				t.Fatalf("seeding production-size rows: %v", err)
			}
			a := f.installTemplate(t, c.name, c.params)
			id := f.enqueue(t, a, db.TriggerSchedule)
			f.step(t, 1)
			f.wantRun(t, id, db.RunSucceeded, "")
			if n := len(f.outputs(t)); n == 0 {
				t.Fatal("no output committed")
			}
			for _, call := range gen.Snapshot() {
				if n := len(llmInputOf(t, call.UserMessage)); n > automations.MaxLLMInputBytes {
					t.Fatalf("llm() input = %d bytes; want at most %d", n, automations.MaxLLMInputBytes)
				}
			}
			mustContain(t, "report input", gen.Snapshot()[0].UserMessage, "PAY-300")
		})
	}
}
