package builtin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
)

// approvalsFixture is testdata/open_approvals.json, the open set Go's
// approvals.list and the Desktop's InboxRefState agree on.
type approvalsFixture struct {
	Now     string `json:"now"`
	Actions []struct {
		ID          int64  `json:"id"`
		Tool        string `json:"tool"`
		ArgsJSON    string `json:"args_json"`
		Status      string `json:"status"`
		Error       string `json:"error"`
		Surface     string `json:"surface"`
		ContextType string `json:"context_type"`
		ContextID   string `json:"context_id"`
		CreatedAt   string `json:"created_at"`
		DecidedAt   string `json:"decided_at"`
		AppliedAt   string `json:"applied_at"`
		DismissedAt string `json:"dismissed_at"`
	} `json:"actions"`
	Reminders []struct {
		ID         int64  `json:"id"`
		MessageRef string `json:"message_ref"`
		Note       string `json:"note"`
		RemindAt   string `json:"remind_at"`
		Status     string `json:"status"`
		CreatedAt  string `json:"created_at"`
	} `json:"reminders"`
	Open []string `json:"open"`
}

// loadApprovalsFixture inserts the fixture's rows as they are (raw SQL: no
// approval hook fires) and returns it with its now.
func loadApprovalsFixture(t *testing.T, d *db.DB) (approvalsFixture, time.Time) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "open_approvals.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fx approvalsFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	for _, a := range fx.Actions {
		if _, err := d.Exec(`INSERT INTO agent_actions (id, tool, args_json, status, error, surface, context_type, context_id,
			created_at, decided_at, applied_at, dismissed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			a.ID, a.Tool, a.ArgsJSON, a.Status, a.Error, a.Surface, a.ContextType, a.ContextID,
			a.CreatedAt, a.DecidedAt, a.AppliedAt, a.DismissedAt); err != nil {
			t.Fatal(err)
		}
	}
	for _, r := range fx.Reminders {
		if _, err := d.Exec(`INSERT INTO reminders (id, message_ref, note, remind_at, status, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
			r.ID, r.MessageRef, r.Note, r.RemindAt, r.Status, r.CreatedAt); err != nil {
			t.Fatal(err)
		}
	}
	now, err := time.Parse(time.RFC3339, fx.Now)
	if err != nil {
		t.Fatal(err)
	}
	return fx, now
}

// listApprovals calls approvals.list over d at now.
func listApprovals(t *testing.T, d *db.DB, now time.Time) map[string]any {
	t.Helper()
	fn := ApprovalsPrimitives(d, func() time.Time { return now })[automations.PrimitiveApprovalsList]
	res, err := fn(context.Background(), automations.PrimitiveCall{Name: automations.PrimitiveApprovalsList, BuiltinID: NeedsApprovalID})
	if err != nil {
		t.Fatalf("approvals.list: %v", err)
	}
	if res.Status != "done" {
		t.Fatalf("status = %q", res.Status)
	}
	return res.Fields
}

func approvalKeys(fields map[string]any) []string {
	var keys []string
	for _, it := range fields["approvals"].([]any) {
		keys = append(keys, it.(map[string]any)["key"].(string))
	}
	return keys
}

// artifacts maps each needs-approval inbox artifact's key to its row.
func (f *fixture) artifacts(t *testing.T) map[string]db.AutomationOutput {
	t.Helper()
	id := f.rowOf(t, NeedsApprovalID).ID
	all, err := f.d.ListAutomationOutputs("inbox", 0)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]db.AutomationOutput{}
	for _, o := range all {
		if o.AutomationID == id {
			out[o.OutputKey] = o
		}
	}
	return out
}

func sortedKeys(m map[string]db.AutomationOutput) []string {
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

// runNeedsApproval runs the built-in once at the clock's now and wants it
// succeeded.
func (f *fixture) runNeedsApproval(t *testing.T) *db.AutomationRun {
	t.Helper()
	run := f.runOnce(t, NeedsApprovalID)
	if run.Status != db.RunSucceeded {
		t.Fatalf("run = %s (%s)", run.Status, run.Error)
	}
	return run
}

// drift is ApprovalDriftOf as the daemon's sweep reads it at the clock's now.
func (f *fixture) drift(t *testing.T) db.ApprovalDrift {
	t.Helper()
	d, err := f.d.ApprovalDriftOf(context.Background(), f.rowOf(t, NeedsApprovalID).ID, f.clock.Now(), automations.MaxOutputsPerRun)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// The shipped recipe parses as a built-in on the approval trigger, keeps
// living artifacts with concurrency 1, asks only for approvals.list and
// calls no model.
func TestNeedsApproval_ShippedRecipe(t *testing.T) {
	e, ok := Lookup(NeedsApprovalID)
	if !ok {
		t.Fatal("no needs-approval entry")
	}
	r, err := ParseShipped(e)
	if err != nil {
		t.Fatal(err)
	}
	if r.Trigger.Kind != automations.TriggerEvent || r.Trigger.Event.Type != automations.ApprovalEvent || len(r.Trigger.Event.Where) != 0 {
		t.Errorf("trigger = %+v", r.Trigger)
	}
	if r.Concurrency != 1 || r.Artifacts != automations.ArtifactsLiving || !slices.Equal(r.Outputs, []string{"inbox"}) {
		t.Errorf("concurrency %d artifacts %q outputs %v", r.Concurrency, r.Artifacts, r.Outputs)
	}
	if !slices.Equal(r.Permissions, []string{"builtin:" + automations.PrimitiveApprovalsList}) {
		t.Errorf("permissions = %v", r.Permissions)
	}
	if n := automations.LLMCallSites(r.Script); n != 0 {
		t.Errorf("LLMCallSites = %d, want none", n)
	}
	if e.Slot != "" || e.DefaultFolder != NeedsApprovalID || !slices.Equal(e.FeatureIDs, []string{"approval-cards"}) || !e.RunNow {
		t.Errorf("entry = slot %q folder %q features %v run now %v", e.Slot, e.DefaultFolder, e.FeatureIDs, e.RunNow)
	}
}

// The shared fixture's open set, in approvals.list's order; nothing to
// remove before any run.
func TestApprovalsList_FixtureOpenSet(t *testing.T) {
	d := db.OpenTestDB(t)
	fx, now := loadApprovalsFixture(t, d)
	fields := listApprovals(t, d, now)
	if got := approvalKeys(fields); !slices.Equal(got, fx.Open) {
		t.Errorf("open = %v, want %v", got, fx.Open)
	}
	if fields["count"] != len(fx.Open) || fields["truncated"] != false || len(fields["remove"].([]any)) != 0 {
		t.Errorf("count %v truncated %v remove %v", fields["count"], fields["truncated"], fields["remove"])
	}
	// The same set the sweep compares with: every one missing, nothing closed.
	if drift, err := d.ApprovalDriftOf(context.Background(), 0, now, automations.MaxOutputsPerRun); err != nil ||
		drift.Missing != len(fx.Open) || drift.Closed != 0 {
		t.Errorf("drift = %+v, %v", drift, err)
	}
}

// What each approval carries: the reminder's note, Slack link and due time;
// a failed action's error as its danger line; an action whose args are not
// JSON drawn with its tool's title, not dropped.
func TestApprovalsList_ItemFields(t *testing.T) {
	d := db.OpenTestDB(t)
	_, now := loadApprovalsFixture(t, d)
	items := map[string]map[string]any{}
	for _, it := range listApprovals(t, d, now)["approvals"].([]any) {
		m := it.(map[string]any)
		items[m["key"].(string)] = m
	}
	r := items["reminder:1"]
	if r["title"] != "Reminder" || r["text"] != "Call colleague A back" || r["kind"] != "reminder" || r["id"] != int64(1) ||
		r["link"] != "https://slack.com/archives/C0ACME01/p1740000000000100" || r["detail"] != "Due 2026-10-22T08:30:00Z" {
		t.Errorf("reminder:1 = %v", r)
	}
	a := items["action:1"]
	if a["title"] != "Create target" || a["text"] != "Draft the Q4 plan for acme" || a["line"] != "Draft the Q4 plan for acme" ||
		a["tone"] != "" || a["changed_at"] != "2026-10-22T07:00:00Z" {
		t.Errorf("action:1 = %v", a)
	}
	failed := items["action:6"]
	if failed["tone"] != "danger" || failed["detail"] != "Failed: jira: 500" || failed["text"] != "Fix the login page" ||
		failed["changed_at"] != "2026-10-22T07:12:00Z" {
		t.Errorf("action:6 = %v", failed)
	}
	broken := items["action:12"]
	if broken["title"] != "Create target" || broken["line"] != "Create target" || broken["text"] != "" {
		t.Errorf("action:12 = %v", broken)
	}
}

// Degenerate input: no approvals at all, and only reminders not due yet.
func TestApprovalsList_NothingOpen(t *testing.T) {
	d := db.OpenTestDB(t)
	now := testStart
	if _, err := d.InsertReminder(db.Reminder{Note: "later", RemindAt: now.Add(time.Hour).Format(time.RFC3339)}); err != nil {
		t.Fatal(err)
	}
	fields := listApprovals(t, d, now)
	if len(fields["approvals"].([]any)) != 0 || fields["count"] != 0 || len(fields["remove"].([]any)) != 0 {
		t.Errorf("fields = %v", fields)
	}
}

// A run writes exactly the open keys, each a heading, the summary or note,
// one list row with its ref, and the reminder's link; the sweep then finds
// no drift.
func TestNeedsApproval_RunWritesOpenKeysWithRefRows(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	fx, now := loadApprovalsFixture(t, f.d)
	f.clock.Set(now.Add(time.Second)) // the cards are written after the last change
	f.runNeedsApproval(t)

	arts := f.artifacts(t)
	want := slices.Clone(fx.Open)
	slices.Sort(want)
	if got := sortedKeys(arts); !slices.Equal(got, want) {
		t.Fatalf("artifacts = %v, want %v", got, want)
	}
	for key, o := range arts {
		kind, id, err := db.ParseApprovalRef(key)
		if err != nil {
			t.Fatal(err)
		}
		doc, err := blocks.Decode(o.BlocksJSON)
		if err != nil {
			t.Fatalf("%s: blocks %v", key, err)
		}
		var refs []blocks.Ref
		for _, b := range doc.Blocks {
			if b.List == nil {
				continue
			}
			for _, r := range b.List.Rows {
				if r.Ref != nil {
					refs = append(refs, *r.Ref)
				}
			}
		}
		if len(refs) != 1 || refs[0].Kind != kind || refs[0].ID != id {
			t.Errorf("%s: refs = %+v", key, refs)
		}
	}
	if r := arts["reminder:1"]; r.Title != "Reminder" || !strings.Contains(r.BlocksJSON, "https://slack.com/archives/C0ACME01/p1740000000000100") ||
		!strings.Contains(r.BlocksJSON, "Call colleague A back") {
		t.Errorf("reminder:1 = %q %s", r.Title, r.BlocksJSON)
	}
	if a := arts["action:12"]; a.Title != "Create target" {
		t.Errorf("action:12 title = %q", a.Title)
	}
	if drift := f.drift(t); drift.Any() {
		t.Errorf("drift after the run = %+v, want none", drift)
	}
}

// A second run after one approval closes removes its card; the others are
// rewritten byte-identical (their content did not change, so changed_at
// stays) and the sweep finds no drift.
func TestNeedsApproval_ClosedApprovalLeavesOthersUnchanged(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	_, now := loadApprovalsFixture(t, f.d)
	f.clock.Set(now.Add(time.Second))
	f.runNeedsApproval(t)
	before := f.artifacts(t)

	if _, err := f.d.Exec(`UPDATE agent_actions SET status = 'approved', decided_at = ? WHERE id = 1`, now.Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	f.clock.Set(now.Add(time.Minute))
	f.runNeedsApproval(t)
	after := f.artifacts(t)

	if _, ok := after["action:1"]; ok {
		t.Error("the approved action's card is still there")
	}
	if len(after) != len(before)-1 {
		t.Errorf("artifacts = %v, want %d", sortedKeys(after), len(before)-1)
	}
	for key, o := range after {
		b := before[key]
		if o.BlocksJSON != b.BlocksJSON || o.Title != b.Title || o.ContentHash != b.ContentHash || !o.ChangedAt.Equal(b.ChangedAt) {
			t.Errorf("%s changed: %s → %s (changed_at %v → %v)", key, b.BlocksJSON, o.BlocksJSON, b.ChangedAt, o.ChangedAt)
		}
	}
	if drift := f.drift(t); drift.Any() {
		t.Errorf("drift = %+v, want none", drift)
	}
}

// With nothing open every earlier card goes, also one the run never wrote
// (an artifact of a closed approval left from elsewhere), and the run writes
// no card.
func TestNeedsApproval_NothingOpenRemovesEveryCard(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	_, now := loadApprovalsFixture(t, f.d)
	f.clock.Set(now.Add(time.Second))
	first := f.runNeedsApproval(t)
	if _, err := f.d.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, output_key)
		VALUES (?, ?, 'inbox', 'Old', '', 'action:999')`, f.rowOf(t, NeedsApprovalID).ID, first.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Exec(`UPDATE agent_actions SET status = 'rejected'`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Exec(`UPDATE reminders SET status = 'done'`); err != nil {
		t.Fatal(err)
	}
	f.clock.Set(now.Add(time.Minute))
	run := f.runNeedsApproval(t)
	if arts := f.artifacts(t); len(arts) != 0 {
		t.Errorf("artifacts = %v, want none", sortedKeys(arts))
	}
	written, err := f.d.ListAutomationOutputsForRun(run.ID, 0)
	if err != nil || len(written) != 0 {
		t.Errorf("the run wrote %d cards (%v), want none", len(written), err)
	}
	if drift := f.drift(t); drift.Any() {
		t.Errorf("drift = %+v, want none", drift)
	}
}

// 51 open approvals: the run writes the 50 oldest, and the sweep — which
// expects only those — finds no drift.
func TestNeedsApproval_51OpenWritesThe50Oldest(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	base := testStart.Add(-2 * time.Hour)
	for i := range 51 {
		if _, err := f.d.Exec(`INSERT INTO agent_actions (tool, args_json, created_at) VALUES ('create_target', ?, ?)`,
			fmt.Sprintf(`{"text":"task %d"}`, i), base.Add(time.Duration(i)*time.Minute).Format(time.RFC3339)); err != nil {
			t.Fatal(err)
		}
	}
	f.runNeedsApproval(t)
	arts := f.artifacts(t)
	if len(arts) != automations.MaxOutputsPerRun {
		t.Fatalf("artifacts = %d, want %d", len(arts), automations.MaxOutputsPerRun)
	}
	if _, ok := arts["action:51"]; ok {
		t.Error("the newest approval got a card; the 50 oldest should")
	}
	if _, ok := arts["action:1"]; !ok {
		t.Error("the oldest approval has no card")
	}
	if drift := f.drift(t); drift.Any() {
		t.Errorf("drift = %+v, want none", drift)
	}
	fields := listApprovals(t, f.d, f.clock.Now())
	if fields["count"] != 51 || fields["truncated"] != true {
		t.Errorf("count %v truncated %v", fields["count"], fields["truncated"])
	}
}

// approvals.list cannot read: the run fails as PrimitiveFailed and every
// earlier card stays byte-identical (AUTO-04; the Desktop then draws the
// native cards).
func TestNeedsApproval_PrimitiveErrorFailsRunKeepsArtifacts(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	_, now := loadApprovalsFixture(t, f.d)
	f.clock.Set(now.Add(time.Second))
	f.runNeedsApproval(t)
	before := f.artifacts(t)

	if _, err := f.d.Exec(`ALTER TABLE reminders RENAME TO reminders_gone`); err != nil {
		t.Fatal(err)
	}
	f.clock.Set(now.Add(time.Minute))
	run := f.runOnce(t, NeedsApprovalID)
	if run.Status != db.RunFailed || !strings.Contains(run.Error, automations.ErrNamePrimitiveFailed) {
		t.Errorf("run = %s (%s), want failed with %s", run.Status, run.Error, automations.ErrNamePrimitiveFailed)
	}
	after := f.artifacts(t)
	if !slices.Equal(sortedKeys(after), sortedKeys(before)) {
		t.Fatalf("artifacts = %v, want %v", sortedKeys(after), sortedKeys(before))
	}
	for key, o := range after {
		b := before[key]
		if o.BlocksJSON != b.BlocksJSON || !o.WrittenAt.Equal(b.WrittenAt) || !o.ChangedAt.Equal(b.ChangedAt) || o.RunID != b.RunID {
			t.Errorf("%s was touched by the failed run", key)
		}
	}
}

// The run's one step is the read, as a tool step with no tokens.
func TestNeedsApproval_ReadIsAToolStepWithNoTokens(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	_, now := loadApprovalsFixture(t, f.d)
	f.clock.Set(now.Add(time.Second))
	run := f.runNeedsApproval(t)
	if run.InputTokens != 0 || run.OutputTokens != 0 {
		t.Errorf("usage = %d/%d, want none", run.InputTokens, run.OutputTokens)
	}
	steps, err := f.d.ListAutomationRunSteps(run.ID)
	if err != nil {
		t.Fatal(err)
	}
	reads := 0
	for _, s := range steps {
		if s.Name == automations.PrimitiveApprovalsList {
			reads++
			if s.Kind != automations.StepKindTool || s.Permission != "builtin:"+automations.PrimitiveApprovalsList {
				t.Errorf("read step = %+v", s)
			}
		}
		if s.Kind == automations.StepKindLLM {
			t.Errorf("an llm step: %+v", s)
		}
	}
	if reads != 1 {
		t.Errorf("approvals.list steps = %d, want 1", reads)
	}
}

// approval-cards off: the built-in is off at its sync and Fire queues
// nothing.
func TestNeedsApproval_FeatureOffQueuesNothing(t *testing.T) {
	f := newFixture(t)
	f.cfg.ApprovalCards.Enabled = false
	f.sync(t)
	if a := f.rowOf(t, NeedsApprovalID); a.Enabled {
		t.Fatal("the built-in row is on with approval-cards off")
	}
	if err := Fire(f.d, "reminder:1", nil); err != nil {
		t.Fatal(err)
	}
	runs, err := f.d.ListAutomationRuns(f.rowOf(t, NeedsApprovalID).ID, 0)
	if err != nil || len(runs) != 0 {
		t.Errorf("runs = %d, %v; want none", len(runs), err)
	}
}

// An owner copy must keep `event: approval` (no where): another trigger is
// the row's parse error, so the copy never runs.
func TestNeedsApproval_CopyMustKeepTheApprovalTrigger(t *testing.T) {
	e, _ := Lookup(NeedsApprovalID)
	for name, trigger := range map[string]string{
		"sync":  "trigger:\n  sync: waiting_for_me\n",
		"where": "trigger:\n  event:\n    type: approval\n    where: {ref: \"action:*\"}\n",
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			data := strings.Replace(string(e.Recipe), "trigger:\n  event:\n    type: approval\n", trigger, 1)
			if data == string(e.Recipe) {
				t.Fatal("the shipped trigger text moved")
			}
			f.writeCopyOf(t, NeedsApprovalID, []byte(data))
			f.sync(t)
			a := f.rowOf(t, NeedsApprovalID)
			if a.ParseError == "" || a.Runnable() {
				t.Errorf("row = parse %q runnable %v; want a parse error", a.ParseError, a.Runnable())
			}
		})
	}
	// The copy that keeps the trigger indexes.
	f := newFixture(t)
	f.writeCopyOf(t, NeedsApprovalID, append(slices.Clone(e.Recipe), []byte("\n<!-- edited -->\n")...))
	f.sync(t)
	if a := f.rowOf(t, NeedsApprovalID); a.ParseError != "" || !a.Overridden {
		t.Errorf("row = parse %q overridden %v", a.ParseError, a.Overridden)
	}
}

// The runner executes inline at a slot; Run Now of a built-in with none is
// refused before anything is queued (its runs are the executor poll's).
func TestRunner_RunNowRefusesASlotlessBuiltin(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	_, err := f.runner.RunNow(context.Background(), NeedsApprovalID, automations.BuiltinInput{})
	if !errors.Is(err, ErrNoSlot) {
		t.Fatalf("RunNow(needs-approval) = %v; want ErrNoSlot", err)
	}
	runs, err := f.d.ListAutomationRuns(f.rowOf(t, NeedsApprovalID).ID, 0)
	if err != nil || len(runs) != 0 {
		t.Errorf("runs = %d, %v; want none queued", len(runs), err)
	}
}

// 50 approvals with the longest words a row can carry — Cyrillic text,
// error, reason and run label — stay under the SDK result cap: the shipped
// recipe's run succeeds and every approval still gets its card.
func TestNeedsApproval_LongApprovalsStayUnderTheResultCap(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	long := strings.Repeat("Длинный текст предложения для acme. ", 200) // ~7000 runes, ~13 KB
	base := testStart.Add(-2 * time.Hour)
	for i := range automations.MaxOutputsPerRun {
		status, errText := "pending", ""
		if i%2 == 1 {
			status, errText = "failed", long
		}
		args, err := json.Marshal(map[string]string{"text": long})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.d.Exec(`INSERT INTO agent_actions (tool, args_json, status, error, reason, context_type, context_id, created_at)
			VALUES ('create_target', ?, ?, ?, ?, 'automation_run', '7', ?)`,
			string(args), status, errText, long, base.Add(time.Duration(i)*time.Minute).Format(time.RFC3339)); err != nil {
			t.Fatal(err)
		}
	}
	fields := listApprovals(t, f.d, f.clock.Now())
	raw, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) > automations.MaxSDKResultBytes/2 {
		t.Errorf("approvals.list is %d bytes; want well under the %d-byte cap", len(raw), automations.MaxSDKResultBytes)
	}
	f.runNeedsApproval(t)
	arts := f.artifacts(t)
	for i := 1; i <= automations.MaxOutputsPerRun; i++ {
		if _, ok := arts[db.ActionRef(int64(i))]; !ok {
			t.Errorf("approval %d has no card", i)
		}
	}
}
