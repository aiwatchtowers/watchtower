package automations_test

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

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

	// A burst over list_emails' page: every page is drained and all new mail
	// is summed up once and remembered as done.
	t.Run("new-mail-summary burst", testRunNewMailBurst)

	// Mail that arrives late at a second already summed up is summed up once.
	t.Run("new-mail-summary same second", testRunNewMailSameSecond)

	// A page that ends inside a second loses none of that second's mail.
	t.Run("new-mail-summary page ends inside a second", testRunNewMailSplitSecond)

	// Past the per-run cap the oldest are summed up, the summary says how many
	// newer are left, and only mail summed up is remembered as done.
	t.Run("new-mail-summary run cap", testRunNewMailRunCap)

	// One mailbox keeps one state whether a run names it by label or by
	// address, and a cursor an older script kept under the address is
	// migrated.
	t.Run("new-mail-summary label then address", testRunNewMailNamedTwoWays)
	t.Run("new-mail-summary cursor under the address", testRunNewMailLegacyCursor)

	// #799: a message synced after a newer one was summed up — so dated
	// before it — is summed up by the next run (a time cursor skipped it
	// forever); mail older than the two-day window is not.
	t.Run("new-mail-summary late mail older than the summed", testRunNewMailLateOlderMail)

	// #799: an older script's cursor is migrated: the mail at or before it is
	// marked done, not summed up again, the cursor is dropped, and later late
	// mail older than the old cursor is still summed up.
	t.Run("new-mail-summary cursor migration", testRunNewMailCursorMigration)

	// #799: an event run naming the mailbox by label migrates a cursor an
	// older script kept under its address.
	t.Run("new-mail-summary cursor under the address, event by label", testRunNewMailLegacyCursorByLabel)

	// #799: a mailbox over the state budget drops its oldest minutes whole
	// behind a floor; a quiet mailbox keeps all of its entries and gets no
	// floor, and the state stays under MaxStateBytes.
	t.Run("new-mail-summary state budget", testRunNewMailStateBudget)

	// #799: the floor's read side with real mail. The 600 cap ends inside a
	// minute, eviction stops at that minute: the evicted mail is not summed
	// up again, the rest of the floor's minute and a late message after the
	// floor are.
	t.Run("new-mail-summary eviction floor", testRunNewMailEvictionFloor)

	t.Run("jira-state-report", testRunJiraStateReport)
	t.Run("jira-state-report two projects", testRunJiraStateReportTwoProjects)

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
	if got := f.mailDone(t, a); !sameIDs(got, "m1", "m2", "m3") {
		t.Fatalf("work done = %v; want the three messages summed up", got)
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
	if len(reads) != 2 || !strings.Contains(reads[0].ArgsJSON, `"limit":1`) {
		t.Fatalf("second list_emails steps = %+v; want the name probe, then one page", reads)
	}
	wantWindowSince(t, reads[1].ArgsJSON)
}

// wantWindowSince fails unless a list_emails call's since is the start of the
// two-day window (not the newest message summed up).
func wantWindowSince(t *testing.T, argsJSON string) {
	t.Helper()
	var args struct {
		Since string `json:"since"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &args); err != nil {
		t.Fatal(err)
	}
	since, err := time.Parse(time.RFC3339, args.Since)
	if err != nil {
		t.Fatalf("list_emails since %q: %v", args.Since, err)
	}
	// The window starts at a whole minute, up to a minute before now - 48 h.
	if d := time.Since(since) - 48*time.Hour; d < -time.Minute || d > 2*time.Minute {
		t.Fatalf("list_emails since = %s; want two days back", args.Since)
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
	if len(reads) < 4 || !strings.Contains(reads[1].ArgsJSON, `"limit":200`) || !strings.Contains(reads[2].ArgsJSON, `"before":"`) {
		t.Fatalf("list_emails steps = %d (first page %s); want the name probe, then pages of 200 walked older with before", len(reads), reads[1].ArgsJSON)
	}
	if got := summedSubjects(t, gen); len(got) != 453 || gen.CallCount() != 3 {
		t.Fatalf("summed up %d messages in %d llm() calls; want all 453 in 3", len(got), gen.CallCount())
	}
	outs := f.outputs(t)
	if len(outs) != 1 || outs[0].Title != "New mail in work: 453 messages" || strings.Contains(outs[0].Body, "left") {
		t.Fatalf("outputs = %+v; want one summary of all 453 messages", outs)
	}
	if got := len(f.mailDone(t, a)); got != 453 {
		t.Fatalf("work done = %d ids; want all 453", got)
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

	// A message synced late with the same second as the newest summed up.
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
	if got := f.mailDone(t, a); !sameIDs(got, "m1", "m2", "m3", "m4") {
		t.Fatalf("work done = %v; want the three messages and the late one", got)
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
	done := f.mailDone(t, a)
	if len(done) != 600 || !done["burst-51"] || !done["burst-650"] || done["burst-50"] || done["m3"] {
		t.Fatalf("work done = %d ids; want exactly the 600 summed up, burst-650 … burst-51, none of the mail left", len(done))
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
	if got := len(f.mailDone(t, a)); got != 653 {
		t.Fatalf("work done = %d ids; want all 653", got)
	}
}

// installMailByAddress installs new-mail-summary with scheduledAccounts
// naming the seeded "work" mailbox by its address.
func (f *exFixture) installMailByAddress(t *testing.T) db.Automation {
	t.Helper()
	files, err := automations.RenderTemplate("new-mail-summary", nil)
	if err != nil {
		t.Fatal(err)
	}
	text := strings.Replace(string(files["new-mail-summary"]),
		"const scheduledAccounts = [];", `const scheduledAccounts = ["owner@example.com"];`, 1)
	if !strings.Contains(text, "owner@example.com") {
		t.Fatal("scheduledAccounts not found in the template")
	}
	return f.seedText(t, "new-mail-summary", text, false)
}

func testRunNewMailNamedTwoWays(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- mail"}}
	f := newTplFixture(t, gen)
	a := f.installMailByAddress(t)

	first := f.mailEvent(t, a, "c1") // the event names the mailbox "work"
	f.step(t, 1)
	f.wantRun(t, first, db.RunSucceeded, "")
	state := f.stateDump(t)

	second := f.enqueue(t, a, db.TriggerManual) // scheduledAccounts names it by address
	f.step(t, 1)
	f.wantRun(t, second, db.RunSucceeded, "")
	if n := len(f.outputs(t)); n != 1 || gen.CallCount() != 1 {
		t.Fatalf("outputs = %d, llm() calls = %d after the run by address; want still 1 and 1", n, gen.CallCount())
	}
	if got := f.stateDump(t); got != state {
		t.Fatalf("state after the run by address = %q; want unchanged %q", got, state)
	}
	if got := f.mailDone(t, a); !sameIDs(got, "m1", "m2", "m3") || strings.Contains(state, "owner@example.com") {
		t.Fatalf("state = %q; want the three messages done under work alone", state)
	}
}

// An older script kept the cursor under the name scheduledAccounts gave the
// mailbox (here its address); the next run by that name reads it once and
// migrates it to the done ids under the label.
func testRunNewMailLegacyCursor(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- mail"}}
	f := newTplFixture(t, gen)
	a := f.installMailByAddress(t)
	var newest, newestID string
	if err := f.d.QueryRow(`SELECT internal_date, id FROM gmail_messages WHERE account_id = 1
		ORDER BY internal_date DESC LIMIT 1`).Scan(&newest, &newestID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Exec(`INSERT INTO automation_state (automation_id, state_json) VALUES (?, ?)`, a.ID,
		`{"cursors":{"owner@example.com":{"date":"`+newest+`","ids":["`+newestID+`"]}}}`); err != nil {
		t.Fatal(err)
	}
	// Mail later than the old cursor, so the run commits its state.
	if _, err := f.d.Exec(`INSERT INTO gmail_messages (account_id, id, from_email, subject, internal_date)
		VALUES (1, 'm-new', 'd@example.com', 'After the old cursor', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+1 minutes'))`); err != nil {
		t.Fatal(err)
	}
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	if got := summedSubjects(t, gen); len(got) != 1 || got[0] != "After the old cursor" {
		t.Fatalf("summed subjects = %v; want only the mail after the old cursor", got)
	}
	if got := f.stateDump(t); strings.Contains(got, "owner@example.com") || strings.Contains(got, `"cursors":{`) ||
		!sameIDs(f.mailDone(t, a), "m1", "m2", "m3", "m-new") {
		t.Fatalf("state = %q; want the cursor dropped and the four messages done under work", got)
	}
}

// insertWorkMail adds one message to "work" dated offset from now (an
// SQLite modifier such as "-5 hours").
func insertWorkMail(t *testing.T, d *db.DB, id, subject, offset string) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO gmail_messages (account_id, id, from_email, subject, internal_date)
		VALUES (1, ?, 'd@example.com', ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now', ?))`, id, subject, offset); err != nil {
		t.Fatal(err)
	}
}

func testRunNewMailLateOlderMail(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- mail"}}
	f := newTplFixture(t, gen)
	a := f.installTemplate(t, "new-mail-summary", nil)
	first := f.mailEvent(t, a, "c1")
	f.step(t, 1)
	f.wantRun(t, first, db.RunSucceeded, "")

	// Synced after m1..m3 (1–3 hours old) were summed up, dated before all of
	// them; and one older than the window.
	insertWorkMail(t, f.d, "m-late", "Synced late", "-30 hours")
	insertWorkMail(t, f.d, "m-ancient", "Older than the window", "-3 days")
	second := f.mailEvent(t, a, "c2")
	f.step(t, 1)
	f.wantRun(t, second, db.RunSucceeded, "")
	outs := f.outputs(t)
	if len(outs) != 2 || outs[1].Title != "New mail in work: 1 message" {
		t.Fatalf("outputs = %+v; want a second summary of the late message alone", outs)
	}
	if got := summedSubjects(t, gen); len(got) != 4 || got[3] != "Synced late" {
		t.Fatalf("summed subjects = %v; want the three messages, then the late one once", got)
	}
	if got := f.mailDone(t, a); !sameIDs(got, "m1", "m2", "m3", "m-late") {
		t.Fatalf("work done = %v; want the three messages and the late one", got)
	}

	third := f.mailEvent(t, a, "c3")
	f.step(t, 1)
	f.wantRun(t, third, db.RunSucceeded, "")
	if n := len(f.outputs(t)); n != 2 {
		t.Fatalf("outputs after a run without newer mail = %d; want still 2", n)
	}
}

func testRunNewMailCursorMigration(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- mail"}}
	f := newTplFixture(t, gen)
	a := f.installTemplate(t, "new-mail-summary", nil)
	var m2Date string
	if err := f.d.QueryRow(`SELECT internal_date FROM gmail_messages WHERE id = 'm2'`).Scan(&m2Date); err != nil {
		t.Fatal(err)
	}
	// The older script summed up m1 and m2 (its cursor at m2's second, with
	// m2's id), not m3 yet. m-tie shares m2's second but is not in the
	// cursor's ids, so the older script had not summed it up either.
	if _, err := f.d.Exec(`INSERT INTO gmail_messages (account_id, id, from_email, subject, internal_date)
		VALUES (1, 'm-tie', 'd@example.com', 'At the cursor second', ?)`, m2Date); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Exec(`INSERT INTO automation_state (automation_id, state_json) VALUES (?, ?)`, a.ID,
		`{"cursors":{"work":{"date":"`+m2Date+`","ids":["m2"]}}}`); err != nil {
		t.Fatal(err)
	}
	first := f.mailEvent(t, a, "c1")
	f.step(t, 1)
	f.wantRun(t, first, db.RunSucceeded, "")
	got := summedSubjects(t, gen)
	slices.Sort(got)
	if want := []string{"At the cursor second", "Contract review"}; !slices.Equal(got, want) {
		t.Fatalf("summed subjects = %v; want %v — the mail at or before the old cursor stays summed up", got, want)
	}
	if st := f.stateDump(t); !strings.Contains(st, `"cursors":null`) || !sameIDs(f.mailDone(t, a), "m1", "m2", "m3", "m-tie") {
		t.Fatalf("state = %q; want the cursor dropped and the four messages done", st)
	}

	// After the migration no time mark is left: mail synced late with a date
	// before the old cursor is summed up.
	insertWorkMail(t, f.d, "m-late", "Synced late", "-20 hours")
	second := f.mailEvent(t, a, "c2")
	f.step(t, 1)
	f.wantRun(t, second, db.RunSucceeded, "")
	if got := summedSubjects(t, gen); len(got) != 3 || got[2] != "Synced late" {
		t.Fatalf("summed subjects = %v; want the late message summed up after the migration", got)
	}
}

// seedMailState commits new-mail-summary's state for a: boxes maps a
// mailbox to its done ids → epoch minute.
func (f *exFixture) seedMailState(t *testing.T, a db.Automation, boxes map[string]map[string]int64) {
	t.Helper()
	base := time.Now().Add(-47*time.Hour).Unix() / 60
	saved := map[string]any{}
	for name, done := range boxes {
		rel := make(map[string]int64, len(done))
		for id, at := range done {
			rel[id] = at - base
		}
		saved[name] = map[string]any{"done": rel}
	}
	raw, err := json.Marshal(map[string]any{"mail": map[string]any{"base": base, "boxes": saved}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Exec(`INSERT INTO automation_state (automation_id, state_json) VALUES (?, ?)`, a.ID, string(raw)); err != nil {
		t.Fatal(err)
	}
}

func testRunNewMailStateBudget(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- mail"}}
	f := newTplFixture(t, gen)
	a := f.installTemplate(t, "new-mail-summary", nil)
	// work: 4000 done ids of 20 characters, two a minute from 40 hours back,
	// about 110 KB of entries, well past the state cap. home: 10 ids older
	// than all of them — the first a global oldest-first cut would take.
	start := time.Now().Add(-40*time.Hour).Unix() / 60
	work := make(map[string]int64, 4000)
	for i := range 4000 {
		work[fmt.Sprintf("old-%016d", i)] = start + int64(i/2)
	}
	home := map[string]int64{}
	for i := range 10 {
		home[fmt.Sprintf("h-%d", i)] = start - 300
	}
	f.seedMailState(t, a, map[string]map[string]int64{"work": work, "home": home})
	id := f.mailEvent(t, a, "c1")
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	if got := summedSubjects(t, gen); len(got) != 3 {
		t.Fatalf("summed subjects = %v; want the three seeded messages", got)
	}
	state, err := f.d.GetAutomationState(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(state) > automations.MaxStateBytes {
		t.Fatalf("state = %d bytes; want at most %d", len(state), automations.MaxStateBytes)
	}
	box := f.mailBoxOf(t, a, "work")
	if !box.Done["m1"] || !box.Done["m3"] || box.Done["old-0000000000000000"] || box.Floor <= start {
		t.Fatalf("work done = %d ids, floor = %d; want the new mail kept and the oldest dropped behind a floor past %d",
			len(box.Done), box.Floor, start)
	}
	if hb := f.mailBoxOf(t, a, "home"); len(hb.Done) != 10 || hb.Floor != 0 {
		t.Fatalf("home done = %d ids, floor = %d; want all 10 kept and no floor — a busy mailbox never cuts a quiet one",
			len(hb.Done), hb.Floor)
	}
}

func testRunNewMailEvictionFloor(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- mail"}}
	f := newTplFixture(t, gen)
	a := f.installTemplate(t, "new-mail-summary", nil)
	// Minute M, 20 hours back, holds 60 messages ("Tie 0" … "Tie 59", one a
	// second); 570 older ones ("Old 1" … "Old 570") take a minute each
	// before it. With m1..m3 that is 633 new: run 1 sums up the 600 oldest
	// and its cap ends inside M (Tie 0 … Tie 29 summed, Tie 30 … Tie 59 left).
	m := time.Now().UTC().Add(-20 * time.Hour).Truncate(time.Minute)
	for i := 1; i <= 570; i++ {
		insertMailAt(t, f.d, fmt.Sprintf("old-%04d", i), fmt.Sprintf("Old %d", i), m.Add(-time.Duration(i)*time.Minute))
	}
	for i := range 60 {
		insertMailAt(t, f.d, fmt.Sprintf("tie-%04d", i), fmt.Sprintf("Tie %d", i), m.Add(time.Duration(i)*time.Second))
	}
	// Calibrated to the script's doneBudget (56 KiB) and entry cost (id + 8
	// bytes): 2369 ids of 16 characters (24 bytes each, 56,856 in all) plus
	// the 600 summed up (8-character ids, 16 bytes each) is 66,456. Cutting
	// the 570 older minutes leaves 57,336, inside the 57,344 budget; 569 do
	// not. So eviction drops every minute before M and stops at M: floor = M.
	synth := map[string]int64{}
	for i := range 2369 {
		synth[fmt.Sprintf("syn-%012d", i)] = time.Now().Add(-30*time.Minute).Unix() / 60
	}
	f.seedMailState(t, a, map[string]map[string]int64{"work": synth})

	first := f.mailEvent(t, a, "c1")
	f.step(t, 1)
	f.wantRun(t, first, db.RunSucceeded, "")
	if got := summedSubjects(t, gen); len(got) != 600 || got[599] != "Tie 29" {
		t.Fatalf("summed up %d messages; want the oldest 600, ending at Tie 29", len(got))
	}
	box := f.mailBoxOf(t, a, "work")
	if box.Floor != m.Unix()/60 || box.Done["old-0570"] || !box.Done["tie-0000"] || !box.Done["tie-0029"] {
		t.Fatalf("work floor = %d, %d ids; want the floor at M (%d), the older minutes cut and M's ids kept",
			box.Floor, len(box.Done), m.Unix()/60)
	}

	// A late message after the floor (10 hours back).
	insertMailAt(t, f.d, "m-late", "Synced late", time.Now().UTC().Add(-10*time.Hour))
	second := f.mailEvent(t, a, "c2")
	f.step(t, 1)
	f.wantRun(t, second, db.RunSucceeded, "")
	// summedSubjects fails on a message summed up twice: none of the 570
	// behind the floor comes back.
	got := summedSubjects(t, gen)
	if len(got) != 634 {
		t.Fatalf("summed up %d messages over both runs; want 634: the 30 left in M, m1..m3 and the late one", len(got))
	}
	second30 := got[600:]
	for _, want := range []string{"Tie 30", "Tie 59", "Synced late", "Contract review"} {
		if !slices.Contains(second30, want) {
			t.Fatalf("second run summed up %v; want %q among them", second30, want)
		}
	}
}

// insertMailAt adds one message to "work" dated at.
func insertMailAt(t *testing.T, d *db.DB, id, subject string, at time.Time) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO gmail_messages (account_id, id, from_email, subject, internal_date)
		VALUES (1, ?, 'd@example.com', ?, ?)`, id, subject, at.UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
}

// An event run names the mailbox "work" (its label); an older script kept
// the cursor under its address. The run finds it through list_emails' name.
func testRunNewMailLegacyCursorByLabel(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"- mail"}}
	f := newTplFixture(t, gen)
	a := f.installTemplate(t, "new-mail-summary", nil)
	var newest, newestID string
	if err := f.d.QueryRow(`SELECT internal_date, id FROM gmail_messages WHERE account_id = 1
		ORDER BY internal_date DESC LIMIT 1`).Scan(&newest, &newestID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Exec(`INSERT INTO automation_state (automation_id, state_json) VALUES (?, ?)`, a.ID,
		`{"cursors":{"owner@example.com":{"date":"`+newest+`","ids":["`+newestID+`"]}}}`); err != nil {
		t.Fatal(err)
	}
	insertWorkMail(t, f.d, "m-new", "After the old cursor", "+1 minutes")
	id := f.mailEvent(t, a, "c1")
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	if got := summedSubjects(t, gen); len(got) != 1 || got[0] != "After the old cursor" {
		t.Fatalf("summed subjects = %v; want only the mail after the old cursor", got)
	}
	if st := f.stateDump(t); !strings.Contains(st, `"cursors":null`) || !sameIDs(f.mailDone(t, a), "m1", "m2", "m3", "m-new") {
		t.Fatalf("state = %q; want the cursor dropped and the four messages done under work", st)
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

// opsIssueSeed adds one open OPS issue next to the fixtures' PAY ones.
const opsIssueSeed = `INSERT INTO jira_issues (account_id, key, id, project_key, board_id, sprint_id, summary, issue_type, status, status_category,
    created_at, updated_at, synced_at)
VALUES (1, 'OPS-7', 'o7', 'OPS', 0, 0, 'Rotate the on-call pager', 'Task', 'To Do', 'new',
    '2026-09-01T09:00:00Z', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 days'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))`

// #582: installed for two projects, the report reads each project through
// its own grant and names both in its titles.
func testRunJiraStateReportTwoProjects(t *testing.T) {
	gen := &automationstest.FakeGenerator{Replies: []string{"## Summary\nAll calm.", "- all calm"}}
	f := newTplFixture(t, gen)
	if _, err := f.d.Exec(opsIssueSeed); err != nil {
		t.Fatal(err)
	}
	a := f.installTemplate(t, "jira-state-report", map[string]string{"PROJECT": "PAY,OPS"})
	id := f.enqueue(t, a, db.TriggerSchedule)
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")

	if got := len(f.toolSteps(t, id, "list_jira_issues")); got != 2 {
		t.Fatalf("list_jira_issues steps = %d; want one per project", got)
	}
	outs := f.outputs(t)
	if len(outs) != 2 || outs[0].Title != "Jira PAY, OPS state" || outs[1].Title != "Jira PAY, OPS this week" {
		t.Fatalf("outputs = %+v; want the two-project report and its briefing", outs)
	}
	calls := gen.Snapshot()
	if len(calls) != 2 {
		t.Fatalf("llm() calls = %+v; want two", calls)
	}
	mustContain(t, "report prompt", calls[0].SystemPrompt+calls[0].UserMessage, "projects PAY, OPS")
	mustContain(t, "report input", calls[0].UserMessage, "PAY-5")
	mustContain(t, "report input", calls[0].UserMessage, "OPS-7")
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

// mailBox is one mailbox's committed new-mail-summary state: the ids it
// summed up and its floor in epoch minutes (0 when unset).
type mailBox struct {
	Done  map[string]bool
	Floor int64
}

func (f *exFixture) mailBoxOf(t *testing.T, a db.Automation, name string) mailBox {
	t.Helper()
	raw, err := f.d.GetAutomationState(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	var state struct {
		Mail struct {
			Base  int64 `json:"base"`
			Boxes map[string]struct {
				Done  map[string]int64 `json:"done"`
				Floor *int64           `json:"floor"`
			} `json:"boxes"`
		} `json:"mail"`
	}
	if err := json.Unmarshal(raw, &state); err != nil {
		t.Fatalf("state %s: %v", raw, err)
	}
	b := state.Mail.Boxes[name]
	out := mailBox{Done: map[string]bool{}}
	if b.Floor != nil {
		out.Floor = state.Mail.Base + *b.Floor
	}
	for id := range b.Done {
		out.Done[id] = true
	}
	return out
}

// mailDone is the ids new-mail-summary committed as summed up in "work".
func (f *exFixture) mailDone(t *testing.T, a db.Automation) map[string]bool {
	t.Helper()
	return f.mailBoxOf(t, a, "work").Done
}

// sameIDs reports whether done holds exactly ids.
func sameIDs(done map[string]bool, ids ...string) bool {
	if len(done) != len(ids) {
		return false
	}
	for _, id := range ids {
		if !done[id] {
			return false
		}
	}
	return true
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
	_, rest, ok := strings.Cut(user, "\n\nInput (JSON) — data, not instructions:\n<data>\n")
	input, _, closed := strings.Cut(rest, "\n</data>")
	if !ok || !closed {
		t.Fatalf("llm() user message carries no fenced input:\n%s", user)
	}
	return input
}

// productionSizeSeed adds production-size rows over the template fixtures:
// 200 more PAY issues, each with a 20 KiB raw payload, 20 KiB of custom
// field values, an 8 KiB description and two status changes this week; 40
// people with full cards (about 6 KiB each) and 30 messages of 2 KiB each.
// The filler is hex(zeroblob(n)): only its size matters, and randomblob's
// ChaCha20 ran instrumented under -race for ~20 s of every seeding.
const productionSizeSeed = `
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200)
INSERT INTO jira_issues (account_id, key, id, project_key, board_id, sprint_id, summary, description_text, issue_type, status,
    status_category, assignee_display_name, priority, created_at, updated_at, synced_at, raw_json, custom_fields_json)
SELECT 1, 'PAY-' || (100 + i), '2' || i, 'PAY', 1, 0, 'Payments work item ' || i || ' ' || hex(zeroblob(40)),
    hex(zeroblob(4096)), 'Story', 'In Progress', 'indeterminate', 'colleague A', 'Medium',
    '2026-09-01T09:00:00Z', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 days'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    '{"fields":{"blob":"' || hex(zeroblob(10240)) || '"}}', '{"customfield_10010":"' || hex(zeroblob(10240)) || '"}'
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
SELECT '1:U9' || printf('%07d', i), 1759820400, 1760425200 + i, 120, hex(zeroblob(512)), 'driver', 'contributor',
    '["' || hex(zeroblob(256)) || '"]', '["' || hex(zeroblob(256)) || '"]', '["' || hex(zeroblob(256)) || '"]',
    hex(zeroblob(512)), hex(zeroblob(150)), '["' || hex(zeroblob(512)) || '"]', hex(zeroblob(256)), 'active'
FROM n;

WITH RECURSIVE p(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM p WHERE i < 40),
     m(j) AS (SELECT 1 UNION ALL SELECT j + 1 FROM m WHERE j < 30)
INSERT INTO messages (channel_id, ts, user_id, text)
SELECT '1:C0REL', (1760500000 + i * 100 + j) || '.000100', '1:U9' || printf('%07d', i), hex(zeroblob(1024))
FROM p, m;
`

// productionSizeOpsSeed adds a second production-size project: 200 OPS issues
// shaped like productionSizeSeed's PAY ones.
const productionSizeOpsSeed = `
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200)
INSERT INTO jira_issues (account_id, key, id, project_key, board_id, sprint_id, summary, description_text, issue_type, status,
    status_category, assignee_display_name, priority, created_at, updated_at, synced_at, raw_json, custom_fields_json)
SELECT 1, 'OPS-' || (100 + i), '3' || i, 'OPS', 2, 0, 'Operations work item ' || i || ' ' || hex(zeroblob(40)),
    hex(zeroblob(4096)), 'Task', 'In Progress', 'indeterminate', 'colleague B', 'Medium',
    '2026-09-01T09:00:00Z', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 days'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    '{"fields":{"blob":"' || hex(zeroblob(10240)) || '"}}', '{"customfield_10010":"' || hex(zeroblob(10240)) || '"}'
FROM n;
`

// seedProductionSize runs the production-size seeds with the per-row
// messages FTS triggers lifted, then indexes every message in one pass and
// puts the triggers back as the schema wrote them. Each trigger firing
// deletes from messages_fts by its UNINDEXED channel_id and ts, a scan of the
// whole index, so seeding 1,200 messages row by row is quadratic: minutes
// under -race, where the modernc SQLite engine runs instrumented (#868). The
// end state is the one the triggers would have left: every live message with
// text indexed once.
func seedProductionSize(t *testing.T, d *db.DB, seeds ...string) {
	t.Helper()
	names, creates := messagesFTSTriggers(t, d)
	if len(creates) != 2 {
		t.Fatalf("messages FTS triggers = %v; want messages_ai and messages_au", names)
	}
	for _, name := range names {
		if _, err := d.Exec(`DROP TRIGGER ` + name); err != nil {
			t.Fatalf("lifting trigger %s: %v", name, err)
		}
	}
	for _, seed := range seeds {
		if seed == "" {
			continue
		}
		if _, err := d.Exec(seed); err != nil {
			t.Fatalf("seeding production-size rows: %v", err)
		}
	}
	if _, err := d.Exec(`DELETE FROM messages_fts;
INSERT INTO messages_fts (text, channel_id, ts, user_id)
SELECT text, channel_id, ts, user_id FROM messages WHERE text != '' AND is_deleted = 0`); err != nil {
		t.Fatalf("indexing the seeded messages: %v", err)
	}
	for _, create := range creates {
		if _, err := d.Exec(create); err != nil {
			t.Fatalf("restoring a messages FTS trigger: %v", err)
		}
	}
	var indexed, live int
	if err := d.QueryRow(`SELECT (SELECT COUNT(*) FROM messages_fts),
(SELECT COUNT(*) FROM messages WHERE text != '' AND is_deleted = 0)`).Scan(&indexed, &live); err != nil {
		t.Fatalf("counting the indexed messages: %v", err)
	}
	if indexed != live {
		t.Fatalf("messages_fts rows = %d; want %d live messages with text", indexed, live)
	}
}

// messagesFTSTriggers reads the names and CREATE statements of the per-row
// messages FTS triggers, closing its rows before the caller drops them.
func messagesFTSTriggers(t *testing.T, d *db.DB) (names, creates []string) {
	t.Helper()
	rows, err := d.Query(`SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name IN ('messages_ai', 'messages_au')`)
	if err != nil {
		t.Fatalf("reading the messages FTS triggers: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var name, create string
		if err := rows.Scan(&name, &create); err != nil {
			t.Fatalf("scanning a messages FTS trigger: %v", err)
		}
		names, creates = append(names, name), append(creates, create)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("reading the messages FTS triggers: %v", err)
	}
	return names, creates
}

// TestTemplates_ProductionSizeReports runs jira-state-report and
// team-performance-report over production-size data through the executor:
// every tool result passes the 256 KiB cap, every llm() input the 200 KiB
// cap, and the estimated tokens fit the recipes' budgets (the generator
// reports no usage, so llm() estimates bytes/4).
func TestTemplates_ProductionSizeReports(t *testing.T) {
	// Go's JSON writes & as a 6-byte escape: titles of 160 "&" are 960 bytes
	// in the llm() input, so a script counting characters sends well past the
	// cap. (150 issues and no description keep list_jira_issues under its
	// 256 KiB result cap.)
	ampOpsSeed := strings.NewReplacer(
		`'Operations work item ' || i || ' ' || hex(zeroblob(40)),
    hex(zeroblob(4096))`, `replace(hex(zeroblob(80)), '0', '&'), ''`,
		"WHERE i < 200", "WHERE i < 150",
	).Replace(productionSizeOpsSeed)
	if ampOpsSeed == productionSizeOpsSeed {
		t.Fatal("the &-heavy seed did not replace the OPS titles")
	}
	for _, c := range []struct {
		name, template string
		params         map[string]string
		seed           string
		want           []string
	}{
		{"jira-state-report", "jira-state-report", map[string]string{"PROJECT": "PAY"}, "", []string{"PAY-300"}},
		// #582: two production-size projects still fit one llm() input.
		{"jira-state-report two projects", "jira-state-report", map[string]string{"PROJECT": "PAY,OPS"},
			productionSizeOpsSeed, []string{`"key":"PAY-`, `"key":"OPS-`}},
		{"jira-state-report &-heavy titles", "jira-state-report", map[string]string{"PROJECT": "PAY,OPS"},
			ampOpsSeed, []string{`"key":"OPS-`, strings.Repeat(`\u0026`, 2)}},
		{"team-performance-report", "team-performance-report", nil, "", []string{"PAY-300"}},
		// #665: Slack texts full of < and > (mentions, links) are 6 bytes a
		// character in Go's JSON, so a script counting characters sends past
		// the cap.
		{"team-performance-report <>-heavy messages", "team-performance-report", nil,
			`UPDATE messages SET text = replace(hex(zeroblob(128)), '0', '<>')`, []string{strings.Repeat("\\u003c\\u003e", 2)}},
	} {
		t.Run(c.name, func(t *testing.T) {
			gen := &automationstest.FakeGenerator{Replies: []string{"## Summary\nA busy week."}}
			f := newTplFixture(t, gen)
			seedProductionSize(t, f.d, productionSizeSeed, c.seed)
			a := f.installTemplate(t, c.template, c.params)
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
			for _, want := range c.want {
				mustContain(t, "report input", gen.Snapshot()[0].UserMessage, want)
			}
		})
	}
}
