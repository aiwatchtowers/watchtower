// Package inboxfolders is the Inbox menu's folder tree: its rules (the fixed
// root and Needs approval, depth, count, titles, icons, slugs) and its five
// writes. Every write is one compare-and-set on the tree's revision
// (db.WithInboxFolderRevision); a stale revision writes nothing and is never
// retried here. The folder tables hold the menu's arrangement only, never an
// item (STRIP-02): deleting a folder moves its contents to its parent and
// deletes nothing else (FOLDER-01).
package inboxfolders

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"watchtower/internal/db"
)

// Folder kinds (inbox_folders.kind).
const (
	kindRoot      = "root"
	kindApprovals = "approvals"
	kindOwner     = "owner"
)

// needsApprovalBuiltinID is the built-in automation whose route is fixed to
// Needs approval, and the only automation routed there.
const needsApprovalBuiltinID = "needs-approval"

// Folder is one folder of the tree with the automations routed to it
// (ascending ids, never nil).
type Folder struct {
	db.InboxFolder
	AutomationIDs []int64
}

// Tree is the folder tree at Revision, in pre-order: the root, then each
// folder followed by its children in position order.
type Tree struct {
	Revision int64
	Folders  []Folder
}

// find returns the folder with id, if the tree holds it.
func (t Tree) find(id int64) (Folder, bool) {
	for _, f := range t.Folders {
		if f.ID == id {
			return f, true
		}
	}
	return Folder{}, false
}

// CreateRequest is a new owner folder. ParentID nil = the root; Position nil
// = last among its siblings, past the end = last.
type CreateRequest struct {
	Title, Icon    string
	ParentID       *int64
	Position       *int
	ExpectRevision int64
}

// UpdateRequest changes the non-nil fields of an owner folder.
type UpdateRequest struct {
	Title, Icon    *string
	Hidden         *bool
	ExpectRevision int64
}

// RouteRequest sets an automation's folder: an existing FolderID, or a new
// folder NewTitle (NewIcon, under ParentID, nil = the root) created in the
// same transaction. Exactly one of FolderID and NewTitle.
type RouteRequest struct {
	FolderID          *int64
	NewTitle, NewIcon string
	ParentID          *int64
	ExpectRevision    int64
}

// Moved counts what a delete moved to the deleted folder's parent: its
// child folders, the automations routed to it and the artifacts placed in it
// explicitly. Renamed lists the moved folders whose title clashed with one
// of the parent's children (never nil).
type Moved struct {
	Folders, Automations, Artifacts int
	Renamed                         []Renamed
}

// Renamed is a folder a delete moved up under a new title: From clashed,
// ignoring case, with a title among its new siblings. Its slug is unchanged.
type Renamed struct {
	ID       int64
	From, To string
}

// Store reads and writes the folder tree.
type Store struct {
	db *db.DB
}

// NewStore returns a Store over d.
func NewStore(d *db.DB) *Store { return &Store{db: d} }

// List reads the tree.
func (s *Store) List(ctx context.Context) (Tree, error) {
	rev, folders, routes, err := s.db.InboxFolderTree(ctx)
	if err != nil {
		return Tree{}, err
	}
	snap, err := newSnapshot(folders, routes)
	if err != nil {
		return Tree{}, err
	}
	return snap.tree(rev), nil
}

// Create adds an owner folder.
func (s *Store) Create(ctx context.Context, req CreateRequest) (Tree, Folder, error) {
	if req.ExpectRevision < 1 {
		return Tree{}, Folder{}, ErrRevisionRequired
	}
	title, err := cleanTitle(req.Title)
	if err != nil {
		return Tree{}, Folder{}, err
	}
	if err := checkIcon(req.Icon); err != nil {
		return Tree{}, Folder{}, err
	}
	if req.Position != nil && *req.Position < 0 {
		return Tree{}, Folder{}, ErrBadPosition
	}
	var id int64
	tree, err := s.write(ctx, req.ExpectRevision, func(tx *sql.Tx, snap *snapshot) error {
		id, err = createTx(ctx, tx, snap, title, req.Icon, req.ParentID, req.Position)
		return err
	})
	if err != nil {
		return Tree{}, Folder{}, err
	}
	return tree, mustFind(tree, id), nil
}

// Update renames, re-icons or hides an owner folder (a rename keeps the slug).
func (s *Store) Update(ctx context.Context, id int64, req UpdateRequest) (Tree, Folder, error) {
	if req.ExpectRevision < 1 {
		return Tree{}, Folder{}, ErrRevisionRequired
	}
	var title string
	if req.Title != nil {
		t, err := cleanTitle(*req.Title)
		if err != nil {
			return Tree{}, Folder{}, err
		}
		title = t
	}
	if req.Icon != nil {
		if err := checkIcon(*req.Icon); err != nil {
			return Tree{}, Folder{}, err
		}
	}
	tree, err := s.write(ctx, req.ExpectRevision, func(tx *sql.Tx, snap *snapshot) error {
		f, err := snap.ownerFolder(id)
		if err != nil {
			return err
		}
		if req.Title != nil && snap.titleTaken(*f.ParentID, title, id) {
			return duplicateTitle(title)
		}
		next := *f
		if req.Title != nil {
			next.Title = title
		}
		if req.Icon != nil {
			next.Icon = *req.Icon
		}
		if req.Hidden != nil {
			next.Hidden = *req.Hidden
		}
		if _, err := tx.ExecContext(ctx, `UPDATE inbox_folders SET title = ?, icon = ?, hidden = ?,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`,
			next.Title, next.Icon, next.Hidden, id); err != nil {
			return fmt.Errorf("updating inbox folder %d: %w", id, err)
		}
		return nil
	})
	if err != nil {
		return Tree{}, Folder{}, err
	}
	return tree, mustFind(tree, id), nil
}

// Move re-parents and reorders an owner folder with its subtree: it lands at
// position among parentID's children (past the end = last; in the root,
// never before Needs approval). Both sibling lists are renumbered 0…n−1.
func (s *Store) Move(ctx context.Context, id, parentID int64, position int, expect int64) (Tree, Folder, error) {
	if expect < 1 {
		return Tree{}, Folder{}, ErrRevisionRequired
	}
	if position < 0 {
		return Tree{}, Folder{}, ErrBadPosition
	}
	tree, err := s.write(ctx, expect, func(tx *sql.Tx, snap *snapshot) error {
		f, err := snap.ownerFolder(id)
		if err != nil {
			return err
		}
		if err := snap.checkParent(parentID); err != nil {
			return err
		}
		if snap.within(parentID, id) {
			return ErrCycle
		}
		if snap.depth(parentID)+1+snap.height(id) > MaxDepth {
			return ErrTooDeep
		}
		oldParent := *f.ParentID
		if oldParent != parentID && snap.titleTaken(parentID, f.Title, id) {
			return duplicateTitle(f.Title)
		}
		if _, err := tx.ExecContext(ctx, `UPDATE inbox_folders SET parent_id = ?,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, parentID, id); err != nil {
			return fmt.Errorf("moving inbox folder %d: %w", id, err)
		}
		target := without(snap.children[parentID], id)
		at := snap.insertIndex(parentID, len(target), &position)
		target = slices.Insert(target, at, id)
		if err := renumber(ctx, tx, target); err != nil {
			return err
		}
		if oldParent != parentID {
			return renumber(ctx, tx, without(snap.children[oldParent], id))
		}
		return nil
	})
	if err != nil {
		return Tree{}, Folder{}, err
	}
	return tree, mustFind(tree, id), nil
}

// Delete removes an owner folder and nothing else (FOLDER-01): its child
// folders move to its parent, appended after the parent's children in their
// order; the automations routed to it and the artifacts placed in it
// explicitly move to the parent too. A moved child whose title clashes with
// one of the parent's children, ignoring case, gets " (2)", " (3)"… so
// titles stay unique among siblings; a delete is never refused for it. It
// returns the counts moved and the renames.
func (s *Store) Delete(ctx context.Context, id int64, expect int64) (Tree, Moved, error) {
	if expect < 1 {
		return Tree{}, Moved{}, ErrRevisionRequired
	}
	moved := Moved{Renamed: []Renamed{}}
	tree, err := s.write(ctx, expect, func(tx *sql.Tx, snap *snapshot) error {
		f, err := snap.ownerFolder(id)
		if err != nil {
			return err
		}
		parent := *f.ParentID
		kids := snap.children[id]
		moved.Renamed = snap.titlesMovingUp(id, parent)
		titles := map[int64]string{}
		for _, r := range moved.Renamed {
			titles[r.ID] = r.To
		}
		for _, kid := range kids {
			title, ok := titles[kid]
			if !ok {
				title = snap.byID[kid].Title
			}
			if _, err := tx.ExecContext(ctx, `UPDATE inbox_folders SET parent_id = ?, title = ?,
				updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, parent, title, kid); err != nil {
				return fmt.Errorf("moving inbox folder %d up: %w", kid, err)
			}
		}
		moved.Folders = len(kids)
		if moved.Automations, err = execCount(ctx, tx,
			`UPDATE inbox_folder_routes SET folder_id = ? WHERE folder_id = ?`, parent, id); err != nil {
			return fmt.Errorf("moving the routes of inbox folder %d up: %w", id, err)
		}
		if moved.Artifacts, err = execCount(ctx, tx,
			`UPDATE automation_outputs SET folder_id = ? WHERE folder_id = ?`, parent, id); err != nil {
			return fmt.Errorf("moving the artifacts of inbox folder %d up: %w", id, err)
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM inbox_folders WHERE id = ?`, id); err != nil {
			return fmt.Errorf("deleting inbox folder %d: %w", id, err)
		}
		return renumber(ctx, tx, append(without(snap.children[parent], id), kids...))
	})
	if err != nil {
		return Tree{}, Moved{}, err
	}
	return tree, moved, nil
}

// Route sets the folder automationID's artifacts go to (those a recipe
// placed explicitly stay put). A route is placement, not part of the recipe:
// it never touches the automation's row. With NewTitle the folder is created
// in the same transaction (created = true). The needs-approval built-in stays
// in Needs approval, and nothing else is routed there.
func (s *Store) Route(ctx context.Context, automationID int64, req RouteRequest) (Tree, Folder, bool, error) {
	if req.ExpectRevision < 1 {
		return Tree{}, Folder{}, false, ErrRevisionRequired
	}
	newFolder := req.NewTitle != ""
	if (req.FolderID != nil) == newFolder || (!newFolder && (req.NewIcon != "" || req.ParentID != nil)) {
		return Tree{}, Folder{}, false, ErrRouteTarget
	}
	var title string
	if newFolder {
		t, err := cleanTitle(req.NewTitle)
		if err != nil {
			return Tree{}, Folder{}, false, err
		}
		title = t
		if err := checkIcon(req.NewIcon); err != nil {
			return Tree{}, Folder{}, false, err
		}
	}
	var folderID int64
	tree, err := s.write(ctx, req.ExpectRevision, func(tx *sql.Tx, snap *snapshot) error {
		approvalsBuiltin, err := isNeedsApprovalBuiltin(ctx, tx, automationID)
		if err != nil {
			return err
		}
		switch {
		case newFolder && approvalsBuiltin:
			return ErrApprovalsRouteFixed
		case newFolder:
			if folderID, err = createTx(ctx, tx, snap, title, req.NewIcon, req.ParentID, nil); err != nil {
				return err
			}
		default:
			folderID = *req.FolderID
			if _, ok := snap.byID[folderID]; !ok {
				return noFolder(folderID)
			}
			if approvalsBuiltin && folderID != snap.approvalsID {
				return ErrApprovalsRouteFixed
			}
			if !approvalsBuiltin && folderID == snap.approvalsID {
				return ErrApprovalsHoldsNothingElse
			}
		}
		// A route to the root is a row too: a built-in's route seed fills
		// only a missing row, so the owner's move to the root must stay one.
		if _, err := tx.ExecContext(ctx, `INSERT INTO inbox_folder_routes (automation_id, folder_id) VALUES (?, ?)
			ON CONFLICT(automation_id) DO UPDATE SET folder_id = excluded.folder_id`, automationID, folderID); err != nil {
			return fmt.Errorf("routing automation %d: %w", automationID, err)
		}
		return nil
	})
	if err != nil {
		return Tree{}, Folder{}, false, err
	}
	return tree, mustFind(tree, folderID), newFolder, nil
}

// write runs fn as one compare-and-set write over the tree it reads in the
// same transaction, and returns the tree as written at the new revision.
func (s *Store) write(ctx context.Context, expect int64, fn func(tx *sql.Tx, snap *snapshot) error) (Tree, error) {
	var after *snapshot
	rev, err := s.db.WithInboxFolderRevision(ctx, expect, func(tx *sql.Tx) error {
		snap, err := readSnapshot(ctx, tx)
		if err != nil {
			return err
		}
		if err := fn(tx, snap); err != nil {
			return err
		}
		after, err = readSnapshot(ctx, tx)
		return err
	})
	var conflict *db.ErrInboxRevisionConflict
	if errors.As(err, &conflict) {
		return Tree{}, &ConflictError{db: conflict}
	}
	if err != nil {
		return Tree{}, err
	}
	return after.tree(rev), nil
}

// createTx inserts an owner folder under parentID (nil = root) at position
// (nil = last) after the tree's checks, and returns its id.
func createTx(ctx context.Context, tx *sql.Tx, snap *snapshot, title, icon string, parentID *int64, position *int) (int64, error) {
	parent := snap.rootID
	if parentID != nil {
		parent = *parentID
	}
	if err := snap.checkParent(parent); err != nil {
		return 0, err
	}
	if snap.depth(parent)+1 > MaxDepth {
		return 0, ErrTooDeep
	}
	if snap.ownerCount() >= MaxOwnerFolders {
		return 0, ErrTooMany
	}
	if snap.titleTaken(parent, title, 0) {
		return 0, duplicateTitle(title)
	}
	slug := uniqueSlug(title, snap.slugTaken)
	var id int64
	if err := tx.QueryRowContext(ctx, `INSERT INTO inbox_folders (kind, parent_id, slug, title, icon, position)
		VALUES ('owner', ?, ?, ?, ?, 0) RETURNING id`, parent, slug, title, icon).Scan(&id); err != nil {
		return 0, fmt.Errorf("creating inbox folder %q: %w", slug, err)
	}
	siblings := snap.children[parent]
	at := snap.insertIndex(parent, len(siblings), position)
	return id, renumber(ctx, tx, slices.Insert(slices.Clone(siblings), at, id))
}

// isNeedsApprovalBuiltin reports whether automationID is the needs-approval
// built-in; an unknown id is ErrNoAutomation.
func isNeedsApprovalBuiltin(ctx context.Context, tx *sql.Tx, automationID int64) (bool, error) {
	var origin string
	var builtinID sql.NullString
	err := tx.QueryRowContext(ctx, `SELECT origin, builtin_id FROM automations WHERE id = ?`, automationID).
		Scan(&origin, &builtinID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, refuse(ErrNoAutomation, "no automation %d", automationID)
	}
	if err != nil {
		return false, fmt.Errorf("reading automation %d: %w", automationID, err)
	}
	return origin == "builtin" && builtinID.String == needsApprovalBuiltinID, nil
}

// renumber writes positions 0…n−1 to ids in order, skipping rows already
// there.
func renumber(ctx context.Context, tx *sql.Tx, ids []int64) error {
	for pos, id := range ids {
		if _, err := tx.ExecContext(ctx, `UPDATE inbox_folders SET position = ? WHERE id = ? AND position != ?`,
			pos, id, pos); err != nil {
			return fmt.Errorf("renumbering inbox folder %d: %w", id, err)
		}
	}
	return nil
}

func execCount(ctx context.Context, tx *sql.Tx, query string, args ...any) (int, error) {
	res, err := tx.ExecContext(ctx, query, args...)
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	return int(n), err
}

func without(ids []int64, id int64) []int64 {
	return slices.DeleteFunc(slices.Clone(ids), func(x int64) bool { return x == id })
}

// mustFind returns the folder a write just wrote; the write read it back in
// its own transaction, so it is there.
func mustFind(tree Tree, id int64) Folder {
	f, _ := tree.find(id)
	return f
}

// snapshot is the tree in memory, read inside a write's transaction (at most
// MaxOwnerFolders + 2 rows) so every rule is checked against one state.
type snapshot struct {
	folders             []db.InboxFolder
	byID                map[int64]*db.InboxFolder
	children            map[int64][]int64 // parent id → ids in position order
	routes              map[int64]int64
	rootID, approvalsID int64
}

func readSnapshot(ctx context.Context, tx *sql.Tx) (*snapshot, error) {
	folders, routes, err := db.InboxFolderTreeTx(ctx, tx)
	if err != nil {
		return nil, err
	}
	return newSnapshot(folders, routes)
}

func newSnapshot(folders []db.InboxFolder, routes map[int64]int64) (*snapshot, error) {
	s := &snapshot{
		folders:  folders,
		byID:     make(map[int64]*db.InboxFolder, len(folders)),
		children: map[int64][]int64{},
		routes:   routes,
	}
	for i := range folders {
		f := &folders[i]
		s.byID[f.ID] = f
		switch f.Kind {
		case kindRoot:
			s.rootID = f.ID
		case kindApprovals:
			s.approvalsID = f.ID
		}
		if f.ParentID != nil {
			s.children[*f.ParentID] = append(s.children[*f.ParentID], f.ID)
		}
	}
	if s.rootID == 0 || s.approvalsID == 0 {
		return nil, errors.New("the inbox folder tree has no root or no Needs approval")
	}
	return s, nil
}

// ownerFolder returns the owner folder id, refusing the root, Needs
// approval and an unknown id.
func (s *snapshot) ownerFolder(id int64) (*db.InboxFolder, error) {
	f, ok := s.byID[id]
	switch {
	case !ok:
		return nil, noFolder(id)
	case f.Kind == kindRoot:
		return nil, ErrRootFixed
	case f.Kind == kindApprovals:
		return nil, ErrApprovalsFixed
	}
	return f, nil
}

// checkParent refuses a parent that does not exist or is Needs approval.
func (s *snapshot) checkParent(id int64) error {
	if _, ok := s.byID[id]; !ok {
		return noFolder(id)
	}
	if id == s.approvalsID {
		return ErrApprovalsHoldsNothingElse
	}
	return nil
}

// depth is the number of steps from id up to the root (the root is 0).
func (s *snapshot) depth(id int64) int {
	d := 0
	for f := s.byID[id]; f != nil && f.ParentID != nil; f = s.byID[*f.ParentID] {
		d++
	}
	return d
}

// height is how many levels lie below id (a leaf is 0).
func (s *snapshot) height(id int64) int {
	h := 0
	for _, kid := range s.children[id] {
		h = max(h, s.height(kid)+1)
	}
	return h
}

// within reports whether id is folder of or one of its descendants.
func (s *snapshot) within(id, of int64) bool {
	for f := s.byID[id]; f != nil; {
		if f.ID == of {
			return true
		}
		if f.ParentID == nil {
			return false
		}
		f = s.byID[*f.ParentID]
	}
	return false
}

func (s *snapshot) ownerCount() int {
	n := 0
	for _, f := range s.folders {
		if f.Kind == kindOwner {
			n++
		}
	}
	return n
}

// titleTaken reports whether a child of parent other than except carries
// title, ignoring case.
func (s *snapshot) titleTaken(parent int64, title string, except int64) bool {
	for _, id := range s.children[parent] {
		if id != except && strings.EqualFold(s.byID[id].Title, title) {
			return true
		}
	}
	return false
}

// titlesMovingUp renames the children of id that are moving up to parent
// whose title clashes, ignoring case, with one of parent's other children:
// "<title> (2)", "(3)"…, the first free among parent's children and every
// moving child's title, the title cut to keep MaxTitleRunes.
func (s *snapshot) titlesMovingUp(id, parent int64) []Renamed {
	taken := map[string]bool{}
	staying := map[string]bool{}
	for _, sib := range s.children[parent] {
		if sib != id {
			key := strings.ToLower(s.byID[sib].Title)
			staying[key], taken[key] = true, true
		}
	}
	for _, kid := range s.children[id] {
		taken[strings.ToLower(s.byID[kid].Title)] = true
	}
	renamed := []Renamed{}
	for _, kid := range s.children[id] {
		title := s.byID[kid].Title
		if !staying[strings.ToLower(title)] {
			continue
		}
		next := numberedTitle(title, taken)
		taken[strings.ToLower(next)] = true
		renamed = append(renamed, Renamed{ID: kid, From: title, To: next})
	}
	return renamed
}

// numberedTitle is title + " (n)" for the lowest n ≥ 2 not in taken
// (lower-cased keys), the title cut so the result fits MaxTitleRunes.
func numberedTitle(title string, taken map[string]bool) string {
	for n := 2; ; n++ {
		suffix := " (" + strconv.Itoa(n) + ")"
		base := []rune(title)
		if keep := MaxTitleRunes - utf8.RuneCountInString(suffix); len(base) > keep {
			base = base[:keep]
		}
		next := strings.TrimRightFunc(string(base), unicode.IsSpace) + suffix
		if !taken[strings.ToLower(next)] {
			return next
		}
	}
}

func (s *snapshot) slugTaken(slug string) bool {
	for _, f := range s.folders {
		if f.Slug == slug {
			return true
		}
	}
	return false
}

// insertIndex places a folder among n siblings of parent at position (nil =
// last), clamped to the list; in the root never before Needs approval,
// which is pinned first.
func (s *snapshot) insertIndex(parent int64, n int, position *int) int {
	if position == nil {
		return n
	}
	lowest := 0
	if parent == s.rootID {
		lowest = 1
	}
	return min(max(*position, lowest), n)
}

// tree renders the snapshot in pre-order at revision rev.
func (s *snapshot) tree(rev int64) Tree {
	automations := map[int64][]int64{}
	for automationID, folderID := range s.routes {
		automations[folderID] = append(automations[folderID], automationID)
	}
	out := Tree{Revision: rev, Folders: make([]Folder, 0, len(s.folders))}
	var visit func(id int64)
	visit = func(id int64) {
		ids := automations[id]
		if ids == nil {
			ids = []int64{}
		}
		slices.Sort(ids)
		out.Folders = append(out.Folders, Folder{InboxFolder: *s.byID[id], AutomationIDs: ids})
		for _, kid := range s.children[id] {
			visit(kid)
		}
	}
	visit(s.rootID)
	return out
}
