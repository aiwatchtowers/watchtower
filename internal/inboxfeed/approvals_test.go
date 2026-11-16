package inboxfeed

import (
	"fmt"
	"testing"

	"watchtower/internal/tools"
	"watchtower/internal/tower/api"
)

func approvalsFolder(feed api.Feed) api.Folder {
	for _, f := range feed.Folders {
		if f.Kind == api.FolderApprovals {
			return f
		}
	}
	return api.Folder{}
}

func cardIDs(cards []api.Card) []string {
	out := make([]string, 0, len(cards))
	for _, c := range cards {
		out = append(out, c.ID)
	}
	return out
}

// The run writes the 50 oldest approvals; the rest have no card and draw
// natively, above the recipe's, so none is hidden by the cap.
func TestNeedsApproval_MoreThanFiftyFallsBackToNative(t *testing.T) {
	seed := []string{seedApprovalsBuiltin, seedApprovalsRun}
	for id := int64(1); id <= 51; id++ {
		created := fmt.Sprintf("2026-11-16T09:%02d:00Z", id)
		seed = append(seed, actionSeed(id, "pending", created, "", ""))
		if id <= 50 {
			seed = append(seed, approvalCardSeed(100+id, fmt.Sprintf("action:%d", id), "2026-11-16T10:00:00Z"))
		}
	}
	feed := buildFeed(t, seed, Options{})
	cards := folderCards(feed, api.FolderApprovals)
	if len(cards) != 51 {
		t.Fatalf("got %d cards, want 51", len(cards))
	}
	if cards[0].ID != ActionCardID(51) || cards[0].CardKind != api.CardApprovalNative {
		t.Errorf("first card %s (%s), want the 51st natively", cards[0].ID, cards[0].CardKind)
	}
	for i, c := range cards[1:] {
		if c.ID != OutputCardID(int64(101+i)) {
			t.Errorf("card %d is %s, want the recipe's o%d", i+1, c.ID, 101+i)
		}
	}
	if f := approvalsFolder(feed); f.Count != 51 || f.Waiting != 51 {
		t.Errorf("Needs approval counts %d, waiting %d; want 51, 51", f.Count, f.Waiting)
	}
}

// Needs approval's order (InboxFolderEntries.approvals): the built-in
// upgrade notices, the native cards, the recipe's cards (each half oldest
// created first, actions before reminders on a tie), then the settled rows.
func TestNeedsApproval_MixedOrderMatchesSwift(t *testing.T) {
	feed := buildFeed(t, []string{seedApprovalsBuiltin, seedApprovalsRun,
		"INSERT INTO builtin_migrations (builtin_id, status, error, attempts, updated_at) " +
			"VALUES ('reactions', 'failed', 'could not move', 1, '2026-11-10T07:00:00Z')",
		actionSeed(1, "pending", "2026-11-16T08:00:00Z", "", ""),
		approvalCardSeed(101, "action:1", "2026-11-16T08:30:00Z"),
		actionSeed(2, "pending", "2026-11-16T09:00:00Z", "", ""),
		"INSERT INTO reminders (id, note, remind_at, created_at) VALUES (1, 'Call back', '2026-11-16T11:00:00Z', '2026-11-16T09:00:00Z')",
		approvalCardSeed(102, "reminder:1", "2026-11-16T11:30:00Z"),
		actionSeed(3, "pending", "2026-11-16T07:00:00Z", "", ""),
		actionSeed(4, "approved", "2026-11-16T06:00:00Z", "2026-11-16T06:10:00Z", ""),
	}, Options{})
	got := fmt.Sprint(cardIDs(folderCards(feed, api.FolderApprovals)))
	if want := "[n1 a3 a2 o101 o102 a4]"; got != want {
		t.Errorf("order %s, want %s", got, want)
	}
}

// APPROVAL-01's 2026-11-10 amendment: an approved or executing row stays
// on its native card below the open ones and is never counted.
func TestNeedsApproval_SettledRowsShownUncounted(t *testing.T) {
	feed := buildFeed(t, []string{seedApprovalsBuiltin, seedApprovalsRun,
		actionSeed(1, "pending", "2026-11-16T08:00:00Z", "", ""),
		actionSeed(2, "approved", "2026-11-16T09:00:00Z", "2026-11-16T09:01:00Z", ""),
		actionSeed(3, "executing", "2026-11-16T10:00:00Z", "2026-11-16T10:01:00Z", ""),
		actionSeed(4, "applied", "2026-11-16T10:00:00Z", "2026-11-16T10:01:00Z", "2026-11-16T10:02:00Z"),
	}, Options{})
	got := fmt.Sprint(cardIDs(folderCards(feed, api.FolderApprovals)))
	if want := "[a1 a3 a2]"; got != want {
		t.Errorf("cards %s, want %s (open, then settled newest first)", got, want)
	}
	if f := approvalsFolder(feed); f.Count != 1 || f.Waiting != 1 {
		t.Errorf("Needs approval counts %d, waiting %d; want 1, 1", f.Count, f.Waiting)
	}
}

// A native card pins the args it shows: Approval.ArgsSHA256 and the card's
// content hash are the registry's hash of the stored args (ApproveSeen).
func TestNeedsApproval_ArgsSHAIsTheRegistryHash(t *testing.T) {
	args := `{"text":"Task 1"}`
	feed := buildFeed(t, []string{actionSeed(1, "pending", "2026-11-16T08:00:00Z", "", "")}, Options{})
	cards := folderCards(feed, api.FolderApprovals)
	if len(cards) != 1 || cards[0].Approval == nil {
		t.Fatalf("got %+v, want one native card", cards)
	}
	want := tools.ArgsSHA256(args)
	if cards[0].Approval.ArgsSHA256 != want || cards[0].ContentHash != want {
		t.Errorf("args_sha256 %q, content_hash %q; want %q", cards[0].Approval.ArgsSHA256, cards[0].ContentHash, want)
	}
	if a := cards[0].Approval; a.Tool != "create_target" || a.Title != "Create a target" || a.Summary != "Task 1" ||
		a.Status != "pending" || a.Reason != "Make task 1" {
		t.Errorf("approval %+v", *a)
	}
}

// Edit… stays on the Mac: a pending Slack send (its editor), a claude.ai
// connector call (Edit Input) and a save_automation (Open Draft); no other
// tool, and no row past pending.
func TestNeedsApproval_EditOnMacForEditableTools(t *testing.T) {
	row := func(id int64, tool, args, status string) string {
		return fmt.Sprintf("INSERT INTO agent_actions (id, tool, args_json, status, created_at) "+
			"VALUES (%d, '%s', '%s', '%s', '2026-11-16T08:0%d:00Z')", id, tool, args, status, id)
	}
	feed := buildFeed(t, []string{
		row(1, "send_slack_message", `{"text":"hi","target":{"label":"#eng","workspace":"acme"}}`, "pending"),
		row(2, "claude_ai_connector_call", `{"server":"acme","tool":"post","input":{"a":1}}`, "pending"),
		row(3, "save_automation", `{"name":"Digest","slug":"digest"}`, "pending"),
		row(4, "create_target", `{"text":"x"}`, "pending"),
		row(5, "send_slack_message", `{"text":"hi","target":{"label":"#eng"}}`, "failed"),
	}, Options{})
	got := map[string]bool{}
	for _, c := range folderCards(feed, api.FolderApprovals) {
		got[c.ID] = c.Approval.EditOnMac
	}
	want := map[string]bool{"a1": true, "a2": true, "a3": true, "a4": false, "a5": false}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("edit_on_mac %v, want %v", got, want)
	}
}
