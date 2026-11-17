package inboxfeed

import (
	"context"
	"database/sql"
	"fmt"

	"watchtower/internal/tower/api"
)

// folderRow is one inbox_folders row.
type folderRow struct {
	ID       int64
	Kind     api.FolderKind
	ParentID *int64
	Slug     string
	Title    string
	Icon     string
	Position int
	Hidden   bool
}

// tree is the menu as one read sees it: the folders in pre-order (root,
// then each folder followed by its children by position, id) and the
// routes. The port of InboxFolderQueries.tree.
type tree struct {
	folders []folderRow
	byID    map[int64]folderRow
}

// rootOnly is a database without the folder seed rows: the root alone,
// with id 0. Everything shows in it.
func rootOnly() tree {
	root := folderRow{ID: 0, Kind: api.FolderRoot, Slug: "inbox", Title: "Inbox"}
	return tree{folders: []folderRow{root}, byID: map[int64]folderRow{0: root}}
}

// readTree reads the folders in pre-order. A folder not reachable from the
// root (impossible under the foreign keys) is left out.
func readTree(ctx context.Context, tx *sql.Tx) (tree, error) {
	rows, err := tx.QueryContext(ctx, `SELECT id, kind, parent_id, slug, title, icon, position, hidden
		FROM inbox_folders ORDER BY position, id`)
	if err != nil {
		return tree{}, fmt.Errorf("inboxfeed: reading the folders: %w", err)
	}
	defer rows.Close()
	var all []folderRow
	for rows.Next() {
		var f folderRow
		var kind string
		var parent sql.NullInt64
		if err := rows.Scan(&f.ID, &kind, &parent, &f.Slug, &f.Title, &f.Icon, &f.Position, &f.Hidden); err != nil {
			return tree{}, fmt.Errorf("inboxfeed: reading a folder: %w", err)
		}
		f.Kind = api.FolderKind(kind)
		if parent.Valid {
			p := parent.Int64
			f.ParentID = &p
		}
		all = append(all, f)
	}
	if err := rows.Err(); err != nil {
		return tree{}, fmt.Errorf("inboxfeed: reading the folders: %w", err)
	}
	var root *folderRow
	children := map[int64][]folderRow{}
	for i := range all {
		f := all[i]
		if f.Kind == api.FolderRoot && root == nil {
			root = &all[i]
		}
		if f.ParentID != nil {
			children[*f.ParentID] = append(children[*f.ParentID], f)
		}
	}
	if root == nil {
		return rootOnly(), nil
	}
	t := tree{byID: map[int64]folderRow{}}
	var visit func(f folderRow)
	visit = func(f folderRow) {
		if _, seen := t.byID[f.ID]; seen {
			return
		}
		t.byID[f.ID] = f
		t.folders = append(t.folders, f)
		for _, c := range children[f.ID] {
			visit(c)
		}
	}
	visit(*root)
	return t, nil
}

// root is the root folder (always first).
func (t tree) root() folderRow { return t.folders[0] }

// approvalsID is Needs approval's id, or the root's on a tree without it
// (its entries then show in the root).
func (t tree) approvalsID() int64 {
	for _, f := range t.folders {
		if f.Kind == api.FolderApprovals {
			return f.ID
		}
	}
	return t.root().ID
}

// hasApprovals reports whether the tree has Needs approval.
func (t tree) hasApprovals() bool {
	for _, f := range t.folders {
		if f.Kind == api.FolderApprovals {
			return true
		}
	}
	return false
}

// isVisible reports whether neither folder id nor any ancestor is hidden
// (InboxFolderTree.isVisible). An unknown id is not visible.
func (t tree) isVisible(id int64) bool {
	f, ok := t.byID[id]
	for steps := 0; ok && steps <= len(t.folders); steps++ {
		if f.Hidden {
			return false
		}
		if f.ParentID == nil {
			return true
		}
		f, ok = t.byID[*f.ParentID]
	}
	return false
}

// apiFolders is every folder of the tree with its counts.
func (s *snapshot) apiFolders() []api.Folder {
	out := make([]api.Folder, 0, len(s.tree.folders))
	for _, f := range s.tree.folders {
		out = append(out, api.Folder{
			ID: f.ID, Kind: f.Kind, Slug: f.Slug, Title: f.Title, Icon: f.Icon,
			ParentID: f.ParentID, Position: f.Position, Hidden: !s.tree.isVisible(f.ID),
			Count: s.counts[f.ID], Waiting: s.waiting[f.ID],
		})
	}
	return out
}
