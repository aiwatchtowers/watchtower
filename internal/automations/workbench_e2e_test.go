package automations_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
)

// The workbench recipes (spec §15 #2 and #5) in templates/, run end
// to end through the executor: FakeShell answers shell(), FakeSessionDesk
// plays the Desktop for session().

const prListCmd = "gh pr list --state open --limit 200 --json number,title,url,author,updatedAt"

// buttonRecipes are the three button recipes: slug, label, command.
var buttonRecipes = []struct{ slug, label, cmd string }{
	{"release", "Release", "make release"},
	{"deploy-test", "Deploy to test", "make deploy-test"},
	{"deploy-stage", "Deploy to stage", "make deploy-stage"},
}

var workbenchRecipeSlugs = []string{"pr-review-rounds", "release", "deploy-test", "deploy-stage"}

func readWorkbenchRecipe(t *testing.T, slug string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("templates", slug+".md"))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// wbE2E is an executor over a file DB with one workbench, a FakeShell and a
// FakeSessionDesk.
type wbE2E struct {
	*exFixture
	wb     int64
	folder string
	shell  *automationstest.FakeShell
	desk   *automationstest.FakeSessionDesk
}

func newWbE2E(t *testing.T, res automations.ShellResult) *wbE2E {
	t.Helper()
	w := &wbE2E{shell: &automationstest.FakeShell{Result: res}}
	w.exFixture = newExFixture(t, exOpts{fileDB: true, backends: func(f *exFixture, b *automations.Backends) {
		b.Shell = w.shell
		b.Workbench = automations.NewWorkbenchResolver(f.d, func() string { return "claude" }, func(string) bool { return false })
	}})
	w.wb, w.folder = newWorkbench(t, w.d)
	w.desk = &automationstest.FakeSessionDesk{DB: w.d, Wake: w.e.Wake}
	return w
}

// seedRecipe indexes testdata recipe slug in the workbench, confirms and
// enables it.
func (w *wbE2E) seedRecipe(t *testing.T, slug string) db.Automation {
	t.Helper()
	writeWorkbenchRecipe(t, w.folder, slug, string(readWorkbenchRecipe(t, slug)))
	rescanWorkbench(t, w.ix, w.wb, w.folder)
	a := workbenchRow(t, w.d, w.wb, slug)
	if a.ParseError != "" {
		t.Fatalf("%s does not parse: %s", slug, a.ParseError)
	}
	if err := w.d.ConfirmAutomation(a.ID, a.ApprovalHash, exStart); err != nil {
		t.Fatal(err)
	}
	if err := w.d.SetAutomationEnabled(a.ID, true, exStart); err != nil {
		t.Fatal(err)
	}
	return workbenchRow(t, w.d, w.wb, slug)
}

// drive starts run id and plays the Desktop until the run ended.
func (w *wbE2E) drive(t *testing.T, id int64) *db.AutomationRun {
	t.Helper()
	w.stepNoWait(t, 1)
	deadline := time.Now().Add(10 * time.Second)
	for {
		if _, err := w.desk.Poll(); err != nil {
			t.Fatalf("desk: %v", err)
		}
		r := w.run(t, id)
		if !slices.Contains([]string{db.RunQueued, db.RunRunning, db.RunWaiting}, r.Status) {
			w.e.Wait()
			return r
		}
		if time.Now().After(deadline) {
			t.Fatalf("run %d never ended (is %s/%s)", id, r.Status, r.WaitingReason)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (w *wbE2E) setState(t *testing.T, a db.Automation, state string) {
	t.Helper()
	if _, err := w.d.Exec(`INSERT INTO automation_state (automation_id, state_json) VALUES (?, ?)`, a.ID, state); err != nil {
		t.Fatal(err)
	}
}

func (w *wbE2E) state(t *testing.T, a db.Automation) map[string]any {
	t.Helper()
	raw, err := w.d.GetAutomationState(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("state %s: %v", raw, err)
	}
	return m
}

// onlyReport is the one committed report output.
func (w *wbE2E) onlyReport(t *testing.T) db.AutomationOutput {
	t.Helper()
	outs, err := w.d.ListAutomationOutputs("report", 10)
	if err != nil || len(outs) != 1 {
		t.Fatalf("report outputs = %+v, %v; want one", outs, err)
	}
	return outs[0]
}

func (w *wbE2E) stepsOfKind(t *testing.T, id int64, kind string) []db.AutomationRunStep {
	t.Helper()
	var out []db.AutomationRunStep
	for _, s := range w.steps(t, id) {
		if s.Kind == kind {
			out = append(out, s)
		}
	}
	return out
}

func runLabelOf(id int64) string { return " · run #" + strconv.FormatInt(id, 10) }

func TestWorkbenchRecipes_AllParseAndConfirm(t *testing.T) {
	for _, slug := range workbenchRecipeSlugs {
		data := readWorkbenchRecipe(t, slug)
		r, err := automations.ParseRecipe(slug, data, automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: 1})
		if err != nil {
			t.Fatalf("%s: %v", slug, err)
		}
		if r.Scope.Kind != automations.ScopeWorkbench || !slices.Equal(r.Outputs, []string{"report"}) {
			t.Fatalf("%s: scope %v outputs %v; want workbench, [report]", slug, r.Scope, r.Outputs)
		}
		if _, err := automations.ParseRecipe(slug, data, automations.Scope{Kind: automations.ScopePersonal}); err == nil {
			t.Fatalf("%s parsed as a personal recipe; its shell:/session: entries are workbench only", slug)
		}
	}
	w := newWbE2E(t, automations.ShellResult{})
	for _, slug := range workbenchRecipeSlugs {
		if a := w.seedRecipe(t, slug); !a.Runnable() {
			t.Fatalf("%s is not runnable after confirm and enable", slug)
		}
	}
}

func TestRelease_ButtonTriggerConfirmTrue(t *testing.T) {
	for _, b := range buttonRecipes {
		r, err := automations.ParseRecipe(b.slug, readWorkbenchRecipe(t, b.slug), automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: 1})
		if err != nil {
			t.Fatalf("%s: %v", b.slug, err)
		}
		if r.Trigger.Kind != automations.TriggerButton || r.Trigger.Button == nil ||
			*r.Trigger.Button != (automations.ButtonTrigger{Label: b.label, Confirm: true}) {
			t.Fatalf("%s trigger = %+v (button %+v); want button{label: %q, confirm: true}", b.slug, r.Trigger, r.Trigger.Button, b.label)
		}
		want := `shell:"` + b.cmd + `"`
		if !slices.Contains(r.Permissions, want) {
			t.Fatalf("%s permissions = %v; want %s", b.slug, r.Permissions, want)
		}
	}
	r, err := automations.ParseRecipe("pr-review-rounds", readWorkbenchRecipe(t, "pr-review-rounds"), automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: 1})
	if err != nil || r.Trigger.Kind != automations.TriggerSchedule || r.Trigger.Schedule != "0 10,16 * * 1-5" {
		t.Fatalf("pr-review-rounds trigger = %+v, %v; want schedule 0 10,16 * * 1-5", r.Trigger, err)
	}
}

// prList is gh's JSON for three open pull requests: #12 last updated before
// the seeded last round, #14 and #15 after it.
const prList = `[
	{"number": 15, "title": "Retry the sync", "url": "https://example.com/acme/pull/15", "author": {"login": "colleague-a"}, "updatedAt": "2026-10-14T09:30:00Z"},
	{"number": 12, "title": "Old docs fix", "url": "https://example.com/acme/pull/12", "author": {"login": "colleague-b"}, "updatedAt": "2026-10-13T16:00:00Z"},
	{"number": 14, "title": "Add the export", "url": "https://example.com/acme/pull/14", "author": {"login": "colleague-a"}, "updatedAt": "2026-10-14T10:00:00Z"}
]`

const lastRound = "2026-10-14T08:00:00.000Z"

func TestPRReviewRounds_E2E(t *testing.T) {
	w := newWbE2E(t, automations.ShellResult{Stdout: prList})
	w.desk.Outcomes = []automationstest.SessionOutcome{{Summary: "2 findings filed, 1 comment posted"}, {AgentError: "overloaded_error"}}
	a := w.seedRecipe(t, "pr-review-rounds")
	w.setState(t, a, `{"last_round":"`+lastRound+`"}`)
	id := w.enqueue(t, a, db.TriggerSchedule)

	r := w.drive(t, id)
	if r.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	if calls := w.shell.Calls(); len(calls) != 1 || calls[0].Cmd != prListCmd || calls[0].Dir != w.folder {
		t.Fatalf("shell calls = %+v; want one %q in %s", calls, prListCmd, w.folder)
	}
	launches := w.desk.Launches()
	checkReviewLaunches(t, launches, id)
	if steps := w.stepsOfKind(t, id, automations.StepKindSession); len(steps) != 2 || steps[0].SessionID != launches[0].SessionID ||
		steps[1].SessionID != launches[1].SessionID {
		t.Fatalf("session steps = %+v; want two, in launch order", steps)
	}

	// #15's session ended with an error: it is retried next round, so
	// last_round stays and only #14 is marked reviewed (board #562).
	st := w.state(t, a)
	if got, _ := st["last_round"].(string); got != lastRound {
		t.Fatalf("last_round = %q; want it kept at %s while #15 waits for a retry", got, lastRound)
	}
	if rev, _ := st["reviewed"].(map[string]any); len(rev) != 1 || rev["14"] == nil {
		t.Fatalf("reviewed = %v; want only #14", rev)
	}
	rep := w.onlyReport(t)
	mustContain(t, "report title", rep.Title, "2 pull requests")
	for _, want := range []string{"#14 Add the export (https://example.com/acme/pull/14): finished — 2 findings filed, 1 comment posted",
		"#15 Retry the sync (https://example.com/acme/pull/15): error — overloaded_error"} {
		mustContain(t, "report body", rep.Body, want)
	}
	if strings.Contains(rep.Body, "#12") {
		t.Fatalf("report names #12, which did not change since the last round:\n%s", rep.Body)
	}
}

// checkReviewLaunches checks the round launched one review session for
// each of PRs #14 and #15, in that order.
func checkReviewLaunches(t *testing.T, launches []automationstest.SessionLaunch, runID int64) {
	t.Helper()
	if len(launches) != 2 {
		t.Fatalf("launches = %+v; want two sessions", launches)
	}
	for i, n := range []string{"14", "15"} {
		l := launches[i]
		if l.Title != "⚙ PR #"+n+" review"+runLabelOf(runID) || l.Agent != "claude" {
			t.Fatalf("launch %d = title %q agent %q; want PR #%s review, claude", i, l.Title, l.Agent, n)
		}
		for _, want := range []string{"#" + n, "ask_owner", "after", "gh pr review " + n, "finish_session"} {
			mustContain(t, "session prompt", l.Prompt, want)
		}
		if len(l.Prompt) > 3000 {
			t.Fatalf("prompt is %d bytes; keep it well under the 4096-byte step args limit", len(l.Prompt))
		}
	}
}

func mustParseTime(t *testing.T, s string) time.Time {
	t.Helper()
	ts, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatalf("time %q: %v", s, err)
	}
	return ts
}

func TestPRReviewRounds_NoUpdatedPRsStartsNoSession(t *testing.T) {
	w := newWbE2E(t, automations.ShellResult{Stdout: prList})
	a := w.seedRecipe(t, "pr-review-rounds")
	w.setState(t, a, `{"last_round":"2026-10-15T08:00:00.000Z"}`)
	id := w.enqueue(t, a, db.TriggerSchedule)

	if r := w.drive(t, id); r.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	if n := len(w.desk.Launches()); n != 0 || len(w.stepsOfKind(t, id, automations.StepKindSession)) != 0 {
		t.Fatalf("%d sessions launched; want none", n)
	}
	if n := w.count(t, "terminal_sessions"); n != 0 {
		t.Fatalf("terminal_sessions = %d; want none", n)
	}
	mustContain(t, "report body", w.onlyReport(t).Body, "No open pull request changed since the last round.")
}

func TestRelease_E2E(t *testing.T) {
	for _, b := range buttonRecipes {
		t.Run(b.slug+" succeeds", func(t *testing.T) {
			w := newWbE2E(t, automations.ShellResult{Stdout: "built v1.2.3\npublished v1.2.3\n"})
			w.desk.Outcomes = []automationstest.SessionOutcome{{Summary: "healthy: v1.2.3 answers"}}
			id := w.enqueue(t, w.seedRecipe(t, b.slug), db.TriggerButton)

			r := w.drive(t, id)
			if r.Status != db.RunSucceeded {
				t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
			}
			if calls := w.shell.Calls(); len(calls) != 1 || calls[0].Cmd != b.cmd {
				t.Fatalf("shell calls = %+v; want one %q", calls, b.cmd)
			}
			launches := w.desk.Launches()
			if len(launches) != 1 || launches[0].Title != "⚙ "+b.label+" check"+runLabelOf(id) {
				t.Fatalf("launches = %+v; want one %s check", launches, b.label)
			}
			mustContain(t, "check prompt", launches[0].Prompt, "healthy")
			mustContain(t, "check prompt", launches[0].Prompt, b.cmd)
			rep := w.onlyReport(t)
			mustContain(t, "report title", rep.Title, b.label+": finished")
			mustContain(t, "report body", rep.Body, "published v1.2.3")
			mustContain(t, "report body", rep.Body, "healthy: v1.2.3 answers")
		})
		t.Run(b.slug+" fails", func(t *testing.T) {
			w := newWbE2E(t, automations.ShellResult{ExitCode: 2, Stdout: "building\n", Stderr: "error: the tag v1.2.3 exists\n"})
			id := w.enqueue(t, w.seedRecipe(t, b.slug), db.TriggerButton)

			r := w.drive(t, id)
			if r.Status != db.RunFailed || r.ErrorKind != db.ErrKindScript {
				t.Fatalf("run = %s/%s (%s); want failed/script", r.Status, r.ErrorKind, r.Error)
			}
			mustContain(t, "run error", r.Error, "exited 2")
			mustContain(t, "run error", r.Error, "error: the tag v1.2.3 exists")
			if n := len(w.desk.Launches()); n != 0 || len(w.stepsOfKind(t, id, automations.StepKindSession)) != 0 {
				t.Fatalf("%d sessions launched; want none after a failed command", n)
			}
			if outs := w.stepsOfKind(t, id, automations.StepKindOutput); len(outs) != 0 {
				t.Fatalf("output steps = %+v; want none after the throw", outs)
			}
			if n := w.count(t, "automation_outputs"); n != 0 {
				t.Fatalf("automation_outputs = %d; a failed run commits none (AUTO-04)", n)
			}
		})
	}
}

// A dry run of each workbench recipe runs no shell() process, starts no
// session and files no ask: its shell and session steps are dry_run and
// nothing waits for the Desktop.
func TestAuto12_DryRunStartsNoSessionOrShell(t *testing.T) {
	for _, slug := range workbenchRecipeSlugs {
		t.Run(slug, func(t *testing.T) {
			w := newWbE2E(t, automations.ShellResult{Stdout: prList})
			id := w.enqueue(t, w.seedRecipe(t, slug), db.TriggerDryRun)
			if r, err := w.e.ExecuteInline(context.Background(), id); err != nil || r.Status != db.RunSucceeded {
				t.Fatalf("dry run = %+v, %v; want succeeded", r, err)
			}
			if n := len(w.shell.Calls()); n != 0 {
				t.Fatalf("shell ran %d commands in a dry run", n)
			}
			pending, err := w.d.PendingAutomationSessionSteps()
			if err != nil || len(pending) != 0 {
				t.Fatalf("pending session steps = %+v, %v; want none", pending, err)
			}
			for _, table := range []string{"terminal_sessions", "owner_asks", "agent_actions", "automation_outputs"} {
				if n := w.count(t, table); n != 0 {
					t.Fatalf("%s = %d rows after a dry run; want none", table, n)
				}
			}
			kinds := w.dryRunStepKinds(t, id)
			wantSessions := 1
			if slug == "pr-review-rounds" {
				wantSessions = 0 // no pull request list in a dry run, so no review session
			}
			if kinds[automations.StepKindShell] != 1 || kinds[automations.StepKindSession] != wantSessions {
				t.Fatalf("steps = %v; want one shell and %d session step", kinds, wantSessions)
			}
		})
	}
}

// dryRunStepKinds counts a dry run's shell and session steps, checking each
// is dry_run and names no session.
func (w *wbE2E) dryRunStepKinds(t *testing.T, runID int64) map[string]int {
	t.Helper()
	kinds := map[string]int{}
	for _, s := range w.steps(t, runID) {
		if s.Kind != automations.StepKindShell && s.Kind != automations.StepKindSession {
			continue
		}
		kinds[s.Kind]++
		if s.Status != automations.StepDryRun || s.SessionID != 0 {
			t.Fatalf("%s step = %s session %d; want dry_run, no session", s.Kind, s.Status, s.SessionID)
		}
	}
	return kinds
}

// manyPRs is gh's JSON for n open pull requests #1..#n, all updated after
// lastRound.
func manyPRs(n int) string {
	items := make([]string, n)
	for i := range items {
		num := strconv.Itoa(i + 1)
		items[i] = `{"number": ` + num + `, "title": "Change ` + num + `", "url": "https://example.com/acme/pull/` + num +
			`", "author": {"login": "colleague-a"}, "updatedAt": "2026-10-14T09:00:00Z"}`
	}
	return "[" + strings.Join(items, ",") + "]"
}

// TestPRReviewRounds_MorePRsThanTheSessionCap: a round with more changed
// pull requests than MaxSessionCalls reviews the first ones and keeps its
// last_round mark, so the next round reviews the rest — every pull request
// gets one session, none two (board #562).
func TestPRReviewRounds_MorePRsThanTheSessionCap(t *testing.T) {
	total := automations.MaxSessionCalls + 2
	w := newWbE2E(t, automations.ShellResult{Stdout: manyPRs(total)})
	a := w.seedRecipe(t, "pr-review-rounds")
	w.setState(t, a, `{"last_round":"`+lastRound+`"}`)

	first := w.enqueue(t, a, db.TriggerSchedule)
	if r := w.drive(t, first); r.Status != db.RunSucceeded {
		t.Fatalf("round 1 = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	if n := len(w.desk.Launches()); n != automations.MaxSessionCalls {
		t.Fatalf("round 1 launched %d sessions; want %d", n, automations.MaxSessionCalls)
	}
	if got, _ := w.state(t, a)["last_round"].(string); got != lastRound {
		t.Fatalf("last_round = %q after a round that left pull requests; want it kept at %s", got, lastRound)
	}
	mustContain(t, "round 1 report", w.onlyReport(t).Body, "2 pull requests left for the next round")

	second := w.enqueue(t, a, db.TriggerSchedule)
	if r := w.drive(t, second); r.Status != db.RunSucceeded {
		t.Fatalf("round 2 = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	seen := map[string]int{}
	for _, l := range w.desk.Launches() {
		seen[strings.SplitN(l.Title, " review", 2)[0]]++
	}
	if len(seen) != total {
		t.Fatalf("reviewed %d distinct pull requests over two rounds (%v); want %d", len(seen), seen, total)
	}
	for title, n := range seen {
		if n != 1 {
			t.Fatalf("%s got %d sessions; want one", title, n)
		}
	}
	st := w.state(t, a)
	if got, _ := st["last_round"].(string); got == "" || !mustParseTime(t, got).After(mustParseTime(t, lastRound)) {
		t.Fatalf("last_round stayed %s after the round that reviewed the rest; want it advanced", got)
	}
	// last_round is round 2's start: only the marks of round 2's reviews
	// (#11, #12) are newer, so round 1's are pruned.
	if rev, _ := st["reviewed"].(map[string]any); len(rev) != 2 || rev["11"] == nil || rev["12"] == nil {
		t.Fatalf("reviewed = %v; want only #11 and #12 once last_round advanced", rev)
	}
}

// prsUpdated is gh's JSON for the pull requests nums, each updated at the
// time in at (default: after lastRound, before the test runs).
func prsUpdated(nums []int, at map[int]string) string {
	items := make([]string, len(nums))
	for i, n := range nums {
		num := strconv.Itoa(n)
		ts := at[n]
		if ts == "" {
			ts = "2026-10-14T09:00:00Z"
		}
		items[i] = `{"number": ` + num + `, "title": "Change ` + num + `", "url": "https://example.com/acme/pull/` + num +
			`", "author": {"login": "colleague-a"}, "updatedAt": "` + ts + `"}`
	}
	return "[" + strings.Join(items, ",") + "]"
}

func prRange(from, to int) []int {
	var out []int
	for n := from; n <= to; n++ {
		out = append(out, n)
	}
	return out
}

// sessionsPerPR counts the review sessions launched per pull request title.
func (w *wbE2E) sessionsPerPR() map[string]int {
	seen := map[string]int{}
	for _, l := range w.desk.Launches() {
		seen[strings.SplitN(strings.TrimPrefix(l.Title, "⚙ "), " review", 2)[0]]++
	}
	return seen
}

// round runs one scheduled round of a over the listed pull requests.
func (w *wbE2E) round(t *testing.T, a db.Automation, list string) {
	t.Helper()
	w.shell.Result = automations.ShellResult{Stdout: list}
	if r := w.drive(t, w.enqueue(t, a, db.TriggerSchedule)); r.Status != db.RunSucceeded {
		t.Fatalf("round = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
}

// TestPRReviewRounds_CarryOverEdgeCases (board #562): while a round leaves
// pull requests for the next one, a reviewed pull request updated after its
// review gets a second session, one that closed loses its mark, and one
// whose session() threw is carried over.
func TestPRReviewRounds_CarryOverEdgeCases(t *testing.T) {
	total := 2*automations.MaxSessionCalls + 2
	t.Run("updated after its review", func(t *testing.T) {
		w := newWbE2E(t, automations.ShellResult{})
		a := w.seedRecipe(t, "pr-review-rounds")
		w.setState(t, a, `{"last_round":"`+lastRound+`"}`)
		w.round(t, a, prsUpdated(prRange(1, total), nil))
		w.round(t, a, prsUpdated(prRange(1, total), map[int]string{3: "2099-01-01T00:00:00Z"}))
		if n := w.sessionsPerPR()["PR #3"]; n != 2 {
			t.Fatalf("PR #3 got %d sessions; want 2 (it changed after its review)", n)
		}
		if n := w.sessionsPerPR()["PR #4"]; n != 1 {
			t.Fatalf("PR #4 got %d sessions; want 1", n)
		}
	})
	t.Run("closed between rounds", func(t *testing.T) {
		w := newWbE2E(t, automations.ShellResult{})
		a := w.seedRecipe(t, "pr-review-rounds")
		w.setState(t, a, `{"last_round":"`+lastRound+`"}`)
		w.round(t, a, prsUpdated(prRange(1, total), nil))
		w.round(t, a, prsUpdated(prRange(2, total), nil)) // #1 closed; #21 and #22 still left over
		rev, _ := w.state(t, a)["reviewed"].(map[string]any)
		if rev["1"] != nil || rev["2"] == nil || rev["20"] == nil || len(rev) != 2*automations.MaxSessionCalls-1 {
			t.Fatalf("reviewed = %v; want #2..#20, without the closed #1", rev)
		}
	})
	t.Run("session() throws", func(t *testing.T) {
		w := newWbE2E(t, automations.ShellResult{})
		w.desk.Outcomes = []automationstest.SessionOutcome{{LaunchFailed: "the workbench folder is gone"}}
		a := w.seedRecipe(t, "pr-review-rounds")
		w.setState(t, a, `{"last_round":"`+lastRound+`"}`)
		w.round(t, a, prsUpdated([]int{1, 2}, nil))
		mustContain(t, "round 1 report", w.onlyReport(t).Body, "#1 Change 1 (https://example.com/acme/pull/1): not started")
		if got, _ := w.state(t, a)["last_round"].(string); got != lastRound {
			t.Fatalf("last_round = %q; want it kept while #1 waits for a retry", got)
		}
		w.round(t, a, prsUpdated([]int{1, 2}, nil))
		if seen := w.sessionsPerPR(); seen["PR #1"] != 2 || seen["PR #2"] != 1 {
			t.Fatalf("sessions = %v; want #1 tried again (2) and #2 once", seen)
		}
	})
}
