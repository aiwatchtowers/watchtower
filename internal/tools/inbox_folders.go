package tools

import (
	"context"
	"fmt"

	"watchtower/internal/db"
	"watchtower/internal/inboxfolders"
)

// inboxFolderRow is one folder of list_inbox_folders: its title, the slug a
// recipe's output.inbox({folder}) and a folder suggestion name it by, its
// parent's slug ("" for the root) and whether the owner hid it (itself or a
// folder above it): its artifacts still arrive, out of the menu.
type inboxFolderRow struct {
	Title      string `json:"title"`
	Slug       string `json:"slug"`
	ParentSlug string `json:"parent_slug"`
	Hidden     bool   `json:"hidden"`
}

// NewListInboxFolders lists the Inbox menu's folders for the automation
// editor chat (inbox builder B, "Creating a folder from the editor"), so it
// reuses a folder instead of proposing a duplicate. The root is listed
// (slug "inbox", the default parent); Needs approval is not: nothing but its
// own built-in goes there and no folder sits under it.
func NewListInboxFolders() *Tool {
	return &Tool{
		Name: "list_inbox_folders",
		Description: "List the owner's Inbox folders in menu order: title, slug, parent_slug (\"\" for the root, " +
			"slug \"inbox\") and hidden (the owner hid it or a folder above it). Read it before suggesting a " +
			"folder in draft_automation's folder argument: reuse an existing folder's title and parent_slug " +
			"rather than proposing a near-duplicate. An unknown parent_slug puts a new folder at the root.",
		InputSchema: mustSchema[struct{}]("list_inbox_folders"),
		Access:      AccessRead,
		Surfaces:    []string{AutomationEditorSurface},
		Execute: func(ctx context.Context, d *db.DB, _ Call) (any, error) {
			tree, err := inboxfolders.NewStore(d).List(ctx)
			if err != nil {
				return nil, fmt.Errorf("reading the Inbox folders: %w", err)
			}
			return map[string]any{"folders": inboxFolderRows(tree)}, nil
		},
	}
}

// inboxFolderRows renders tree (pre-order) without Needs approval; a folder
// is hidden when it or any folder above it is (never nil).
func inboxFolderRows(tree inboxfolders.Tree) []inboxFolderRow {
	slugs := map[int64]string{}
	hidden := map[int64]bool{}
	rows := []inboxFolderRow{}
	for _, f := range tree.Folders {
		slugs[f.ID] = f.Slug
		parentSlug := ""
		hide := f.Hidden
		if f.ParentID != nil {
			parentSlug = slugs[*f.ParentID]
			hide = hide || hidden[*f.ParentID]
		}
		hidden[f.ID] = hide
		if f.Kind == inboxfolders.KindApprovals {
			continue
		}
		rows = append(rows, inboxFolderRow{Title: f.Title, Slug: f.Slug, ParentSlug: parentSlug, Hidden: hide})
	}
	return rows
}
