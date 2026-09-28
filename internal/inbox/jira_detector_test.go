package inbox

import (
	"context"
	"testing"
	"time"

	"watchtower/internal/db"
)

// seedJiraIssue inserts a jira_issues row assigned to the given account ID.
// updated is used as both updated_at and synced_at, in Jira Cloud's own
// dotted-millisecond format (db.FormatJiraTime) exactly as the real sync
// writes it — the detector's window bound is a plain SQL string compare
// against updated_at, so a differently-formatted fixture would not exercise
// the production comparison.
func seedJiraIssue(t *testing.T, d *db.DB, key, assigneeAccountID string, updated time.Time) {
	t.Helper()
	// jira_issues.account_id references jira_accounts(id); make sure account 1 exists.
	var accounts int
	if err := d.QueryRow(`SELECT COUNT(*) FROM jira_accounts`).Scan(&accounts); err != nil {
		t.Fatalf("seedJiraIssue: counting jira_accounts: %v", err)
	}
	if accounts == 0 {
		db.SeedTestJiraAccount(t, d)
	}
	ts := db.FormatJiraTime(updated.UTC())
	_, err := d.Exec(`INSERT INTO jira_issues
		(account_id, key, id, project_key, summary, status, status_category,
		 assignee_account_id, created_at, updated_at, synced_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
		1, key, key, "WT", "test issue", "In Progress", "in_progress",
		assigneeAccountID, ts, ts, ts)
	if err != nil {
		t.Fatalf("seedJiraIssue: %v", err)
	}
}

func TestJiraDetector_AssignedToMe(t *testing.T) {
	d := testDB(t)
	seedJiraIssue(t, d, "WT-123", "alice", time.Now().Add(-1*time.Hour))

	n, err := DetectJira(context.Background(), d, db.Owner{SlackUserID: "alice"}, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("want 1 new inbox item, got %d", n)
	}
	got := queryInboxByTrigger(t, d, "jira_assigned")
	if len(got) != 1 {
		t.Fatalf("want 1 jira_assigned item, got %d", len(got))
	}
	// SenderUserID stores the issue key as the "sender" for Jira items.
	if got[0].SenderUserID != "WT-123" {
		t.Errorf("expected SenderUserID=WT-123, got %q", got[0].SenderUserID)
	}
	if got[0].ItemClass != "actionable" {
		t.Errorf("expected actionable class, got %q", got[0].ItemClass)
	}
}

func TestJiraDetector_CommentMention_SkippedWithoutMappedAtlassianID(t *testing.T) {
	d := testDB(t)
	// jira_comments is real (migration 00050), but alice has no jira_user_map
	// row — DetectJira cannot resolve her Atlassian account id, so comment
	// mentions stay a graceful no-op (the pre-reconciliation "no schema"
	// no-op is now "no mapped identity").
	seedJiraIssue(t, d, "WT-200", "bob", time.Now().Add(-1*time.Hour))
	seedJiraComment(t, d, "WT-200", "acc-bob", "hey [~acc-alice] please look", time.Now().Add(-30*time.Minute))

	n, err := DetectJira(context.Background(), d, db.Owner{SlackUserID: "alice"}, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	// alice is not the assignee, so no jira_assigned item.
	// jira_comment_mention is a no-op (alice has no mapped Atlassian id).
	if n != 0 {
		t.Errorf("expected 0 items for non-assignee with unmapped identity, got %d", n)
	}
	got := queryInboxByTrigger(t, d, "jira_comment_mention")
	if len(got) != 0 {
		t.Errorf("expected no comment mention items, got %d", len(got))
	}
}

func TestJiraDetector_CommentMention_Detected(t *testing.T) {
	d := testDB(t)
	seedJiraIssue(t, d, "WT-201", "bob", time.Now().Add(-1*time.Hour))
	if err := d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "acc-alice", SlackUserID: "alice", DisplayName: "Alice"}); err != nil {
		t.Fatalf("UpsertJiraUserMap: %v", err)
	}
	seedJiraComment(t, d, "WT-201", "acc-bob", "hey [~acc-alice] please look", time.Now().Add(-30*time.Minute))

	n, err := DetectJira(context.Background(), d, db.Owner{SlackUserID: "alice"}, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 comment mention item, got %d", n)
	}
	got := queryInboxByTrigger(t, d, "jira_comment_mention")
	if len(got) != 1 {
		t.Fatalf("want 1 jira_comment_mention item, got %d", len(got))
	}
	if got[0].SenderUserID != "WT-201" {
		t.Errorf("expected SenderUserID=WT-201, got %q", got[0].SenderUserID)
	}
}

func TestJiraDetector_StatusChange(t *testing.T) {
	// jira_status_change requires jira_issue_history table which does not exist yet.
	// This test documents the no-op behavior until schema v2.
	d := testDB(t)
	seedJiraIssue(t, d, "WT-300", "alice", time.Now().Add(-1*time.Hour))

	n, err := DetectJira(context.Background(), d, db.Owner{SlackUserID: "alice"}, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	// Only jira_assigned fires; no status_change items.
	got := queryInboxByTrigger(t, d, "jira_status_change")
	if len(got) != 0 {
		t.Errorf("expected no status_change items (schema not available), got %d", len(got))
	}
	_ = n
}

func TestJiraDetector_NoDoubleDetection(t *testing.T) {
	d := testDB(t)
	seedJiraIssue(t, d, "WT-1", "alice", time.Now().Add(-1*time.Hour))

	n1, err := DetectJira(context.Background(), d, db.Owner{SlackUserID: "alice"}, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n1 != 1 {
		t.Fatalf("first run: want 1, got %d", n1)
	}

	// Second run with same sinceTS — existing inbox_item blocks re-insert.
	n2, err := DetectJira(context.Background(), d, db.Owner{SlackUserID: "alice"}, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n2 != 0 {
		t.Errorf("second run: expected 0 (no duplicates), got %d", n2)
	}
}

func TestJiraDetector_EmptyUserID(t *testing.T) {
	d := testDB(t)
	n, err := DetectJira(context.Background(), d, db.Owner{}, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("expected 0 for empty userID, got %d", n)
	}
}

func TestJiraDetector_NotMyIssue(t *testing.T) {
	d := testDB(t)
	// Issue assigned to "bob", not "alice"
	seedJiraIssue(t, d, "WT-999", "bob", time.Now().Add(-1*time.Hour))

	n, err := DetectJira(context.Background(), d, db.Owner{SlackUserID: "alice"}, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("expected 0 items (not alice's issue), got %d", n)
	}
}

// Owner.JiraAccountID wins over the Slack-id fallback: an issue assigned to
// the owner's Atlassian id is detected even though the owner also has a Slack
// id that matches nothing in jira_issues.
func TestJiraDetector_AssignedToOwnerJiraAccountID(t *testing.T) {
	d := testDB(t)
	seedJiraIssue(t, d, "WT-7", "acc-alice", time.Now().Add(-1*time.Hour))

	owner := db.Owner{SlackUserID: "1:U_ALICE", JiraAccountID: "acc-alice"}
	n, err := DetectJira(context.Background(), d, owner, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("want 1 jira_assigned item for the owner's Atlassian id, got %d", n)
	}
}

// A Google-only owner has neither a Jira nor a Slack id: the detector skips
// without an error and never matches an unassigned issue (empty assignee).
func TestJiraDetector_NoJiraOrSlackIDSkips(t *testing.T) {
	d := testDB(t)
	seedJiraIssue(t, d, "WT-8", "", time.Now().Add(-1*time.Hour))

	n, err := DetectJira(context.Background(), d, db.Owner{ID: "google:me@x.com", Email: "me@x.com"}, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("an owner with no Jira/Slack id must match nothing, got %d", n)
	}
}

// An assigned issue updated again while its jira_assigned item is still
// pending does not mint a second item; once that item is resolved, the next
// update surfaces a new one.
func TestJiraDetector_AssignedDedupesWhilePending(t *testing.T) {
	d := testDB(t)
	owner := db.Owner{JiraAccountID: "acc-alice"}
	since := time.Now().Add(-3 * time.Hour)
	seedJiraIssue(t, d, "WT-5", "acc-alice", time.Now().Add(-2*time.Hour))

	bump := func(updated time.Time) {
		t.Helper()
		if _, err := d.Exec(`UPDATE jira_issues SET updated_at = ? WHERE key = 'WT-5'`,
			db.FormatJiraTime(updated.UTC())); err != nil {
			t.Fatalf("bumping updated_at: %v", err)
		}
	}
	detect := func() {
		t.Helper()
		if _, err := DetectJira(context.Background(), d, owner, since); err != nil {
			t.Fatal(err)
		}
	}

	detect()
	bump(time.Now().Add(-1 * time.Hour))
	detect()
	if got := queryInboxByTrigger(t, d, "jira_assigned"); len(got) != 1 {
		t.Fatalf("two updates while pending: want 1 jira_assigned item, got %d", len(got))
	}

	if _, err := d.Exec(`UPDATE inbox_items SET status = 'resolved' WHERE trigger_type = 'jira_assigned'`); err != nil {
		t.Fatalf("resolving item: %v", err)
	}
	bump(time.Now().Add(-30 * time.Minute))
	detect()
	if got := queryInboxByTrigger(t, d, "jira_assigned"); len(got) != 2 {
		t.Fatalf("an update after the item resolved: want 2 jira_assigned items, got %d", len(got))
	}
}

// A stale-archived jira_assigned item keeps status='pending'
// (db.ArchiveStaleActionable), but it no longer blocks a later update of the
// same issue from surfacing a new item.
func TestJiraDetector_AssignedArchivedPendingDoesNotBlock(t *testing.T) {
	d := testDB(t)
	owner := db.Owner{JiraAccountID: "acc-alice"}
	since := time.Now().Add(-3 * time.Hour)
	seedJiraIssue(t, d, "WT-6", "acc-alice", time.Now().Add(-2*time.Hour))
	if _, err := DetectJira(context.Background(), d, owner, since); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE inbox_items SET archived_at = ?, archive_reason = 'stale'
		WHERE trigger_type = 'jira_assigned'`, time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatalf("archiving item: %v", err)
	}
	if _, err := d.Exec(`UPDATE jira_issues SET updated_at = ? WHERE key = 'WT-6'`,
		db.FormatJiraTime(time.Now().Add(-1*time.Hour).UTC())); err != nil {
		t.Fatalf("bumping updated_at: %v", err)
	}
	if _, err := DetectJira(context.Background(), d, owner, since); err != nil {
		t.Fatal(err)
	}
	if got := queryInboxByTrigger(t, d, "jira_assigned"); len(got) != 2 {
		t.Fatalf("an update after the pending item was archived: want 2 jira_assigned items, got %d", len(got))
	}
}

// The owner's own comment on an assigned issue resolves its jira_assigned item
// (INBOX-02) and also bumps the issue's updated_at. That bump must not mint a
// fresh pending item the next cycle — it would never auto-resolve (the owner's
// latest comment predates it), so answering in the source would bring the
// item back. A later change by someone else still surfaces a new item.
func TestJiraDetector_AssignedOwnCommentDoesNotReMint(t *testing.T) {
	d := testDB(t)
	owner := db.Owner{JiraAccountID: "acc-alice"}
	since := time.Now().Add(-3 * time.Hour)
	seedJiraIssue(t, d, "WT-7", "acc-alice", time.Now().Add(-2*time.Hour))
	detect := func() {
		t.Helper()
		if _, err := DetectJira(context.Background(), d, owner, since); err != nil {
			t.Fatal(err)
		}
	}
	bump := func(updated time.Time) {
		t.Helper()
		if _, err := d.Exec(`UPDATE jira_issues SET updated_at = ? WHERE key = 'WT-7'`,
			db.FormatJiraTime(updated.UTC())); err != nil {
			t.Fatalf("bumping updated_at: %v", err)
		}
	}

	detect()
	if got := queryInboxByTrigger(t, d, "jira_assigned"); len(got) != 1 {
		t.Fatalf("want 1 jira_assigned item, got %d", len(got))
	}

	// The owner answers in Jira: the comment resolves the item and Jira
	// stamps the issue's updated_at a moment after the comment.
	commentAt := time.Now().Add(-40 * time.Minute)
	seedJiraComment(t, d, "WT-7", "acc-alice", "on it", commentAt)
	bump(commentAt.Add(2 * time.Second))
	if _, err := d.Exec(`UPDATE inbox_items SET status = 'resolved' WHERE trigger_type = 'jira_assigned'`); err != nil {
		t.Fatalf("resolving item: %v", err)
	}
	detect()
	if got := queryInboxByTrigger(t, d, "jira_assigned"); len(got) != 1 {
		t.Fatalf("the owner's own comment must not re-mint: want 1 jira_assigned item, got %d", len(got))
	}

	// Someone else changes the issue afterwards: that surfaces again.
	bump(time.Now().Add(-5 * time.Minute))
	detect()
	if got := queryInboxByTrigger(t, d, "jira_assigned"); len(got) != 2 {
		t.Fatalf("a later change by someone else: want 2 jira_assigned items, got %d", len(got))
	}
}

// Degenerate branch: an owner comment on a DIFFERENT issue never suppresses
// this issue's jira_assigned item.
func TestJiraDetector_AssignedOwnCommentOnOtherIssueDoesNotSuppress(t *testing.T) {
	d := testDB(t)
	owner := db.Owner{JiraAccountID: "acc-alice"}
	updated := time.Now().Add(-1 * time.Hour)
	seedJiraIssue(t, d, "WT-8", "acc-alice", updated)
	seedJiraComment(t, d, "WT-9", "acc-alice", "elsewhere", updated)

	n, err := DetectJira(context.Background(), d, owner, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 jira_assigned item, got %d", n)
	}
}

func TestIsOwnCommentBump(t *testing.T) {
	comment := time.Now().Add(-time.Hour)
	c := comment.Unix()
	cases := []struct {
		name      string
		updatedAt string
		ownTS     int64
		want      bool
	}{
		{"no own comment", db.FormatJiraTime(comment.UTC()), 0, false},
		{"updated at the comment", db.FormatJiraTime(comment.UTC()), c, true},
		{"updated within tolerance", db.FormatJiraTime(comment.Add(ownCommentBumpTolerance * time.Second).UTC()), c, true},
		{"updated past tolerance", db.FormatJiraTime(comment.Add((ownCommentBumpTolerance + 1) * time.Second).UTC()), c, false},
		{"updated before the comment", db.FormatJiraTime(comment.Add(-time.Minute).UTC()), c, true},
		{"unparseable updated_at", "not-a-date", c, false},
	}
	for _, tc := range cases {
		if got := isOwnCommentBump(tc.updatedAt, tc.ownTS); got != tc.want {
			t.Errorf("%s: isOwnCommentBump = %v, want %v", tc.name, got, tc.want)
		}
	}
}
