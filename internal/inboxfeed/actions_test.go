package inboxfeed

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// actionsCard seeds an owner automation (1, its recipe state set by
// automation) and one card with actionsJSON, and returns its actions.
func actionsCard(t *testing.T, automation, actionsJSON string, extra ...string) []api.CardAction {
	t.Helper()
	seed := append([]string{
		"INSERT INTO automations (id, slug, scope, path, name, enabled, parse_error, confirmed_hash, approval_hash) " +
			"VALUES (1, 'a', 'personal', '/recipes/a.md', 'A', " + automation + ")",
		"INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')",
		"INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (7, 1, 'button', 'succeeded')",
		"INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at, actions_json) " +
			"VALUES (1, 1, 1, 'inbox', 'Card', 'Body', '2026-11-16T08:00:00Z', '" + actionsJSON + "')",
	}, extra...)
	feed := buildFeed(t, seed, Options{})
	return cardByID(t, feed, OutputCardID(1)).Actions
}

const runnable = "1, '', 'h', 'h'"

// Each kind draws as the Mac draws it: a web link enabled, a screen link
// the Mac's alone, chat and agent handoffs the Mac's, a reply enabled while
// its recipe runs; an action the Mac cannot draw is left out and the
// others keep their press index.
func TestActions_StatesByKind(t *testing.T) {
	got := actionsCard(t, runnable, `[`+
		`{"label":"Open","kind":"link","open":"https://example.com/x"},`+
		`{"label":"Screen","kind":"link","open":"watchtower-nav://tracks"},`+
		`{"label":"Bad","kind":"link","open":"ftp://example.com"},`+
		`{"label":"","kind":"chat","chat":"x"},`+
		`{"label":"Discuss","kind":"chat","chat":"Talk"},`+
		`{"label":"Agent","kind":"agent","agent":{"task":"Do"}},`+
		`{"label":"Yes","kind":"reply","reply":"yes"}]`)
	want := fmt.Sprint([]api.CardAction{
		{Index: 0, Kind: "link", Label: "Open", State: api.ActionEnabled},
		{Index: 1, Kind: "link", Label: "Screen", State: api.ActionMacOnly},
		{Index: 2, Kind: "link", Label: "Bad", State: api.ActionDisabled},
		{Index: 4, Kind: "chat", Label: "Discuss", State: api.ActionMacOnly},
		{Index: 5, Kind: "agent", Label: "Agent", State: api.ActionMacOnly},
		{Index: 6, Kind: "reply", Label: "Yes", State: api.ActionEnabled, Detail: replyReady},
	})
	if fmt.Sprint(got) != want {
		t.Errorf("actions %v\nwant    %v", got, want)
	}
}

// The Reply buttons follow InboxCardAction.replyState: pressed once one
// was ("Sent — run #N" on the pressed one), disabled once the recipe is
// removed, enabled with a caption while it needs confirmation or is off.
func TestActions_ReplyStates(t *testing.T) {
	two := `[{"label":"Yes","kind":"reply","reply":"y"},{"label":"No","kind":"reply","reply":"n"}]`
	sent := actionsCard(t, runnable, two, "UPDATE automation_outputs SET pressed_action = 1, pressed_run_id = 7 WHERE id = 1")
	if sent[0].State != api.ActionPressed || sent[0].Label != "Yes" || sent[1].Label != "Sent — run #7" ||
		sent[1].Detail != replySent {
		t.Errorf("sent %+v", sent)
	}
	for _, c := range []struct {
		automation, detail, note string
		state                    api.ActionState
	}{
		{"1, '', 'h', 'old'", replyNeedsConfirmation, "Needs confirmation", api.ActionEnabled},
		{"0, '', 'h', 'h'", replyOff, "Off", api.ActionEnabled},
		{"1, 'bad yaml', 'h', 'h'", replyUnreadable, "Recipe can't be read", api.ActionEnabled},
	} {
		got := actionsCard(t, c.automation, two)
		if got[0].Detail != c.detail || got[0].Note != c.note || got[0].State != c.state {
			t.Errorf("%s: %+v", c.detail, got[0])
		}
	}
	removed := actionsCard(t, runnable, two, "UPDATE automations SET removed_at = '2026-11-16T09:00:00Z' WHERE id = 1")
	if removed[0].State != api.ActionDisabled || removed[0].Note != "Recipe removed" {
		t.Errorf("removed %+v", removed[0])
	}
}

// A target button's state is its newest proposal's
// (TargetButtonStateResolver): waiting, creating for two minutes after the
// decision and stuck after, created while its task exists, failed with the
// row's error.
func TestActions_TargetStates(t *testing.T) {
	action := db.InboxAction{Label: "Make a task", Kind: "target", Target: &db.InboxTargetAction{Title: "Fix it"}}
	ctxID := fmt.Sprintf("1:0:%s", blocks.ActionHash(action))
	actions := `[{"label":"Make a task","kind":"target","target":{"title":"Fix it"}}]`
	proposal := func(id int, status, decided, errText string) string {
		return fmt.Sprintf("INSERT INTO agent_actions (id, tool, args_json, status, context_type, context_id, created_at, "+
			"decided_at, error) VALUES (%d, 'create_target', '{}', '%s', 'automation_output', '%s', '2026-11-16T09:00:00Z', "+
			"'%s', '%s')", id, status, ctxID, decided, errText)
	}
	recent := testNow.Add(-time.Minute).Format(time.RFC3339)
	for _, c := range []struct {
		name, detail, note string
		state              api.ActionState
		seed               []string
	}{
		{"idle", targetIdle, "", api.ActionEnabled, nil},
		{"waiting", targetWaiting, "", api.ActionPressed, []string{proposal(1, "pending", "", "")}},
		{"creating", targetCreating, "", api.ActionPressed, []string{proposal(1, "approved", recent, "")}},
		{"stuck", targetStuck, "", api.ActionEnabled, []string{proposal(1, "executing", "2026-11-16T09:00:00Z", "")}},
		{"created", targetCreated, "", api.ActionPressed, []string{proposal(1, "applied", "2026-11-16T09:00:00Z", ""),
			"INSERT INTO targets (id, text, period_start, period_end, source_type, source_id) VALUES (1, 'Fix it', '2026-11-16', '2026-11-16', 'chat', 'action:1')"}},
		{"applied without its task", targetIdle, "", api.ActionEnabled, []string{proposal(1, "applied", "2026-11-16T09:00:00Z", "")}},
		{"failed", targetFailed, "boom", api.ActionEnabled, []string{proposal(1, "failed", "2026-11-16T09:00:00Z", "boom")}},
		{"newest wins", targetWaiting, "", api.ActionPressed, []string{proposal(1, "failed", "", "boom"), proposal(2, "pending", "", "")}},
	} {
		got := actionsCard(t, runnable, actions, c.seed...)
		if len(got) != 1 || got[0].Detail != c.detail || got[0].Note != c.note || got[0].State != c.state {
			t.Errorf("%s: %+v", c.name, got)
		}
		wantUntil := ""
		if c.detail == targetCreating {
			wantUntil = testNow.Add(-time.Minute + targetStuckAfter).Format(time.RFC3339)
		}
		if len(got) == 1 && got[0].Until != wantUntil {
			t.Errorf("%s: until %q, want %q", c.name, got[0].Until, wantUntil)
		}
	}
}

const targetButtonPath = "testdata/target_button_cases.json"

// targetButtonCase is one case of the shared target button fixture: the
// newest proposal of a button's context (or none) and whether its task
// exists, at now, and the state the Mac draws (TargetButtonStateResolver).
// The app target's ApprovalTextParityTests runs the Swift resolver over
// the same cases.
type targetButtonCase struct {
	Name     string `json:"name"`
	Now      string `json:"now"`
	Proposal *struct {
		Status      string `json:"status"`
		DecidedAt   string `json:"decided_at"`
		DismissedAt string `json:"dismissed_at"`
		Error       string `json:"error"`
	} `json:"proposal"`
	TaskExists bool `json:"task_exists"`
	Expect     struct {
		Detail string `json:"detail"`
		Note   string `json:"note"`
	} `json:"expect"`
}

// TestTargetState_SharedCases: targetState equals every case's expect;
// -update rewrites the expects.
func TestTargetState_SharedCases(t *testing.T) {
	b, err := os.ReadFile(targetButtonPath)
	if err != nil {
		t.Fatal(err)
	}
	var cases []targetButtonCase
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	for i, c := range cases {
		now, err := time.Parse(time.RFC3339, c.Now)
		if err != nil {
			t.Fatal(err)
		}
		f := targetFacts{taskExists: c.TaskExists}
		if p := c.Proposal; p != nil {
			f.proposal = &db.AgentAction{Status: p.Status, DecidedAt: p.DecidedAt, DismissedAt: p.DismissedAt, Error: p.Error}
		}
		detail, note := targetState(f, now)
		if *update {
			cases[i].Expect.Detail, cases[i].Expect.Note = detail, note
			continue
		}
		if detail != c.Expect.Detail || note != c.Expect.Note {
			t.Errorf("%s: got %s %q, want %s %q", c.Name, detail, note, c.Expect.Detail, c.Expect.Note)
		}
	}
	if *update {
		out, err := json.MarshalIndent(cases, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(targetButtonPath, append(out, '\n'), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}
