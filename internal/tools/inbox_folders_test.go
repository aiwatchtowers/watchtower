package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/inboxfolders"
)

func listInboxFolders(t *testing.T, d *db.DB) []inboxFolderRow {
	t.Helper()
	res, err := NewListInboxFolders().Execute(context.Background(), d, Call{Args: json.RawMessage(`{}`)})
	require.NoError(t, err)
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	var out struct {
		Folders []inboxFolderRow `json:"folders"`
	}
	require.NoError(t, json.Unmarshal(raw, &out))
	return out.Folders
}

func TestListInboxFolders_TreeWithHiddenBranchMarked(t *testing.T) {
	d := openDB(t)
	ctx := context.Background()
	s := inboxfolders.NewStore(d)
	rev := func() int64 {
		tree, err := s.List(ctx)
		require.NoError(t, err)
		return tree.Revision
	}
	_, release, err := s.Create(ctx, inboxfolders.CreateRequest{Title: "Release", ExpectRevision: rev()})
	require.NoError(t, err)
	_, _, err = s.Create(ctx, inboxfolders.CreateRequest{Title: "Q4", ParentID: &release.ID, ExpectRevision: rev()})
	require.NoError(t, err)
	_, _, err = s.Create(ctx, inboxfolders.CreateRequest{Title: "Acme", ExpectRevision: rev()})
	require.NoError(t, err)
	hide := true
	_, _, err = s.Update(ctx, release.ID, inboxfolders.UpdateRequest{Hidden: &hide, ExpectRevision: rev()})
	require.NoError(t, err)

	assert.Equal(t, []inboxFolderRow{
		{Title: "Inbox", Slug: "inbox", ParentSlug: "", Hidden: false},
		{Title: "Release", Slug: "release", ParentSlug: "inbox", Hidden: true},
		{Title: "Q4", Slug: "q4", ParentSlug: "release", Hidden: true},
		{Title: "Acme", Slug: "acme", ParentSlug: "inbox", Hidden: false},
	}, listInboxFolders(t, d), "menu order, Needs approval left out, a hidden folder's children marked hidden too")
}

func TestListInboxFolders_EditorSurfaceOnly(t *testing.T) {
	tool := NewListInboxFolders()
	assert.Equal(t, AccessRead, tool.Access)
	assert.Equal(t, []string{AutomationEditorSurface}, tool.Surfaces)
	assert.False(t, tool.CompanyData, "folder titles are the owner's own menu (READ-01 unmarked list)")
	assert.Empty(t, UndecidedReadTools([]*Tool{tool}))
}

func TestListInboxFolders_ReadErrorIsToolError(t *testing.T) {
	d := openDB(t)
	require.NoError(t, d.Close())
	res, err := NewListInboxFolders().Execute(context.Background(), d, Call{Args: json.RawMessage(`{}`)})
	require.Error(t, err, "a failed read is the tool's error, never an empty menu")
	assert.Nil(t, res)
	assert.Contains(t, err.Error(), "reading the Inbox folders")
}
