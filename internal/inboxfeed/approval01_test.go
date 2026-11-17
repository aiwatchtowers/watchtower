package inboxfeed

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"watchtower/internal/tower/api"
)

// Approval seeds: the needs-approval built-in (automation 10) with one
// succeeded run (10), and helpers for its cards and the approvals.
const (
	seedApprovalsBuiltin = "INSERT INTO automations (id, slug, scope, path, name, enabled, disabled_reason, origin, builtin_id) " +
		"VALUES (10, 'needs-approval', 'personal', '/recipes/needs-approval.md', 'Needs approval', 1, '', 'builtin', 'needs-approval')"
	seedApprovalsRun = "INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (10, 10, 'event', 'succeeded')"
)

// approvalCardSeed is the built-in's living card for key, written at written.
func approvalCardSeed(id int64, key, written string) string {
	return fmt.Sprintf("INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at, output_key, "+
		"content_hash, written_at, changed_at) VALUES (%d, 10, 10, 'inbox', 'Approve %s', 'Approve it.', '%s', '%s', 'h%d', '%s', '%s')",
		id, key, written, key, id, written, written)
}

// actionSeed is a create_target proposal.
func actionSeed(id int64, status, created, decided, applied string) string {
	return fmt.Sprintf("INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at, decided_at, applied_at) "+
		`VALUES (%d, 'create_target', '{"text":"Task %d"}', 'Make task %d', '%s', '%s', '%s', '%s')`,
		id, id, id, status, created, decided, applied)
}

// buildFeed builds the feed of a database seeded with seed at testNow.
func buildFeed(t *testing.T, seed []string, o Options) api.Feed {
	t.Helper()
	d := seeded(t, seed)
	if o.Now.IsZero() {
		o.Now = testNow
	}
	feed, err := Build(context.Background(), d, o)
	if err != nil {
		t.Fatal(err)
	}
	return feed
}

// folderCards are the cards of the folder of kind k.
func folderCards(feed api.Feed, k api.FolderKind) []api.Card {
	var id int64 = -1
	for _, f := range feed.Folders {
		if f.Kind == k {
			id = f.ID
		}
	}
	var out []api.Card
	for _, c := range feed.Cards {
		if c.FolderID == id {
			out = append(out, c)
		}
	}
	return out
}

// picks maps each approval card of Needs approval to whether the recipe's
// card draws it: an artifact card (o…) is the recipe's, a native one not.
func picks(feed api.Feed) map[string]bool {
	out := map[string]bool{}
	for _, c := range folderCards(feed, api.FolderApprovals) {
		switch c.CardKind {
		case api.CardArtifact:
			out[c.Title] = true
		case api.CardApprovalNative, api.CardReminder:
			out[c.Title] = false
		case api.CardNotice, api.CardLegacy:
		}
	}
	return out
}

// APPROVAL-01 (docs/inventory/inbox-folders.md): the recipe off — the
// approval-cards switch off, or the built-in stopped by the daemon — draws
// every open approval natively.
func TestApproval01_NativeCardWhenRecipeOff(t *testing.T) {
	seed := []string{seedApprovalsBuiltin, seedApprovalsRun,
		actionSeed(1, "pending", "2026-11-16T09:00:00Z", "", ""),
		approvalCardSeed(100, "action:1", "2026-11-16T09:01:00Z")}
	on := buildFeed(t, seed, Options{})
	if got := picks(on); len(got) != 1 || !got["Make task 1"] {
		t.Fatalf("control: on and current → the recipe's card, got %v", got)
	}
	off := buildFeed(t, seed, Options{DisabledFeatures: []string{approvalsFeatureID}})
	if got := picks(off); len(got) != 1 || got["Make task 1"] {
		t.Fatalf("the feature off → the native card, got %v", got)
	}
	for _, c := range folderCards(off, api.FolderApprovals) {
		if c.CardKind != api.CardApprovalNative {
			t.Errorf("feature off: card %s is %s, want approval_native", c.ID, c.CardKind)
		}
	}
	stopped := buildFeed(t, append(seed, "UPDATE automations SET disabled_reason = 'the run would not end' WHERE id = 10"),
		Options{})
	if got := picks(stopped); len(got) != 1 || got["Make task 1"] {
		t.Fatalf("stopped by the daemon → native, got %v", got)
	}
}

// APPROVAL-01: a card behind its approval's last change, an approval with
// no card yet, a reminder that came due after its card, and every approval
// after a failed run draw natively.
func TestApproval01_NativeCardWhenBehind(t *testing.T) {
	seed := []string{seedApprovalsBuiltin, seedApprovalsRun,
		// Failed after its card was written: the card is behind.
		"INSERT INTO agent_actions (id, tool, args_json, reason, status, error, created_at, decided_at, applied_at) " +
			`VALUES (1, 'create_target', '{}', 'Behind', 'failed', 'the team was archived', '2026-11-06T09:00:00Z', ` +
			`'2026-11-06T09:05:00Z', '2026-11-06T09:06:00Z')`,
		approvalCardSeed(100, "action:1", "2026-11-06T09:01:00Z"),
		// New since the last run: no card yet.
		"INSERT INTO agent_actions (id, tool, args_json, reason, created_at) VALUES (2, 'create_target', '{}', 'New', '2026-11-06T09:30:00Z')",
		// A due reminder whose card predates its due time.
		"INSERT INTO reminders (id, message_ref, note, remind_at, status, created_at) " +
			"VALUES (1, 'C1@1', 'call back', '2026-11-06T09:50:00Z', 'pending', '2026-11-06T08:00:00Z')",
		approvalCardSeed(101, "reminder:1", "2026-11-06T08:01:00Z")}
	behind := buildFeed(t, seed, Options{})
	want := map[string]bool{"Behind": false, "New": false, "call back": false}
	if got := picks(behind); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("behind: got %v, want %v", got, want)
	}
	failed := buildFeed(t, []string{seedApprovalsBuiltin,
		"INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (10, 10, 'event', 'failed')",
		actionSeed(1, "pending", "2026-11-06T09:00:00Z", "", ""),
		approvalCardSeed(100, "action:1", "2026-11-06T09:01:00Z")}, Options{})
	if got := picks(failed); len(got) != 1 || got["Make task 1"] {
		t.Fatalf("the last run failed → native, got %v", got)
	}
}

// APPROVAL-01: a closed approval's living card — an applied action's, a
// done reminder's — is drawn in no folder and counted in none.
func TestApproval01_ClosedNeverDrawn(t *testing.T) {
	feed := buildFeed(t, []string{seedApprovalsBuiltin, seedApprovalsRun,
		actionSeed(1, "applied", "2026-11-06T09:00:00Z", "2026-11-06T09:02:00Z", "2026-11-06T09:03:00Z"),
		approvalCardSeed(100, "action:1", "2026-11-06T09:04:00Z"),
		"INSERT INTO reminders (id, message_ref, note, remind_at, status, created_at) " +
			"VALUES (1, 'C1@1', 'call back', '2026-11-06T09:00:00Z', 'done', '2026-11-06T08:00:00Z')",
		approvalCardSeed(101, "reminder:1", "2026-11-06T09:04:00Z")}, Options{})
	for _, c := range feed.Cards {
		if c.ID == OutputCardID(100) || c.ID == OutputCardID(101) || strings.HasPrefix(c.ID, "a") ||
			strings.HasPrefix(c.ID, "r") {
			t.Errorf("closed approval drawn: %s in folder %d", c.ID, c.FolderID)
		}
	}
	for _, f := range feed.Folders {
		if f.Count != 0 || f.Waiting != 0 {
			t.Errorf("folder %s counts %d (waiting %d), want 0", f.Slug, f.Count, f.Waiting)
		}
	}
}
