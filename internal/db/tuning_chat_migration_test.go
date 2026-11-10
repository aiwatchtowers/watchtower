package db

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
)

// coachV1Columns is every 00162 coach_proposals column, in table order.
const coachV1Columns = `id, fingerprint, kind, destination, workbench_id, prompt_id, title, why, metric,
	before_text, after_text, evidence, sources, status, reverts_id, created_at, decided_at,
	baseline, baseline_n, verdict, verdict_value, verdict_at`

// tuningChatNewDestinations are the destinations 00184 adds to the CHECK.
var tuningChatNewDestinations = []string{
	"claude_skill_user", "codex_skill_user", "pack_overlay", "codex_agents_md_user", "codex_rules_allow",
	"repo_claude_md", "repo_agents_md", "repo_claude_skill", "repo_codex_skill", "repo_workflow",
}

func seedCoachV1(t *testing.T, raw *sql.DB) {
	t.Helper()
	mustExec(t, raw, `INSERT INTO projects (id, name, folder_path, created_at, updated_at)
		VALUES (1, 'acme', '/tmp/acme', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z')`)
	rows := []string{
		`(4, 'fp-4', 'add', 'session', 1, '', 'T4', 'W4', 'corrections', 'b4', 'a4', '[{"kind":"ask","ref":"1"}]', 3, 'accepted', NULL, '2026-11-01T00:00:00Z', '2026-11-02T00:00:00Z', 1.5, 10, 'works', 0.5, '2026-11-03T00:00:00Z')`,
		`(7, 'fp-7', 'replace', 'prompt_addition', NULL, 'digest.channel', 'T7', 'W7', 'task_cost', 'b7', 'a7', '[]', 4, 'accepted', NULL, '2026-11-01T00:00:00Z', '2026-11-02T00:00:00Z', 2.5, 12, 'no_effect', 2.4, '2026-11-04T00:00:00Z')`,
		`(9, 'fp-9', 'cut', 'claude_md_user', NULL, '', 'T9', 'W9', 'owner_loop', 'b9', 'a9', '[]', 3, 'open', 7, '2026-11-05T00:00:00Z', '', NULL, 0, '', NULL, '')`,
	}
	for _, r := range rows {
		mustExec(t, raw, `INSERT INTO coach_proposals (`+coachV1Columns+`) VALUES `+r)
	}
	mustExec(t, raw, `INSERT INTO prompt_additions (id, prompt_id, text, proposal_id, created_at) VALUES
		(1, 'digest.channel', 'x', 4, '2026-11-02T00:00:00Z'),
		(2, 'digest.channel', 'y', 7, '2026-11-02T00:00:00Z')`)
}

func mustExec(t *testing.T, raw *sql.DB, q string, args ...any) {
	t.Helper()
	if _, err := raw.Exec(q, args...); err != nil {
		t.Fatalf("exec %q: %v", q, err)
	}
}

// coachRowsDump renders every 00162 column of every row, ordered by id.
func coachRowsDump(t *testing.T, raw *sql.DB) []string {
	t.Helper()
	rows, err := raw.Query(`SELECT ` + coachV1Columns + ` FROM coach_proposals ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	cols, _ := rows.Columns()
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			t.Fatal(err)
		}
		out = append(out, fmt.Sprint(vals...))
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

func hasColumn(t *testing.T, raw *sql.DB, table, column string) bool {
	t.Helper()
	var n int
	if err := raw.QueryRow(`SELECT count(*) FROM pragma_table_info(?) WHERE name = ?`, table, column).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n == 1
}

func objectExists(t *testing.T, raw *sql.DB, typ, name string) bool {
	t.Helper()
	var n int
	if err := raw.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type = ? AND name = ?`, typ, name).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n == 1
}

func assertNoFKViolations(t *testing.T, raw *sql.DB) {
	t.Helper()
	rows, err := raw.Query(`PRAGMA foreign_key_check`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	if rows.Next() {
		t.Fatal("PRAGMA foreign_key_check reports a violation")
	}
}

func insertCoachDest(raw *sql.DB, id int, dest, origin string) error {
	_, err := raw.Exec(`INSERT INTO coach_proposals (id, fingerprint, kind, destination, title, why, metric, sources, created_at, origin)
		VALUES (?, ?, 'add', ?, 't', 'w', 'corrections', 3, '2026-11-06T00:00:00Z', ?)`,
		id, fmt.Sprintf("fp-new-%d", id), dest, origin)
	return err
}

func TestMigration00184_CoachRebuildKeepsRows(t *testing.T) {
	t.Parallel()
	raw := openRawDBAtVersion(t, 183)
	seedCoachV1(t, raw)
	before := coachRowsDump(t, raw)

	applyNextMigration(t, raw)

	after := coachRowsDump(t, raw)
	if fmt.Sprint(before) != fmt.Sprint(after) {
		t.Fatalf("rows changed\nbefore %v\nafter  %v", before, after)
	}
	var reverts sql.NullInt64
	if err := raw.QueryRow(`SELECT reverts_id FROM coach_proposals WHERE id = 9`).Scan(&reverts); err != nil {
		t.Fatal(err)
	}
	if !reverts.Valid || reverts.Int64 != 7 {
		t.Fatalf("reverts_id of 9 = %v, want 7", reverts)
	}
	var links string
	if err := raw.QueryRow(`SELECT group_concat(proposal_id, ',') FROM (SELECT proposal_id FROM prompt_additions ORDER BY id)`).Scan(&links); err != nil {
		t.Fatal(err)
	}
	if links != "4,7" {
		t.Fatalf("prompt_additions.proposal_id = %q, want 4,7", links)
	}
	var n int
	if err := raw.QueryRow(`SELECT count(*) FROM coach_proposals
		WHERE origin = 'weekly' AND skill = '' AND conversation_id IS NULL AND written_branch = '' AND measure_from IS NULL`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Fatalf("rows with default new columns = %d, want 3", n)
	}
	if !objectExists(t, raw, "index", "coach_proposals_conversation") || !objectExists(t, raw, "index", "skill_pack_overlays_skill") {
		t.Fatal("new indexes missing")
	}
	assertNoFKViolations(t, raw)

	// The SET NULL links still work on the rebuilt table.
	mustExec(t, raw, `DELETE FROM coach_proposals WHERE id = 7`)
	var nulls int
	if err := raw.QueryRow(`SELECT (SELECT count(*) FROM coach_proposals WHERE id = 9 AND reverts_id IS NULL)
		+ (SELECT count(*) FROM prompt_additions WHERE id = 2 AND proposal_id IS NULL)`).Scan(&nulls); err != nil {
		t.Fatal(err)
	}
	if nulls != 2 {
		t.Fatalf("SET NULL after delete: %d of 2", nulls)
	}
}

func TestMigration00184_DestinationCheck(t *testing.T) {
	t.Parallel()
	raw := openRawDBAtVersion(t, 183)
	applyNextMigration(t, raw)

	for i, dest := range tuningChatNewDestinations {
		if err := insertCoachDest(raw, 100+i, dest, "chat"); err != nil {
			t.Errorf("destination %q refused: %v", dest, err)
		}
	}
	if err := insertCoachDest(raw, 200, "nope", "weekly"); err == nil {
		t.Error("destination 'nope' accepted")
	}
	if err := insertCoachDest(raw, 201, "session", "other"); err == nil {
		t.Error("origin 'other' accepted")
	}
}

// openRawFileDBAtVersion is openRawDBAtVersion on a file: a failed rebuild
// makes the driver discard its connection (wt_session.go), which would lose
// an in-memory database with it.
func openRawFileDBAtVersion(t *testing.T, version int64) *sql.DB {
	t.Helper()
	raw, err := sql.Open("sqlite3", filepath.Join(t.TempDir(), "w.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { raw.Close() })
	raw.SetMaxOpenConns(1)
	mustExec(t, raw, "PRAGMA foreign_keys=ON")
	if err := gooseUpTo(raw, "migrations", version); err != nil {
		t.Fatalf("migrate to v%d: %v", version, err)
	}
	return raw
}

func TestMigration00184_FailureLeavesNothing(t *testing.T) {
	t.Parallel()
	raw := openRawFileDBAtVersion(t, 183)
	seedCoachV1(t, raw)
	// The last object the block creates already exists under this name.
	mustExec(t, raw, `CREATE TABLE planted(a)`)
	mustExec(t, raw, `CREATE INDEX skill_pack_overlays_skill ON planted(a)`)

	if err := gooseUpByOne(raw, "migrations"); err == nil {
		t.Fatal("migration succeeded over a planted index name")
	}
	if hasColumn(t, raw, "coach_proposals", "origin") {
		t.Error("coach_proposals gained origin after a failed run")
	}
	if objectExists(t, raw, "table", "skill_pack_overlays") {
		t.Error("skill_pack_overlays left behind")
	}
	if objectExists(t, raw, "table", "coach_proposals_new") {
		t.Error("coach_proposals_new left behind")
	}
	if v, err := goose.GetDBVersion(raw); err != nil || v != 183 {
		t.Fatalf("goose version = %d (err %v), want 183", v, err)
	}
	// The failed run left foreign keys off (or the connection was replaced);
	// turn them back on as Open's connection setup does.
	mustExec(t, raw, `PRAGMA foreign_keys = ON`)
	if got := len(coachRowsDump(t, raw)); got != 3 {
		t.Fatalf("rows after failed run = %d, want 3", got)
	}

	mustExec(t, raw, `DROP TABLE planted`)
	applyNextMigration(t, raw)
	if !hasColumn(t, raw, "coach_proposals", "origin") || !objectExists(t, raw, "table", "skill_pack_overlays") {
		t.Fatal("rerun did not apply the migration")
	}
	if got := len(coachRowsDump(t, raw)); got != 3 {
		t.Fatalf("rows after rerun = %d, want 3", got)
	}
}

func TestMigration00184_DownUp(t *testing.T) {
	t.Parallel()
	raw := openRawDBAtVersion(t, 183)
	seedCoachV1(t, raw)
	applyNextMigration(t, raw)

	mustExec(t, raw, `INSERT INTO skill_pack_overlays (id, skill, text, proposal_id, created_at)
		VALUES (1, 'watchtower-workbench', 'line', 4, '2026-11-06T00:00:00Z')`)
	for i, dest := range tuningChatNewDestinations {
		if err := insertCoachDest(raw, 100+i, dest, "chat"); err != nil {
			t.Fatalf("insert %q: %v", dest, err)
		}
	}
	// A kept row pointing at a dropped one, and an addition linked to one.
	mustExec(t, raw, `UPDATE coach_proposals SET reverts_id = 100 WHERE id = 4`)
	mustExec(t, raw, `UPDATE prompt_additions SET proposal_id = 101 WHERE id = 2`)

	if err := gooseDownTo(raw, "migrations", 183); err != nil {
		t.Fatalf("down: %v", err)
	}
	if hasColumn(t, raw, "coach_proposals", "origin") || objectExists(t, raw, "table", "skill_pack_overlays") ||
		objectExists(t, raw, "index", "coach_proposals_conversation") {
		t.Fatal("down left 00184 objects behind")
	}
	var ids string
	if err := raw.QueryRow(`SELECT group_concat(id, ',') FROM (SELECT id FROM coach_proposals ORDER BY id)`).Scan(&ids); err != nil {
		t.Fatal(err)
	}
	if ids != "4,7,9" {
		t.Fatalf("ids after down = %q, want 4,7,9", ids)
	}
	var dangling int
	if err := raw.QueryRow(`SELECT (SELECT count(*) FROM coach_proposals WHERE id = 4 AND reverts_id IS NULL)
		+ (SELECT count(*) FROM prompt_additions WHERE id = 2 AND proposal_id IS NULL)`).Scan(&dangling); err != nil {
		t.Fatal(err)
	}
	if dangling != 2 {
		t.Fatalf("links to dropped rows not cleared: %d of 2", dangling)
	}
	assertNoFKViolations(t, raw)

	applyNextMigration(t, raw)
	if !hasColumn(t, raw, "coach_proposals", "measure_from") || !objectExists(t, raw, "table", "skill_pack_overlays") {
		t.Fatal("up after down did not apply")
	}
	assertNoFKViolations(t, raw)
}

// TestMigration00184_DanglingLinkAborts: the temp-table CHECK over
// pragma_foreign_key_check refuses a rebuild that would leave a link to a
// missing proposal, and the block rolls back.
func TestMigration00184_DanglingLinkAborts(t *testing.T) {
	t.Parallel()
	raw := openRawFileDBAtVersion(t, 183)
	seedCoachV1(t, raw)
	mustExec(t, raw, `PRAGMA foreign_keys = OFF`)
	mustExec(t, raw, `INSERT INTO prompt_additions (id, prompt_id, text, proposal_id, created_at)
		VALUES (3, 'digest.channel', 'z', 999, '2026-11-02T00:00:00Z')`)
	mustExec(t, raw, `PRAGMA foreign_keys = ON`)

	if err := gooseUpByOne(raw, "migrations"); err == nil {
		t.Fatal("migration succeeded with a dangling prompt_additions link")
	}
	mustExec(t, raw, `PRAGMA foreign_keys = ON`)
	if hasColumn(t, raw, "coach_proposals", "origin") || objectExists(t, raw, "table", "skill_pack_overlays") {
		t.Fatal("aborted run left 00184 objects behind")
	}
	if v, err := goose.GetDBVersion(raw); err != nil || v != 183 {
		t.Fatalf("goose version = %d (err %v), want 183", v, err)
	}
}
