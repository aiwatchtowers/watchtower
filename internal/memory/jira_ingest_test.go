package memory

import (
	"context"
	"strings"
	"testing"

	"watchtower/internal/db"
)

// seedJiraIssueExtract inserts one jira_issues row for builder tests (a fuller
// fixture than seed_test.go's seedJiraIssue, which only seeds key/project_key
// for the project-seeding tests).
func seedJiraIssueExtract(t *testing.T, d *db.DB, key, project, summary, desc, status, statusCat, resolvedAt, updatedAt, assigneeSlackID string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO jira_issues
		(key, project_key, summary, description_text, issue_type, status, status_category,
		 priority, assignee_display_name, assignee_slack_id, reporter_display_name, reporter_slack_id,
		 sprint_name, epic_key, due_date, resolved_at, created_at, updated_at, synced_at, is_deleted)
		VALUES (?,?,?,?, 'Task', ?, ?, 'Medium', 'Alice A', ?, 'Bob B', '', 'Sprint 9', '', '', ?, '2026-07-01T00:00:00.000+0000', ?, '2026-07-22T00:00:00Z', 0)`,
		key, project, summary, desc, status, statusCat, assigneeSlackID, resolvedAt, updatedAt)
	if err != nil {
		t.Fatalf("seed jira issue %s: %v", key, err)
	}
}

// TestRunJiraIngestNoBackfillInit: watermark 0 + rows present → the watermark
// initializes to the max parsed updated_at and NOTHING is built (owner scope-B
// decision: the pre-enablement backlog never backfills). No AI call ever.
func TestRunJiraIngestNoBackfillInit(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedJiraIssueExtract(t, d, "CEX-1", "CEX", "old backlog", "", "To Do", "todo", "", "2026-07-20T10:00:00.000+0000", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)

	var stats RunStats
	steps, err := p.runJiraIngest(1, 0, &stats)
	if err != nil {
		t.Fatalf("runJiraIngest: %v", err)
	}
	if steps != 1 {
		t.Errorf("steps = %d, want 1 (the init records a step row)", steps)
	}
	if stats.JiraEpisodes != 0 {
		t.Errorf("JiraEpisodes = %d, want 0 (no backfill)", stats.JiraEpisodes)
	}
	wm, _ := d.MemoryJiraWatermark()
	if wm == 0 {
		t.Error("watermark not initialized")
	}
	// Second run: nothing above the watermark → zero steps, zero episodes.
	steps, err = p.runJiraIngest(2, 0, &stats)
	if err != nil || steps != 0 || stats.JiraEpisodes != 0 {
		t.Errorf("steady state = steps %d, episodes %d, err %v; want 0,0,nil", steps, stats.JiraEpisodes, err)
	}
}

// TestRunJiraIngestBuildsEpisode: an issue updated above the watermark becomes
// one episode with deterministic Story/Outcome/Provenance, aliased
// jiraissue:<KEY>, linked to its project entity and assignee person entity;
// a done+resolved issue is born closed/long.
func TestRunJiraIngestBuildsEpisode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	seedJiraIssueExtract(t, d, "CEX-7413", "CEX", "Fix the webhook", "Decision-request handling is broken on prod.",
		"Done", "done", "2026-07-22T09:00:00.000+0000", "2026-07-22T10:00:00.000+0000", "U1ALICE")
	// The project entity the episode must back-link (seedJiraProjects aliases
	// a project entity by its bare key).
	writeAndIndex(t, v, d, bareEntity("ent_00000000000000000000000cex", "CEX"))
	writeAndIndex(t, v, d, bareEntity("ent_0000000000000000000000alice", "U1ALICE"))
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)

	var stats RunStats
	if _, err := p.runJiraIngest(1, 0, &stats); err != nil {
		t.Fatalf("runJiraIngest: %v", err)
	}
	if stats.JiraEpisodes != 1 {
		t.Fatalf("JiraEpisodes = %d, want 1", stats.JiraEpisodes)
	}
	id, err := d.LookupMemoryAlias("jiraissue:CEX-7413")
	if err != nil {
		t.Fatalf("alias lookup: %v", err)
	}
	n, err := v.ReadNode(id)
	if err != nil {
		t.Fatalf("read node: %v", err)
	}
	if n.Status != "closed" || n.Tier != "long" {
		t.Errorf("done issue: status/tier = %s/%s, want closed/long", n.Status, n.Tier)
	}
	for _, want := range []string{
		"# CEX-7413: Fix the webhook",
		"Type: Task.", "Status: Done (done).", "Priority: Medium.",
		"Assignee: Alice A.", "Reporter: Bob B.", "Sprint: Sprint 9.",
		"Decision-request handling is broken on prod.",
		"Resolved (Done) at 2026-07-22T09:00:00.000+0000",
		"- jira:CEX-7413 2026-07-22T10:00:00.000+0000",
	} {
		if !strings.Contains(n.Body, want) {
			t.Errorf("body missing %q\nbody:\n%s", want, n.Body)
		}
	}
	// Back-links landed on both entities.
	for _, entID := range []string{"ent_00000000000000000000000cex", "ent_0000000000000000000000alice"} {
		en, rerr := v.ReadNode(entID)
		if rerr != nil {
			t.Fatalf("read entity: %v", rerr)
		}
		if !strings.Contains(en.Body, "[["+id+"|") {
			t.Errorf("entity %s missing back-link to %s", entID, id)
		}
	}
	// Watermark advanced to the issue's parsed updated_at.
	wm, _ := d.MemoryJiraWatermark()
	if wm == 1 {
		t.Error("watermark did not advance")
	}
}

// TestRunJiraIngestIdempotentUpdate: re-running with no change commits nothing
// (content-equality no-op); a real update refreshes the SAME node in place.
func TestRunJiraIngestIdempotentUpdate(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	seedJiraIssueExtract(t, d, "CEX-1", "CEX", "First", "", "To Do", "todo", "", "2026-07-22T10:00:00.000+0000", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)

	var stats RunStats
	if _, err := p.runJiraIngest(1, 0, &stats); err != nil {
		t.Fatal(err)
	}
	firstID, _ := d.LookupMemoryAlias("jiraissue:CEX-1")

	// Same content re-scan: reset the watermark so the row re-lists — commit
	// must be a no-op (JiraEpisodes unchanged).
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	before := stats.JiraEpisodes
	if _, err := p.runJiraIngest(2, 0, &stats); err != nil {
		t.Fatal(err)
	}
	if stats.JiraEpisodes != before {
		t.Errorf("unchanged re-scan built %d new episode(s)", stats.JiraEpisodes-before)
	}

	// A real update (status flip) refreshes the same node.
	if _, err := d.Exec(`UPDATE jira_issues SET status='In Progress', status_category='in_progress', updated_at='2026-07-22T12:00:00.000+0000' WHERE key='CEX-1'`); err != nil {
		t.Fatal(err)
	}
	if _, err := p.runJiraIngest(3, 0, &stats); err != nil {
		t.Fatal(err)
	}
	secondID, _ := d.LookupMemoryAlias("jiraissue:CEX-1")
	if secondID != firstID {
		t.Errorf("update minted a new node %s (want in-place update of %s)", secondID, firstID)
	}
	n, _ := v.ReadNode(firstID)
	if !strings.Contains(n.Body, "Status: In Progress (in_progress).") {
		t.Errorf("body not refreshed:\n%s", n.Body)
	}
}

// TestRunJiraIngestWatermarkFreezeOnError: a lookup failure during the build
// (here, LookupMemoryAlias erroring on a dropped memory_aliases table — the
// calendar freeze test's dropped-recap-table precedent) freezes the whole step
// so every pending issue re-scans next run (MEM-04, adapted).
func TestRunJiraIngestWatermarkFreezeOnError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	seedJiraIssueExtract(t, d, "CEX-1", "CEX", "s", "", "To Do", "todo", "", "2026-07-22T10:00:00.000+0000", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)
	if _, err := d.Exec(`DROP TABLE memory_aliases`); err != nil {
		t.Fatal(err)
	}

	var stats RunStats
	_, _ = p.runJiraIngest(1, 0, &stats)
	if stats.JiraIssuesFailed == 0 {
		t.Error("failed counter not bumped")
	}
	wm, _ := d.MemoryJiraWatermark()
	if wm != 1 {
		t.Errorf("watermark moved to %v on a failed commit (must freeze at 1)", wm)
	}
}

// TestRunJiraIngestDarkByDefault: with memory.sources.jira off, a full Run
// never touches the jira path — no jiraissue: alias appears and the jira
// watermark stays 0 even with pending issues present.
func TestRunJiraIngestDarkByDefault(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedJiraIssueExtract(t, d, "CEX-1", "CEX", "pending", "", "To Do", "todo", "", "2026-07-22T10:00:00.000+0000", "")

	cfg := pipelineTestConfig() // Sources.Jira is false by default
	p := NewPipeline(d, v, nil, cfg, t.Logf)

	if _, err := p.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := d.LookupMemoryAlias("jiraissue:CEX-1"); err == nil {
		t.Error("dark run built a jira episode")
	}
	wm, _ := d.MemoryJiraWatermark()
	if wm != 0 {
		t.Errorf("dark run moved the jira watermark to %v", wm)
	}
}
