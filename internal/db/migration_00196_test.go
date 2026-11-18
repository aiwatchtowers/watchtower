package db

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// mfDump renders every row of q, one string per row.
func mfDump(t *testing.T, raw *sql.DB, q string, args ...any) []string {
	t.Helper()
	rows, err := raw.Query(q, args...)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, rows.Scan(ptrs...))
		out = append(out, strings.TrimSuffix(fmt.Sprintln(vals...), "\n"))
	}
	require.NoError(t, rows.Err())
	return out
}

func mfCount(t *testing.T, raw *sql.DB, q string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, raw.QueryRow(q, args...).Scan(&n))
	return n
}

// seedMultiFolderV195 plants two workbenches with sessions (one standalone),
// a target, asks with every child table 00158/00162/00178 made, a reviewer
// thread, PR states and workbench document index rows — the pre-00196 shape.
func seedMultiFolderV195(t *testing.T, raw *sql.DB) {
	t.Helper()
	for _, q := range []string{
		`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/code/app'), (2, 'hub', '/tmp/code/hub')`,
		`INSERT INTO terminal_sessions (id, project_id, kind, title, folder_path, claude_session_id)
			VALUES (10, 1, 'claude', 'One', '/tmp/code/app', 'u-10'), (11, 2, 'claude', 'Two', '/tmp/code/hub', 'u-11'),
			       (12, NULL, 'shell', 'Terminal', '/tmp', NULL)`,
		`INSERT INTO targets (id, text, level, custom_label, period_start, period_end, source_type, project_id)
			VALUES (20, 'feature', 'custom', 'project', '2026-11-01', '2026-11-01', 'chat', 1)`,
		`INSERT INTO owner_asks (id, project_id, session_id, target_id, kind, title, doc_path, doc_snapshot, doc_type)
			VALUES (30, 1, 10, 20, 'review', 'Spec', 'docs/spec.md', 'text', 'spec')`,
		`INSERT INTO owner_asks (id, project_id, session_id, kind, title, previous_ask_id, status, answer, answered_at)
			VALUES (31, 1, 10, 'question', 'Which?', NULL, 'answered', '{"a":1}', '2026-11-02T00:00:00Z')`,
		`INSERT INTO owner_asks (id, project_id, kind, title, doc_path, previous_ask_id)
			VALUES (32, 1, 'review', 'Spec v2', 'docs/spec.md', 30)`,
		`INSERT INTO spec_reviews (ask_id, status, queued_at) VALUES (30, 'done', '2026-11-01T00:00:00Z')`,
		`INSERT INTO spec_review_marks (ask_id, item_key, state, updated_at) VALUES (30, 'f1', 'ok', '2026-11-01T00:00:00Z')`,
		`INSERT INTO spec_review_questions (id, ask_id, thread, item_key, question, created_at)
			VALUES (40, 30, 'th', 'f1', 'why?', '2026-11-01T00:00:00Z')`,
		`INSERT INTO spec_review_thread_findings (ask_id, item_key, thread, finding, created_at)
			VALUES (30, 'f2', 'th', '{}', '2026-11-01T00:00:00Z')`,
		`INSERT INTO chat_conversations (id, title, context_type, context_id, created_at, updated_at)
			VALUES (50, 'Reviewer: main', 'review_reviewer', '1:main', 0, 0)`,
		`INSERT INTO review_reviewer_threads (project_id, branch, conversation_id) VALUES (1, 'main', 50)`,
		`INSERT INTO workbench_pr_states (project_id, ref, state, checked_at)
			VALUES (1, 'branch:main', 'open', '2026-11-01T00:00:00Z'), (2, 'pr:7', 'merged', '2026-11-01T00:00:00Z')`,
		`INSERT INTO kb_documents (id, source, title) VALUES ('wbdoc:1:README.md', 'project_doc', 'readme'),
			('jira:ACME-1', 'jira', 'issue')`,
		`INSERT INTO kb_chunks (doc_id, idx, body) VALUES ('wbdoc:1:README.md', 0, 'hello'), ('jira:ACME-1', 0, 'issue body')`,
		`INSERT INTO kb_dirty (source, key) VALUES ('project_doc', 'wbdoc:1:README.md')`,
	} {
		tcExec(t, raw, q)
	}
}

const ownerAskChildrenDump = `
	SELECT 'review', ask_id, status, queued_at FROM spec_reviews
	UNION ALL SELECT 'mark', ask_id, item_key, state FROM spec_review_marks
	UNION ALL SELECT 'question', ask_id, thread, question FROM spec_review_questions
	UNION ALL SELECT 'finding', ask_id, item_key, finding FROM spec_review_thread_findings
	ORDER BY 1, 2, 3`

const ownerAskV195Cols = `id, project_id, session_id, target_id, kind, title, summary, changes, payload, doc_path,
	doc_snapshot, previous_ask_id, status, withdrawn_reason, answer, created_at, answered_at, delivered_at, level,
	origin, chat_asked_at, withdrawn_at, automation_run_id, doc_type`

func migratedMultiFolder(t *testing.T) *sql.DB {
	t.Helper()
	raw := openRawDBAtVersion(t, 195)
	seedMultiFolderV195(t, raw)
	applyNextMigration(t, raw)
	assertNoFKViolations(t, raw)
	return raw
}

func TestMigration00196_BackfillsOneFolderPerWorkbench(t *testing.T) {
	t.Parallel()
	raw := migratedMultiFolder(t)

	assert.Equal(t, []string{
		"1 /tmp/code/app 0 owner <nil> app",
		"2 /tmp/code/hub 0 owner <nil> hub",
	}, mfDump(t, raw, `SELECT workbench_id, folder_path, position, added_by, removed_at, name
		FROM workbench_folders ORDER BY workbench_id`))
	assert.Equal(t, []string{"10 1", "11 1", "12 <nil>"}, mfDump(t, raw, `SELECT s.id,
		CASE WHEN s.workbench_folder_id IS NULL THEN NULL
		     ELSE s.workbench_folder_id = (SELECT f.id FROM workbench_folders f WHERE f.workbench_id = s.project_id) END
		FROM terminal_sessions s ORDER BY s.id`))
	assert.Zero(t, mfCount(t, raw, `SELECT COUNT(*) FROM terminal_sessions WHERE parent_session_id IS NOT NULL`))
	assert.Zero(t, mfCount(t, raw, `SELECT COUNT(*) FROM targets WHERE workbench_folder_id IS NOT NULL`))
}

func TestMigration00196_BackfillsFolderNames(t *testing.T) {
	t.Parallel()
	raw := openRawDBAtVersion(t, 195)
	// A pre-NOCASE-check pair (another spelling of one folder) must not fail
	// the live-path index: the later bench's row starts removed.
	tcExec(t, raw, `INSERT INTO projects (id, name, folder_path) VALUES
		(1, 'a', '/Users/acme/Code/My App'), (2, 'b', '/users/acme/code/my app'), (3, 'c', '/srv/site')`)
	applyNextMigration(t, raw)
	assert.Equal(t, []string{"1 My App 0", "2 my app 1", "3 site 0"},
		mfDump(t, raw, `SELECT workbench_id, name, removed_at IS NOT NULL FROM workbench_folders ORDER BY workbench_id`))
}

func TestMigration00196_OwnerAsksRebuildKeepsChildren(t *testing.T) {
	t.Parallel()
	raw := openRawDBAtVersion(t, 195)
	seedMultiFolderV195(t, raw)
	asksBefore := mfDump(t, raw, `SELECT `+ownerAskV195Cols+` FROM owner_asks ORDER BY id`)
	childrenBefore := mfDump(t, raw, ownerAskChildrenDump)
	require.Len(t, childrenBefore, 4)

	applyNextMigration(t, raw)
	assertNoFKViolations(t, raw)

	assert.Equal(t, asksBefore, mfDump(t, raw, `SELECT `+ownerAskV195Cols+` FROM owner_asks ORDER BY id`))
	assert.Equal(t, childrenBefore, mfDump(t, raw, ownerAskChildrenDump))
	assert.Equal(t, 32, mfCount(t, raw, `SELECT seq FROM sqlite_sequence WHERE name = 'owner_asks'`),
		"the AUTOINCREMENT high-water mark is carried")
	for _, idx := range []string{"idx_owner_asks_project", "idx_owner_asks_session"} {
		assert.True(t, tcObjectExists(t, raw, "index", idx), idx)
	}

	tcExec(t, raw, `INSERT INTO owner_asks (project_id, kind, title, payload) VALUES (1, 'folder', 'Add hub?', '{"path":"/tmp/code/hub"}')`)
	_, err := raw.Exec(`INSERT INTO owner_asks (project_id, kind, title) VALUES (1, 'review', 'No doc')`)
	assert.Error(t, err, "a review without doc_path is still refused")
	_, err = raw.Exec(`INSERT INTO owner_asks (project_id, kind, title) VALUES (1, 'nope', 'Bad')`)
	assert.Error(t, err, "an unknown kind is still refused")

	// The cascades and SET NULL links still work on the rebuilt table.
	tcExec(t, raw, `DELETE FROM owner_asks WHERE id = 30`)
	assert.Zero(t, mfCount(t, raw, `SELECT COUNT(*) FROM (`+ownerAskChildrenDump+`)`))
	assert.Equal(t, 1, mfCount(t, raw, `SELECT COUNT(*) FROM owner_asks WHERE id = 32 AND previous_ask_id IS NULL`))
	tcExec(t, raw, `DELETE FROM terminal_sessions WHERE id = 10`)
	assert.Equal(t, 1, mfCount(t, raw, `SELECT COUNT(*) FROM owner_asks WHERE id = 31 AND session_id IS NULL`))
}

func TestMigration00196_OwnerAsksGainDocFolder(t *testing.T) {
	t.Parallel()
	raw := migratedMultiFolder(t)
	assert.Equal(t, []string{"30 docs/spec.md <nil>", "31  <nil>", "32 docs/spec.md <nil>"},
		mfDump(t, raw, `SELECT id, doc_path, doc_folder_id FROM owner_asks ORDER BY id`))

	hub := mfCount(t, raw, `SELECT id FROM workbench_folders WHERE workbench_id = 2`)
	tcExec(t, raw, `INSERT INTO owner_asks (id, project_id, kind, title, doc_path, doc_folder_id)
		VALUES (33, 1, 'review', 'Hub spec', 'docs/hub.md', ?)`, hub)
	tcExec(t, raw, `DELETE FROM workbench_folders WHERE id = ?`, hub)
	assert.Equal(t, 1, mfCount(t, raw, `SELECT COUNT(*) FROM owner_asks WHERE id = 33 AND doc_folder_id IS NULL`),
		"a gone folder clears the link, the ask stays")
}

func TestMigration00196_OldReviewThreadsAndPRStatesResolveForTheHomeFolder(t *testing.T) {
	t.Parallel()
	raw := migratedMultiFolder(t)
	app := int64(mfCount(t, raw, `SELECT id FROM workbench_folders WHERE workbench_id = 1`))

	assert.Equal(t, 50, mfCount(t, raw, `SELECT conversation_id FROM review_reviewer_threads
		WHERE project_id = 1 AND workbench_folder_id = ? AND branch = 'main'`, app))
	assert.Equal(t, []string{"1 branch:main open", "2 pr:7 merged"}, mfDump(t, raw, `SELECT s.project_id, s.ref, s.state
		FROM workbench_pr_states s JOIN workbench_folders f ON f.id = s.workbench_folder_id AND f.workbench_id = s.project_id
		ORDER BY s.project_id`))

	// Another folder of the bench keys its own rows.
	tcExec(t, raw, `INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
		VALUES (1, '/tmp/code/site', 1, 'owner', 'site')`)
	site := int64(mfCount(t, raw, `SELECT id FROM workbench_folders WHERE folder_path = '/tmp/code/site'`))
	tcExec(t, raw, `INSERT INTO chat_conversations (id, title, context_type, context_id, created_at, updated_at)
		VALUES (51, 'Reviewer: main', 'review_reviewer', '1:main', 0, 0)`)
	tcExec(t, raw, `INSERT INTO review_reviewer_threads (project_id, workbench_folder_id, branch, conversation_id)
		VALUES (1, ?, 'main', 51)`, site)
	tcExec(t, raw, `INSERT INTO workbench_pr_states (project_id, workbench_folder_id, ref, state, checked_at)
		VALUES (1, ?, 'branch:main', 'none', '2026-11-02T00:00:00Z')`, site)
	assert.Equal(t, 2, mfCount(t, raw, `SELECT COUNT(*) FROM review_reviewer_threads WHERE project_id = 1`))
	assert.Equal(t, 2, mfCount(t, raw, `SELECT COUNT(*) FROM workbench_pr_states WHERE project_id = 1`))

	// The thread's delete trigger survived the rebuild.
	tcExec(t, raw, `DELETE FROM workbench_folders WHERE id = ?`, site)
	assert.Zero(t, mfCount(t, raw, `SELECT COUNT(*) FROM chat_conversations WHERE id = 51`))
	assert.Equal(t, 1, mfCount(t, raw, `SELECT COUNT(*) FROM chat_conversations WHERE id = 50`))
}

// Entries indexed from a privacy-protected folder are never rebuilt by the
// daemon: the migration rekeys every wbdoc row in place, searchable.
func TestMigration00196_RekeysWorkbenchDocIndexRows(t *testing.T) {
	t.Parallel()
	raw := migratedMultiFolder(t)
	app := mfCount(t, raw, `SELECT id FROM workbench_folders WHERE workbench_id = 1`)
	key := fmt.Sprintf("wbdoc:1:%d:README.md", app)
	assert.Equal(t, []string{"jira:ACME-1", key}, mfDump(t, raw, `SELECT id FROM kb_documents ORDER BY id`))
	assert.Equal(t, []string{"jira:ACME-1", key}, mfDump(t, raw, `SELECT doc_id FROM kb_chunks ORDER BY doc_id`))
	assert.Equal(t, []string{key}, mfDump(t, raw, `SELECT c.doc_id FROM kb_fts JOIN kb_chunks c ON c.id = kb_fts.rowid
		WHERE kb_fts MATCH 'hello'`), "the rekeyed entry is still found by search")
	assert.Equal(t, 1, mfCount(t, raw, `SELECT COUNT(*) FROM kb_fts WHERE kb_fts MATCH 'issue'`))
	assert.Equal(t, []string{"project_doc " + key}, mfDump(t, raw, `SELECT source, key FROM kb_dirty WHERE source = 'project_doc'`))
}

func TestMigration00196_DownAndUpAgain(t *testing.T) {
	t.Parallel()
	raw := migratedMultiFolder(t)
	tcExec(t, raw, `INSERT INTO owner_asks (project_id, kind, title) VALUES (1, 'folder', 'Add hub?')`)
	tcExec(t, raw, `INSERT INTO workbench_folders (id, workbench_id, folder_path, position, added_by, name)
		VALUES (90, 1, '/tmp/code/site', 1, 'owner', 'site')`)
	tcExec(t, raw, `INSERT INTO kb_documents (id, source, title) VALUES ('wbdoc:1:90:README.md', 'project_doc', 'site readme')`)
	tcExec(t, raw, `INSERT INTO kb_chunks (doc_id, idx, body) VALUES ('wbdoc:1:90:README.md', 0, 'site text')`)
	require.NoError(t, gooseDownTo(raw, "migrations", 195))
	assert.Zero(t, mfCount(t, raw, `SELECT COUNT(*) FROM kb_fts WHERE kb_fts MATCH 'site'`),
		"another folder's document, whose old key would collide, goes")
	assertNoFKViolations(t, raw)
	assert.False(t, tcObjectExists(t, raw, "table", "workbench_folders"))
	assert.Zero(t, mfCount(t, raw, `SELECT COUNT(*) FROM owner_asks WHERE kind = 'folder'`))
	assert.Equal(t, 4, mfCount(t, raw, `SELECT COUNT(*) FROM (`+ownerAskChildrenDump+`)`))
	assert.Equal(t, 50, mfCount(t, raw, `SELECT conversation_id FROM review_reviewer_threads WHERE project_id = 1 AND branch = 'main'`))
	assert.Equal(t, 2, mfCount(t, raw, `SELECT COUNT(*) FROM workbench_pr_states`))
	assert.False(t, tcHasColumn(t, raw, "terminal_sessions", "workbench_folder_id"))
	assert.False(t, tcHasColumn(t, raw, "targets", "workbench_folder_id"))
	assert.Equal(t, []string{"jira:ACME-1", "wbdoc:1:README.md"}, mfDump(t, raw, `SELECT id FROM kb_documents ORDER BY id`),
		"the home folder's documents get their old keys back")
	assert.Equal(t, []string{"jira:ACME-1", "wbdoc:1:README.md"}, mfDump(t, raw, `SELECT doc_id FROM kb_chunks ORDER BY doc_id`))
	applyNextMigration(t, raw)
	assertNoFKViolations(t, raw)
}

// A legacy bench whose only folder 00196 marked removed (another spelling of
// an older bench's folder) still has a home: its report and PR cache work.
func TestMigration00196_LegacyDuplicateBenchKeepsAHome(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "w.db")
	d, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	require.NoError(t, gooseDownTo(d.DB, "migrations", 195))
	_, err = d.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (1, 'a', '/tmp/Code/App'), (2, 'b', '/tmp/code/app')`)
	require.NoError(t, err)
	require.NoError(t, gooseUp(d.DB, "migrations"))

	home, err := d.HomeFolder(ctx, 2)
	require.NoError(t, err)
	assert.Equal(t, int64(2), home.WorkbenchID)
	assert.True(t, home.RemovedAt.Valid, "its only row, removed")
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: 2, FolderID: home.ID, Ref: "pr:1", State: "open",
		CheckedAt: "2026-11-18T00:00:00Z"}))
	got, err := d.PRStates(2, home.ID)
	require.NoError(t, err)
	assert.Equal(t, "open", got["pr:1"].State)
	live, err := d.HomeFolderID(ctx, 1)
	require.NoError(t, err)
	assert.NotEqual(t, home.ID, live)
}

// `workbench asks` and the ask guard open the database without migrating:
// on a 00195 database the asks and the session row read with NULL folders.
func TestMigration00196_UnmigratedReadersStillReadAsksAndSessions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.db")
	d, err := Open(path)
	require.NoError(t, err)
	wb := newTestWorkbench(t, d)
	sid := newTestSession(t, d, wb)
	ask := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: wb, SessionID: nullID(sid), Kind: AskKindQuestion, Title: "Which?"})
	require.NoError(t, gooseDownTo(d.DB, "migrations", 195))
	require.NoError(t, d.Close())

	old, err := OpenExisting(path, 100*time.Millisecond)
	require.NoError(t, err)
	t.Cleanup(func() { _ = old.Close() })
	list, err := old.ListOwnerAsks(wb, OwnerAskFilter{Statuses: []string{"open"}})
	require.NoError(t, err)
	require.Len(t, list, 1)
	assert.False(t, list[0].DocFolderID.Valid)
	got, err := old.GetOwnerAsk(wb, ask)
	require.NoError(t, err)
	assert.Equal(t, "Which?", got.Title)
	s, err := old.GetTerminalSession(sid)
	require.NoError(t, err)
	assert.False(t, s.WorkbenchFolderID.Valid)
	assert.False(t, s.ParentSessionID.Valid)
}
