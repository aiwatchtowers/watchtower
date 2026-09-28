package inbox

import (
	"context"
	"fmt"
	"strings"
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

// assignedAfterOwnActivity runs one detection over a jira_assigned issue whose
// earlier item was resolved, the owner having commented at commentAt (and
// edited that comment at editedAt when non-zero) and the issue last updated
// at issueUpdated. Returns the number of jira_assigned items afterwards.
func assignedAfterOwnActivity(t *testing.T, commentAt, editedAt, issueUpdated time.Time) int {
	t.Helper()
	d := testDB(t)
	owner := db.Owner{JiraAccountID: "acc-alice"}
	since := time.Now().Add(-4 * time.Hour)
	seedJiraIssue(t, d, "WT-10", "acc-alice", time.Now().Add(-3*time.Hour))
	if _, err := DetectJira(context.Background(), d, owner, since); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE inbox_items SET status = 'resolved' WHERE trigger_type = 'jira_assigned'`); err != nil {
		t.Fatal(err)
	}
	seedJiraComment(t, d, "WT-10", "acc-alice", "on it", commentAt)
	if !editedAt.IsZero() {
		if _, err := d.Exec(`UPDATE jira_comments SET updated_at = ? WHERE issue_key = 'WT-10'`,
			db.FormatJiraTime(editedAt.UTC())); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := d.Exec(`UPDATE jira_issues SET updated_at = ? WHERE key = 'WT-10'`,
		db.FormatJiraTime(issueUpdated.UTC())); err != nil {
		t.Fatal(err)
	}
	if _, err := DetectJira(context.Background(), d, owner, since); err != nil {
		t.Fatal(err)
	}
	return len(queryInboxByTrigger(t, d, "jira_assigned"))
}

// Editing an own comment bumps the issue's updated_at as well; the edit is
// the owner's own activity and must not re-mint a resolved item either.
func TestJiraDetector_AssignedOwnCommentEditDoesNotReMint(t *testing.T) {
	commentAt := time.Now().Add(-2 * time.Hour)
	editedAt := time.Now().Add(-30 * time.Minute)
	if n := assignedAfterOwnActivity(t, commentAt, editedAt, editedAt.Add(2*time.Second)); n != 1 {
		t.Fatalf("an edit of the owner's own comment re-minted: want 1 jira_assigned item, got %d", n)
	}
}

// The 60-second window is a deliberate trade-off: a colleague's change that
// lands within ownCommentBumpTolerance of the owner's comment is taken for
// the comment's own bump and does not surface; one just past it does.
func TestJiraDetector_AssignedColleagueChangeInsideToleranceSwallowed(t *testing.T) {
	commentAt := time.Now().Add(-1 * time.Hour)
	if n := assignedAfterOwnActivity(t, commentAt, time.Time{}, commentAt.Add(ownCommentBumpTolerance*time.Second)); n != 1 {
		t.Fatalf("a change inside the tolerance: want it swallowed (1 item), got %d", n)
	}
	if n := assignedAfterOwnActivity(t, commentAt, time.Time{}, commentAt.Add((ownCommentBumpTolerance+2)*time.Second)); n != 2 {
		t.Fatalf("a change past the tolerance: want a new item (2), got %d", n)
	}
}

// latestFor reads only the keys it is asked about and serves repeat keys
// from its per-cycle cache, so detection and auto-resolve share one read.
func TestOwnJiraComments_FiltersByKeyAndCaches(t *testing.T) {
	d := testDB(t)
	seedJiraIssue(t, d, "WT-11", "acc-alice", time.Now().Add(-2*time.Hour))
	at := time.Now().Add(-1 * time.Hour)
	seedJiraComment(t, d, "WT-11", "acc-alice", "mine", at)
	seedJiraComment(t, d, "WT-12", "acc-alice", "mine too", at)
	seedJiraComment(t, d, "WT-11", "acc-bob", "not mine", time.Now())

	own := newOwnJiraComments(d, db.Owner{JiraAccountID: "acc-alice"})
	got, err := own.latestFor([]string{"WT-11"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got["WT-11"].created != at.Unix() {
		t.Fatalf("latestFor(WT-11) = %+v, want only WT-11 at the owner's comment", got)
	}

	// Change the table under the cache: a re-read of WT-11 would now see the
	// newer own comment below, and WT-12's row is gone before it is first
	// asked for.
	if _, err := d.Exec(`DELETE FROM jira_comments`); err != nil {
		t.Fatal(err)
	}
	seedJiraComment(t, d, "WT-11", "acc-alice", "newer", time.Now())
	got, err = own.latestFor([]string{"WT-11", "WT-12"})
	if err != nil {
		t.Fatal(err)
	}
	if got["WT-11"].created != at.Unix() {
		t.Errorf("WT-11 must be served from the cycle cache, got %+v", got["WT-11"])
	}
	if _, ok := got["WT-12"]; ok {
		t.Errorf("WT-12 was first asked for after the delete; want no entry, got %+v", got["WT-12"])
	}
}

// Degenerate branch: an owner with no Atlassian id reads nothing.
func TestOwnJiraComments_NoIdentityReadsNothing(t *testing.T) {
	d := testDB(t)
	seedJiraComment(t, d, "WT-13", "acc-alice", "mine", time.Now())
	got, err := newOwnJiraComments(d, db.Owner{}).latestFor([]string{"WT-13"})
	if err != nil || got != nil {
		t.Fatalf("latestFor with no identity = %+v, %v; want nil, nil", got, err)
	}
}

// TestOwnJiraComments_QueryUsesIndex is the EXPLAIN guard for the own-comment
// read: it must SEARCH through idx_jira_comments_issue_author, never SCAN
// jira_comments (idx_jira_comments_issue leads with account_id, which this
// read does not bind).
func TestOwnJiraComments_QueryUsesIndex(t *testing.T) {
	d := testDB(t)
	rows, err := d.Query(`EXPLAIN QUERY PLAN `+ownCommentsQuery(2, 3), "k1", "k2", "k3", "a1", "a2")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var plan []string
	for rows.Next() {
		var id, parent, notUsed int
		var detail string
		if err := rows.Scan(&id, &parent, &notUsed, &detail); err != nil {
			t.Fatal(err)
		}
		plan = append(plan, detail)
	}
	joined := strings.Join(plan, "\n")
	if !strings.Contains(joined, "idx_jira_comments_issue_author") || strings.Contains(joined, "SCAN jira_comments") {
		t.Fatalf("own-comment read must search idx_jira_comments_issue_author, plan:\n%s", joined)
	}
}

// More keys than one IN (...) chunk holds are read across several chunks,
// and every key's comment is found.
func TestOwnJiraComments_ChunksPastTheLimit(t *testing.T) {
	d := testDB(t)
	at := time.Now().Add(-1 * time.Hour)
	n := ownCommentKeyChunk + 7
	keys := make([]string, n)
	for i := range keys {
		keys[i] = fmt.Sprintf("WT-%d", i+1)
	}
	seedJiraComment(t, d, keys[0], "acc-alice", "first chunk", at)
	seedJiraComment(t, d, keys[n-1], "acc-alice", "last chunk", at)

	got, err := newOwnJiraComments(d, db.Owner{JiraAccountID: "acc-alice"}).latestFor(keys)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[keys[0]].created != at.Unix() || got[keys[n-1]].created != at.Unix() {
		t.Fatalf("latestFor over %d keys = %+v, want both chunk ends", n, got)
	}
}

// Degenerate branch: a known identity but no keys reads nothing.
func TestOwnJiraComments_EmptyKeysWithIdentity(t *testing.T) {
	d := testDB(t)
	seedJiraComment(t, d, "WT-1", "acc-alice", "mine", time.Now())
	got, err := newOwnJiraComments(d, db.Owner{JiraAccountID: "acc-alice"}).latestFor(nil)
	if err != nil || got != nil {
		t.Fatalf("latestFor(nil) = %+v, %v; want nil, nil", got, err)
	}
}

// A failed read does not mark its keys as read: asking again retries and
// reports the error again rather than serving "no comments" from the cache.
func TestOwnJiraComments_FailedReadIsRetried(t *testing.T) {
	d := testDB(t)
	seedJiraComment(t, d, "WT-1", "acc-alice", "mine", time.Now())
	own := newOwnJiraComments(d, db.Owner{JiraAccountID: "acc-alice"})
	if _, err := d.Exec(`ALTER TABLE jira_comments RENAME COLUMN author_account_id TO author_gone`); err != nil {
		t.Fatal(err)
	}
	if _, err := own.latestFor([]string{"WT-1"}); err == nil {
		t.Fatal("want an error from a broken read")
	}
	if _, err := own.latestFor([]string{"WT-1"}); err == nil {
		t.Fatal("a failed key must be re-read (and fail again), not served from the cache")
	}
}
