package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"unicode/utf8"
)

// InboxFolder is one row of inbox_folders (00175): the root (kind 'root',
// ParentID nil), Needs approval (kind 'approvals') or an owner folder. The
// folder tables hold the Inbox menu's arrangement only, never an item
// (STRIP-02). Only Go writes them (the CLI through WithInboxFolderRevision,
// the built-in indexer's route seed, a run's commit); the Desktop never.
type InboxFolder struct {
	ID                      int64
	Kind, Slug, Title, Icon string
	ParentID                *int64
	Position                int
	Hidden                  bool
}

// ErrInboxRevisionConflict is the refusal of a folder write whose expected
// revision is not the tree's: nothing was written. Now is the tree's
// revision, Given the caller's.
type ErrInboxRevisionConflict struct{ Now, Given int64 }

func (e *ErrInboxRevisionConflict) Error() string {
	return fmt.Sprintf("inbox folder revision conflict (revision %d, you had %d)", e.Now, e.Given)
}

// InboxFolderTree reads the folder tree in one read-only transaction: the
// tree's revision, every folder (the root first, then grouped by parent id,
// each sibling list in position order; pre-order is the caller's) and the
// routes (automation id → folder id).
func (db *DB) InboxFolderTree(ctx context.Context) (revision int64, folders []InboxFolder, routes map[int64]int64, err error) {
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return 0, nil, nil, fmt.Errorf("reading the inbox folder tree: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	if revision, err = inboxFolderRevisionTx(ctx, tx); err != nil {
		return 0, nil, nil, err
	}
	if folders, routes, err = InboxFolderTreeTx(ctx, tx); err != nil {
		return 0, nil, nil, err
	}
	return revision, folders, routes, nil
}

// InboxFolderTreeTx reads the folders (InboxFolderTree's order) and the
// routes inside tx: a folder write reads the tree it validates against, and
// the tree it returns, in its own WithInboxFolderRevision transaction.
func InboxFolderTreeTx(ctx context.Context, tx *sql.Tx) ([]InboxFolder, map[int64]int64, error) {
	folders, err := inboxFoldersTx(ctx, tx)
	if err != nil {
		return nil, nil, err
	}
	routes, err := inboxFolderRoutesTx(ctx, tx)
	if err != nil {
		return nil, nil, err
	}
	return folders, routes, nil
}

func inboxFolderRevisionTx(ctx context.Context, tx *sql.Tx) (int64, error) {
	var rev int64
	if err := tx.QueryRowContext(ctx, `SELECT revision FROM inbox_folder_state WHERE id = 1`).Scan(&rev); err != nil {
		return 0, fmt.Errorf("reading the inbox folder revision: %w", err)
	}
	return rev, nil
}

func inboxFoldersTx(ctx context.Context, tx *sql.Tx) ([]InboxFolder, error) {
	rows, err := tx.QueryContext(ctx, `SELECT id, kind, slug, title, icon, parent_id, position, hidden
		FROM inbox_folders ORDER BY parent_id IS NOT NULL, parent_id, position, id`)
	if err != nil {
		return nil, fmt.Errorf("reading inbox folders: %w", err)
	}
	defer rows.Close()
	folders := []InboxFolder{}
	for rows.Next() {
		var (
			f      InboxFolder
			parent sql.NullInt64
		)
		if err := rows.Scan(&f.ID, &f.Kind, &f.Slug, &f.Title, &f.Icon, &parent, &f.Position, &f.Hidden); err != nil {
			return nil, fmt.Errorf("scanning an inbox folder: %w", err)
		}
		if parent.Valid {
			p := parent.Int64
			f.ParentID = &p
		}
		folders = append(folders, f)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading inbox folders: %w", err)
	}
	return folders, nil
}

func inboxFolderRoutesTx(ctx context.Context, tx *sql.Tx) (map[int64]int64, error) {
	rows, err := tx.QueryContext(ctx, `SELECT automation_id, folder_id FROM inbox_folder_routes`)
	if err != nil {
		return nil, fmt.Errorf("reading inbox folder routes: %w", err)
	}
	defer rows.Close()
	routes := map[int64]int64{}
	for rows.Next() {
		var automationID, folderID int64
		if err := rows.Scan(&automationID, &folderID); err != nil {
			return nil, fmt.Errorf("scanning an inbox folder route: %w", err)
		}
		routes[automationID] = folderID
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading inbox folder routes: %w", err)
	}
	return routes, nil
}

// WithInboxFolderRevision runs one folder or route write as a compare-and-set
// on the tree's revision: in one BEGIN IMMEDIATE transaction it reads the
// revision, refuses with *ErrInboxRevisionConflict (fn not called, nothing
// written) when it is not expect, else runs fn and bumps the revision. An fn
// error rolls everything back and is returned as is. It returns the new
// revision. Never retried here: a write computed against a stale tree could
// land in the wrong place, so the caller re-reads.
func (db *DB) WithInboxFolderRevision(ctx context.Context, expect int64, fn func(tx *sql.Tx) error) (newRevision int64, err error) {
	tx, err := db.BeginTx(ctx, nil) // BEGIN IMMEDIATE (_txlock=immediate)
	if err != nil {
		return 0, fmt.Errorf("starting an inbox folder write: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	now, err := inboxFolderRevisionTx(ctx, tx)
	if err != nil {
		return 0, err
	}
	if now != expect {
		return 0, &ErrInboxRevisionConflict{Now: now, Given: expect}
	}
	if err := fn(tx); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE inbox_folder_state SET revision = revision + 1 WHERE id = 1`); err != nil {
		return 0, fmt.Errorf("bumping the inbox folder revision: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("committing an inbox folder write: %w", err)
	}
	return now + 1, nil
}

// ErrNoInboxArtifact is InboxArtifactFolder's answer for an id that is not
// an inbox artifact (no such output, or one of another kind).
var ErrNoInboxArtifact = errors.New("no inbox artifact")

// InboxArtifactFolder returns the effective folder of an inbox artifact
// (inbox_artifact_folders: its explicit folder ?? its automation's route ??
// the root).
func (db *DB) InboxArtifactFolder(ctx context.Context, outputID int64) (int64, error) {
	var folderID int64
	err := db.QueryRowContext(ctx, `SELECT folder_id FROM inbox_artifact_folders WHERE output_id = ?`, outputID).Scan(&folderID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, fmt.Errorf("inbox artifact %d: %w", outputID, ErrNoInboxArtifact)
	}
	if err != nil {
		return 0, fmt.Errorf("reading the folder of inbox artifact %d: %w", outputID, err)
	}
	return folderID, nil
}

// outputFolderSQL finds the folder a recipe's output.inbox({folder}) names:
// the folder with that slug, except Needs approval for any automation but
// the needs-approval built-in (Needs approval holds only its own approvals).
// Arguments: the slug, the automation id (0 = none, as in a draft).
const outputFolderSQL = `SELECT f.id, f.title FROM inbox_folders f WHERE f.slug = ?
	AND (f.kind <> 'approvals' OR EXISTS (SELECT 1 FROM automations a
		WHERE a.id = ? AND a.origin = 'builtin' AND a.builtin_id = 'needs-approval'))`

// routeTitleSQL is the title of the folder automation ? writes into: its
// route's folder, else the root's.
const routeTitleSQL = `SELECT COALESCE(
	(SELECT f.title FROM inbox_folder_routes r JOIN inbox_folders f ON f.id = r.folder_id WHERE r.automation_id = ?),
	(SELECT title FROM inbox_folders WHERE kind = 'root'), 'Inbox')`

// InboxFolderForOutput is the folder output.inbox({folder: slug}) of
// automation automationID (0 = a draft with none) would land in: its id
// and title, found = false when no such folder may take it. A dry run's
// preview reads it; a run's commit resolves the slug in its own transaction.
func (db *DB) InboxFolderForOutput(ctx context.Context, automationID int64, slug string) (id int64, title string, found bool, err error) {
	err = db.QueryRowContext(ctx, outputFolderSQL, slug, automationID).Scan(&id, &title)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, "", false, nil
	}
	if err != nil {
		return 0, "", false, fmt.Errorf("reading inbox folder %q: %w", slug, err)
	}
	return id, title, true, nil
}

// resolveOutputFolderTx is output o's folder_id inside a run's commit
// transaction: o.FolderID when the recipe named no folder, else the folder
// with o.FolderSlug. A slug no folder takes (never created, or deleted
// after the call) is NULL — the card follows its route — and the run's
// journal gets a log step saying where it went, in the same transaction.
// Resolving here, not at the call, keeps a folder delete from failing the
// commit: a delete is a BEGIN IMMEDIATE transaction too, so it lands wholly
// before the lookup or wholly after the insert.
func resolveOutputFolderTx(tx *sql.Tx, automationID, runID int64, stamp string, o AutomationOutput) (*int64, error) {
	if o.FolderSlug == "" {
		return o.FolderID, nil
	}
	var id int64
	var title string
	err := tx.QueryRow(outputFolderSQL, o.FolderSlug, automationID).Scan(&id, &title)
	if err == nil {
		return &id, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("reading inbox folder %q: %w", o.FolderSlug, err)
	}
	var route string
	if err := tx.QueryRow(routeTitleSQL, automationID).Scan(&route); err != nil {
		return nil, fmt.Errorf("reading the inbox folder of automation %d: %w", automationID, err)
	}
	line := clipStepText(fmt.Sprintf("folder %q not found — shown in %s", o.FolderSlug, route))
	if _, err := tx.Exec(`INSERT INTO automation_run_steps (run_id, seq, kind, name, args_json, status, started_at, finished_at)
		VALUES (?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM automation_run_steps WHERE run_id = ?), 'log', 'log', ?, 'ok', ?, ?)`,
		runID, runID, line, stamp, stamp); err != nil {
		return nil, fmt.Errorf("journaling the missing folder %q: %w", o.FolderSlug, err)
	}
	return nil, nil
}

// StepClipBytes is the most a journal step's args_json or result_summary
// holds (automations.StepClipBytes is this constant).
const StepClipBytes = 4 * 1024

// clipStepText cuts s to StepClipBytes on a rune boundary, as the journal
// clips the steps it writes.
func clipStepText(s string) string {
	if len(s) <= StepClipBytes {
		return s
	}
	cut := StepClipBytes
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut]
}

// SeedInboxFolderRoute routes automation automationID to the folder with
// slug folderSlug only when it has no route yet (the built-in indexer's
// seed of a built-in's default folder), so a route the owner set later is
// kept. A plain read first: an automation with a route (every sync after
// the first) takes no write lock. A seed that writes bumps the tree's
// revision, in the same BEGIN IMMEDIATE transaction, so a client holding the
// old tree re-reads it; the insert still yields to a route written between
// the read and the write. It reports whether it wrote; a slug no folder has
// is an error, nothing written.
func (db *DB) SeedInboxFolderRoute(ctx context.Context, automationID int64, folderSlug string) (seeded bool, err error) {
	var routed bool
	if err := db.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM inbox_folder_routes WHERE automation_id = ?)`,
		automationID).Scan(&routed); err != nil {
		return false, fmt.Errorf("reading the route of automation %d: %w", automationID, err)
	}
	if routed {
		return false, nil
	}
	tx, err := db.BeginTx(ctx, nil) // BEGIN IMMEDIATE (_txlock=immediate)
	if err != nil {
		return false, fmt.Errorf("starting the route seed of automation %d: %w", automationID, err)
	}
	defer func() { _ = tx.Rollback() }()

	var folderID int64
	err = tx.QueryRowContext(ctx, `SELECT id FROM inbox_folders WHERE slug = ?`, folderSlug).Scan(&folderID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("seeding the route of automation %d: no inbox folder %q", automationID, folderSlug)
	}
	if err != nil {
		return false, fmt.Errorf("seeding the route of automation %d: %w", automationID, err)
	}
	res, err := tx.ExecContext(ctx, `INSERT INTO inbox_folder_routes (automation_id, folder_id) VALUES (?, ?)
		ON CONFLICT (automation_id) DO NOTHING`, automationID, folderID)
	if err != nil {
		return false, fmt.Errorf("seeding the route of automation %d: %w", automationID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("seeding the route of automation %d: %w", automationID, err)
	}
	if n == 0 {
		return false, nil // it has a route: the owner's, or an earlier seed
	}
	if _, err := tx.ExecContext(ctx, `UPDATE inbox_folder_state SET revision = revision + 1 WHERE id = 1`); err != nil {
		return false, fmt.Errorf("bumping the inbox folder revision: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("committing the route seed of automation %d: %w", automationID, err)
	}
	return true, nil
}
