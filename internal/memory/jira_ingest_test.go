package memory

import (
	"context"
	"fmt"
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

// assertBodyContains fails the test for each want string not found in body.
func assertBodyContains(t *testing.T, body string, wants ...string) {
	t.Helper()
	for _, want := range wants {
		if !strings.Contains(body, want) {
			t.Errorf("body missing %q\nbody:\n%s", want, body)
		}
	}
}

// assertEntityBackLinks fails the test for each entity id whose vault node
// lacks a back-link to id.
func assertEntityBackLinks(t *testing.T, v *Vault, entIDs []string, id string) {
	t.Helper()
	for _, entID := range entIDs {
		en, rerr := v.ReadNode(entID)
		if rerr != nil {
			t.Fatalf("read entity: %v", rerr)
		}
		if !strings.Contains(en.Body, "[["+id+"|") {
			t.Errorf("entity %s missing back-link to %s", entID, id)
		}
	}
}

// assertPipelineStepStatus fails the test unless steps contains one with the
// given channel name whose status matches want.
func assertPipelineStepStatus(t *testing.T, steps []db.PipelineStep, channelName, want string) {
	t.Helper()
	for _, s := range steps {
		if s.ChannelName != channelName {
			continue
		}
		if s.Status != want {
			t.Errorf("%s step status = %q, want %q", channelName, s.Status, want)
		}
		return
	}
	t.Fatalf("no %s step recorded", channelName)
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
	wantUnix, ok := db.ParseJiraTime("2026-07-22T10:00:00.000+0000")
	if !ok {
		t.Fatal("test time failed to parse")
	}
	assertBodyContains(t, n.Body,
		"# CEX-7413: Fix the webhook",
		"Type: Task.", "Status: Done (done).", "Priority: Medium.",
		"Assignee: Alice A.", "Reporter: Bob B.", "Sprint: Sprint 9.",
		"Decision-request handling is broken on prod.",
		"Resolved (Done) at 2026-07-22T09:00:00.000+0000",
		fmt.Sprintf("- jira:CEX-7413 %d", wantUnix),
	)
	// Back-links landed on both entities.
	assertEntityBackLinks(t, v, []string{"ent_00000000000000000000000cex", "ent_0000000000000000000000alice"}, id)
	// Watermark advanced to the issue's parsed updated_at.
	wm, _ := d.MemoryJiraWatermark()
	if wm == 1 {
		t.Error("watermark did not advance")
	}
	// The unix-ts ref lands in the derived memory_provenance index (Finding 1
	// of the final-review fix wave) — a jira ref is now indexable/ageable.
	var provCount int
	row := d.QueryRow(`SELECT COUNT(*) FROM memory_provenance WHERE node_id = ? AND scheme = 'jira' AND channel_id = 'jira:CEX-7413'`, id)
	if err := row.Scan(&provCount); err != nil {
		t.Fatalf("query memory_provenance: %v", err)
	}
	if provCount != 1 {
		t.Errorf("memory_provenance rows for %s = %d, want 1", id, provCount)
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

// TestRunJiraIngestReopenFlipsBackToActive (Minor 4, final-review fix wave): a
// done+resolved issue is born closed/long; when it is later reopened
// (status/status_category flip off done, resolved_at cleared, a newer
// updated_at) the SAME node flips back to active/short — status/tier are not
// pinned once an issue is closed.
func TestRunJiraIngestReopenFlipsBackToActive(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	seedJiraIssueExtract(t, d, "CEX-9", "CEX", "Flaky test", "", "Done", "done", "2026-07-22T09:00:00.000+0000", "2026-07-22T10:00:00.000+0000", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)

	var stats RunStats
	if _, err := p.runJiraIngest(1, 0, &stats); err != nil {
		t.Fatal(err)
	}
	firstID, err := d.LookupMemoryAlias("jiraissue:CEX-9")
	if err != nil {
		t.Fatalf("alias lookup: %v", err)
	}
	n, _ := v.ReadNode(firstID)
	if n.Status != "closed" || n.Tier != "long" {
		t.Fatalf("done issue: status/tier = %s/%s, want closed/long", n.Status, n.Tier)
	}

	// Reopened: status flips off done, resolved_at clears, updated_at moves
	// forward past the watermark.
	if _, err := d.Exec(`UPDATE jira_issues SET status='In Progress', status_category='in_progress', resolved_at='', updated_at='2026-07-22T12:00:00.000+0000' WHERE key='CEX-9'`); err != nil {
		t.Fatal(err)
	}
	if _, err := p.runJiraIngest(2, 0, &stats); err != nil {
		t.Fatal(err)
	}
	secondID, _ := d.LookupMemoryAlias("jiraissue:CEX-9")
	if secondID != firstID {
		t.Errorf("reopen minted a new node %s (want in-place update of %s)", secondID, firstID)
	}
	n, _ = v.ReadNode(firstID)
	if n.Status != "active" || n.Tier != "short" {
		t.Errorf("reopened issue: status/tier = %s/%s, want active/short (not pinned closed/long)", n.Status, n.Tier)
	}
}

// TestRunJiraIngestSkipsArchivedRollupAlias (Finding 1d, final-review fix
// wave): when the jiraissue:<KEY> alias has been re-aliased onto a
// non-episode node (a rollup left behind by eviction, or any future
// re-alias), the mechanical builder must never rewrite it — the archived
// rollup's body stays untouched and no new node is created.
func TestRunJiraIngestSkipsArchivedRollupAlias(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	seedJiraIssueExtract(t, d, "CEX-1", "CEX", "Reopened after archive", "", "In Progress", "in_progress", "", "2026-07-22T10:00:00.000+0000", "")

	rollup := Node{
		ID:      NewID("rollup"),
		Type:    "rollup",
		Tier:    "long",
		Status:  "active",
		Title:   "Archived summary",
		Aliases: []string{"jiraissue:CEX-1"},
		Body:    "# Archived summary\n\nBody untouched by the mechanical builder.\n",
	}
	writeAndIndex(t, v, d, rollup)

	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)
	var stats RunStats
	if _, err := p.runJiraIngest(1, 0, &stats); err != nil {
		t.Fatal(err)
	}
	if stats.JiraEpisodes != 0 {
		t.Errorf("JiraEpisodes = %d, want 0 (rollup alias skipped, not rewritten)", stats.JiraEpisodes)
	}

	id, err := d.LookupMemoryAlias("jiraissue:CEX-1")
	if err != nil {
		t.Fatalf("alias lookup: %v", err)
	}
	if id != rollup.ID {
		t.Errorf("alias now resolves to %s, want unchanged rollup %s", id, rollup.ID)
	}
	n, err := v.ReadNode(id)
	if err != nil {
		t.Fatalf("read node: %v", err)
	}
	if n.Type != "rollup" || n.Body != rollup.Body {
		t.Errorf("rollup was rewritten: type=%s body=%q", n.Type, n.Body)
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

// TestRunJiraIngestWatermarkSetFailureAfterBuildRecordsStepError (round-1
// review panel): the build can succeed (episodes committed) while the
// SUBSEQUENT watermark advance fails — the prior code only logged that
// failure while the step still recorded "done", hiding a partial success
// from pipeline_steps. A trigger on the watermark column simulates a write
// failure that leaves every read (and the build's own writes, which never
// touch workspace) unaffected.
func TestRunJiraIngestWatermarkSetFailureAfterBuildRecordsStepError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	seedJiraIssueExtract(t, d, "CEX-1", "CEX", "s", "", "To Do", "todo", "", "2026-07-22T10:00:00.000+0000", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)

	if _, err := d.Exec(`CREATE TRIGGER jira_watermark_write_fails
		BEFORE UPDATE OF memory_jira_last_extracted_ts ON workspace
		BEGIN SELECT RAISE(FAIL, 'boom'); END`); err != nil {
		t.Fatal(err)
	}

	runID, err := d.CreatePipelineRun("memory", "test", "")
	if err != nil {
		t.Fatal(err)
	}

	var stats RunStats
	n, err := p.runJiraIngest(runID, 0, &stats)
	if err != nil {
		t.Fatalf("runJiraIngest: %v (the function itself still returns nil — only the recorded step status must flip)", err)
	}
	if n != 1 {
		t.Fatalf("steps = %d, want 1", n)
	}
	if stats.JiraEpisodes != 1 {
		t.Fatalf("JiraEpisodes = %d, want 1 (the build itself succeeded)", stats.JiraEpisodes)
	}

	steps, err := d.GetPipelineSteps(runID)
	if err != nil {
		t.Fatal(err)
	}
	assertPipelineStepStatus(t, steps, "jira-ingest", "error")

	wm, _ := d.MemoryJiraWatermark()
	if wm != 1 {
		t.Errorf("watermark = %v, want unchanged 1 (the set failed)", wm)
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
