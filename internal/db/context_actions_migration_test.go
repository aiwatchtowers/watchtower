package db

import (
	"fmt"
	"testing"
)

// coachV2Columns is every 00187 coach_proposals column, in table order.
const coachV2Columns = coachV1Columns + `, origin, skill, conversation_id, written_branch, measure_from`

// TestMigration00188_KeepsRows: the rebuild keeps every 00187 row with its id,
// its links (reverts_id, conversation_id, prompt_additions,
// skill_pack_overlays) and its index, and the new columns take their defaults.
func TestMigration00188_KeepsRows(t *testing.T) {
	t.Parallel()
	raw := openRawDBAtVersion(t, 187)
	seedCoachV1(t, raw)
	tcExec(t, raw, `INSERT INTO chat_conversations (id, title, context_type, created_at, updated_at)
		VALUES (5, '', 'analytics_tuning', 0, 0)`)
	tcExec(t, raw, `INSERT INTO coach_proposals (`+coachV2Columns+`) VALUES
		(11, 'fp-11', 'add', 'repo_claude_md', 1, '', 'T11', 'W11', 'corrections', 'b', 'a', '[]', 1, 'accepted', NULL,
		 '2026-11-06T00:00:00Z', '2026-11-07T00:00:00Z', NULL, 0, '', NULL, '', 'chat', '', 5, 'feature/x', '2026-11-08T00:00:00Z')`)
	tcExec(t, raw, `INSERT INTO skill_pack_overlays (id, skill, text, proposal_id, created_at)
		VALUES (1, 'watchtower-workbench', 'line', 11, '2026-11-07T00:00:00Z')`)
	before := coachRowsDumpQuery(t, raw, `SELECT `+coachV2Columns+` FROM coach_proposals ORDER BY id`)

	applyNextMigration(t, raw)

	after := coachRowsDumpQuery(t, raw, `SELECT `+coachV2Columns+` FROM coach_proposals ORDER BY id`)
	if fmt.Sprint(before) != fmt.Sprint(after) {
		t.Fatalf("rows changed\nbefore %v\nafter  %v", before, after)
	}
	var n int
	if err := raw.QueryRow(`SELECT count(*) FROM coach_proposals
		WHERE session_id IS NULL AND source_key = '' AND via_session = 0 AND session_branch = ''`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 4 {
		t.Fatalf("rows with default new columns = %d, want 4", n)
	}
	for _, idx := range []string{"coach_proposals_conversation", "coach_proposals_session"} {
		if !tcObjectExists(t, raw, "index", idx) {
			t.Fatalf("index %s missing", idx)
		}
	}
	assertNoFKViolations(t, raw)

	// The SET NULL links still work on the rebuilt table.
	tcExec(t, raw, `DELETE FROM coach_proposals WHERE id IN (7, 11)`)
	var nulls int
	if err := raw.QueryRow(`SELECT (SELECT count(*) FROM coach_proposals WHERE id = 9 AND reverts_id IS NULL)
		+ (SELECT count(*) FROM prompt_additions WHERE id = 2 AND proposal_id IS NULL)
		+ (SELECT count(*) FROM skill_pack_overlays WHERE id = 1 AND proposal_id IS NULL)`).Scan(&nulls); err != nil {
		t.Fatal(err)
	}
	if nulls != 3 {
		t.Fatalf("SET NULL after delete: %d of 3", nulls)
	}
}

// TestMigration00188_Checks: the CHECK lists take the new values and still
// refuse unknown ones.
func TestMigration00188_Checks(t *testing.T) {
	t.Parallel()
	raw := openRawDBAtVersion(t, 187)
	applyNextMigration(t, raw)

	ins := func(id int, kind, dest, metric, origin, verdict string) error {
		_, err := raw.Exec(`INSERT INTO coach_proposals (id, fingerprint, kind, destination, title, why, metric, sources,
			created_at, origin, verdict) VALUES (?, ?, ?, ?, 't', 'w', ?, 1, '2026-11-12T00:00:00Z', ?, ?)`,
			id, fmt.Sprintf("fp-%d", id), kind, dest, metric, origin, verdict)
		return err
	}
	for i, dest := range []string{"claude_plugin_off", "claude_mcp_server_off", "claude_connectors_off", "claude_memory_index"} {
		if err := ins(100+i, "restructure", dest, "start_tokens", "context", "reverted_outside"); err != nil {
			t.Errorf("destination %q refused: %v", dest, err)
		}
	}
	bad := []struct{ kind, dest, metric, origin, verdict string }{
		{"nope", "session", "corrections", "weekly", ""},
		{"add", "nope", "corrections", "weekly", ""},
		{"add", "session", "nope", "weekly", ""},
		{"add", "session", "corrections", "nope", ""},
		{"add", "session", "corrections", "weekly", "nope"},
	}
	for i, b := range bad {
		if err := ins(200+i, b.kind, b.dest, b.metric, b.origin, b.verdict); err == nil {
			t.Errorf("accepted %+v", b)
		}
	}
}

// TestMigration00188_DownUp: Down drops the rows 00187 cannot hold, clears the
// links to them and the new columns; Up applies again.
func TestMigration00188_DownUp(t *testing.T) {
	t.Parallel()
	raw := openRawDBAtVersion(t, 187)
	seedCoachV1(t, raw)
	applyNextMigration(t, raw)
	tcExec(t, raw, `INSERT INTO coach_proposals (id, fingerprint, kind, destination, title, why, metric, sources,
		created_at, origin, source_key) VALUES (20, 'fp-20', 'cut', 'claude_plugin_off', 't', 'w', 'start_tokens', 1,
		'2026-11-12T00:00:00Z', 'context', 'alpha@market')`)
	tcExec(t, raw, `UPDATE coach_proposals SET reverts_id = 20 WHERE id = 4`)
	tcExec(t, raw, `UPDATE prompt_additions SET proposal_id = 20 WHERE id = 2`)
	tcExec(t, raw, `INSERT INTO skill_pack_overlays (id, skill, text, proposal_id, created_at)
		VALUES (1, 'watchtower-workbench', 'line', 20, '2026-11-12T00:00:00Z')`)

	if err := gooseDownTo(raw, "migrations", 187); err != nil {
		t.Fatalf("down: %v", err)
	}
	if tcHasColumn(t, raw, "coach_proposals", "source_key") || tcObjectExists(t, raw, "index", "coach_proposals_session") {
		t.Fatal("down left 00188 objects behind")
	}
	if !tcObjectExists(t, raw, "index", "coach_proposals_conversation") {
		t.Fatal("down lost the 00187 index")
	}
	var ids string
	if err := raw.QueryRow(`SELECT group_concat(id, ',') FROM (SELECT id FROM coach_proposals ORDER BY id)`).Scan(&ids); err != nil {
		t.Fatal(err)
	}
	if ids != "4,7,9" {
		t.Fatalf("ids after down = %q, want 4,7,9", ids)
	}
	var cleared int
	if err := raw.QueryRow(`SELECT (SELECT count(*) FROM coach_proposals WHERE id = 4 AND reverts_id IS NULL)
		+ (SELECT count(*) FROM prompt_additions WHERE id = 2 AND proposal_id IS NULL)
		+ (SELECT count(*) FROM skill_pack_overlays WHERE id = 1 AND proposal_id IS NULL)`).Scan(&cleared); err != nil {
		t.Fatal(err)
	}
	if cleared != 3 {
		t.Fatalf("links to dropped rows not cleared: %d of 3", cleared)
	}
	assertNoFKViolations(t, raw)

	applyNextMigration(t, raw)
	if !tcHasColumn(t, raw, "coach_proposals", "session_branch") {
		t.Fatal("up after down did not apply")
	}
	assertNoFKViolations(t, raw)
}
