package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/workbenchfiles"
)

// writeWorkbenchFile creates rel (and its directories) inside project id's folder.
func writeWorkbenchFile(t *testing.T, d *db.DB, projectID int64, rel, body string) {
	t.Helper()
	p, err := d.GetWorkbench(projectID)
	require.NoError(t, err)
	path := filepath.Join(p.FolderPath, rel)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(body), 0o644))
}

// DEV-06: a workbench document path never reaches a file outside the folder —
// not by `../`, an absolute path, a symlinked file or a symlinked directory —
// and only an existing .md/.txt regular file passes. The check
// (ResolveWorkbenchDocumentPath) is the one ask_owner's doc_path goes through.
func TestDev06_DocumentPathStaysInsideTheFolder(t *testing.T) {
	fx := newWorkbenchFixture(t)
	p, err := fx.d.GetWorkbench(fx.a)
	require.NoError(t, err)
	outsideDir := t.TempDir()
	outsideFile := filepath.Join(outsideDir, "secret.md")
	require.NoError(t, os.WriteFile(outsideFile, []byte("secret"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(filepath.Dir(p.FolderPath), "sibling.md"), []byte("x"), 0o644))
	require.NoError(t, os.MkdirAll(filepath.Join(p.FolderPath, "docs"), 0o755))
	require.NoError(t, os.Symlink(outsideFile, filepath.Join(p.FolderPath, "docs", "link.md")))
	require.NoError(t, os.Symlink(outsideDir, filepath.Join(p.FolderPath, "docs", "ext")))
	writeWorkbenchFile(t, fx.d, fx.a, "docs/diagram.pdf", "%PDF")
	require.NoError(t, os.MkdirAll(filepath.Join(p.FolderPath, "docs", "dir.md"), 0o755))

	for name, rel := range map[string]string{
		"dot-dot":           "../sibling.md",
		"nested dot-dot":    "docs/../../sibling.md",
		"absolute":          outsideFile,
		"symlinked file":    "docs/link.md",
		"symlinked dir":     "docs/ext/secret.md",
		"missing":           "docs/nope.md",
		"wrong extension":   "docs/diagram.pdf",
		"directory":         "docs/dir.md",
		"the folder itself": ".",
	} {
		_, err := ResolveWorkbenchDocumentPath(p.FolderPath, rel)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, name)
	}

	// The path itself may hold spaces and non-ASCII characters.
	writeWorkbenchFile(t, fx.d, fx.a, "docs/spec ü.md", "# Spec\n")
	rel, err := ResolveWorkbenchDocumentPath(p.FolderPath, "docs/spec ü.md")
	require.NoError(t, err)
	assert.Equal(t, "docs/spec ü.md", rel)
}

// Spec 2026-10-03 §4: attached documents are gone — attach_document is not a
// workbench tool any more, and list_comments refuses its document_id.
func TestDocumentsWereReplacedByAsks(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	for _, tool := range WorkbenchTools(workbenchfiles.Store{}) {
		assert.NotEqual(t, "attach_document", tool.Name)
	}
	_, ok := reg.Get("attach_document")
	assert.False(t, ok, "attach_document is not registered")

	for _, args := range []string{`{"document_id":1}`, `{"document_id":1,"target_id":1}`, `{"document_id":0}`} {
		_, err := reg.CallRead(context.Background(), "list_comments", json.RawMessage(args), directBinding(fx.a))
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, args)
		assert.Equal(t, "documents were replaced by asks — use ask_owner (kind review)", verr.Msg, args)
	}
}

// ResolveWorkbenchDocumentPath also takes an absolute path — resolved through
// symlinks, so a path into the folder via a symlinked parent still passes.
func TestResolveProjectDocumentPath(t *testing.T) {
	fx := newWorkbenchFixture(t)
	p, err := fx.d.GetWorkbench(fx.a)
	require.NoError(t, err)
	writeWorkbenchFile(t, fx.d, fx.a, "docs/specs/x.md", "# X\n")
	outsideFile := filepath.Join(t.TempDir(), "secret.md")
	require.NoError(t, os.WriteFile(outsideFile, []byte("secret"), 0o644))
	require.NoError(t, os.Symlink(outsideFile, filepath.Join(p.FolderPath, "docs", "link.md")))
	viaLink := filepath.Join(t.TempDir(), "folder-link")
	require.NoError(t, os.Symlink(p.FolderPath, viaLink))

	for name, path := range map[string]string{
		"relative":             "docs/specs/x.md",
		"absolute":             filepath.Join(p.FolderPath, "docs", "specs", "x.md"),
		"via a symlinked root": filepath.Join(viaLink, "docs", "specs", "x.md"),
	} {
		rel, err := ResolveWorkbenchDocumentPath(p.FolderPath, path)
		require.NoError(t, err, name)
		assert.Equal(t, "docs/specs/x.md", rel, name)
	}
	for name, path := range map[string]string{
		"empty":             " ",
		"absolute outside":  outsideFile,
		"symlink outside":   filepath.Join(p.FolderPath, "docs", "link.md"),
		"dot-dot":           "../x.md",
		"missing":           "docs/nope.md",
		"the folder itself": p.FolderPath,
	} {
		_, err := ResolveWorkbenchDocumentPath(p.FolderPath, path)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, name)
	}
}

func TestComments_AgentThreadLifecycle(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	ownerRoot, err := fx.d.AddWorkbenchComment(db.WorkbenchComment{WorkbenchID: fx.a,
		TargetID: nullInt(fx.aTarget), Author: "owner", Body: "tighten this"})
	require.NoError(t, err)

	fresh := callReadIn(t, reg, fx.a, "list_comments", `{}`)
	assert.Contains(t, fresh, `"body":"tighten this"`)
	assert.NotContains(t, fresh, "why?", "another project's comment is not listed")

	mustApply(t, reg, fx.a, "resolve_comment", fmt.Sprintf(`{"comment_id":%d,"reply":"Tightened.","reason":"addressed"}`, ownerRoot))
	root, err := fx.d.GetWorkbenchComment(ownerRoot)
	require.NoError(t, err)
	assert.Equal(t, "resolved", root.Status)
	thread := callReadIn(t, reg, fx.a, "list_comments", fmt.Sprintf(`{"target_id":%d}`, fx.aTarget))
	assert.Contains(t, thread, `"body":"Tightened."`)
	assert.Contains(t, thread, `"author":"agent"`)

	out := mustApply(t, reg, fx.a, "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"Which DB?","reason":"blocked"}`, fx.aTarget))
	c, err := fx.d.GetWorkbenchComment(int64(out["comment_id"].(float64)))
	require.NoError(t, err)
	assert.Equal(t, "agent", c.Author)
	assert.Equal(t, "claude-code", c.AgentLabel)
	assert.Equal(t, fx.a, c.WorkbenchID)

	reply := mustApply(t, reg, fx.a, "add_comment", fmt.Sprintf(`{"parent_id":%d,"body":"Answer?","reason":"r"}`, c.ID))
	_, err = proposeIn(t, reg, fx.a, "resolve_comment", fmt.Sprintf(`{"comment_id":%d,"reason":"r"}`, int64(reply["comment_id"].(float64))))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.True(t, strings.Contains(verr.Msg, "is a reply"), verr.Msg)

	for _, args := range []string{
		`{"body":"x","reason":"r"}`,
		fmt.Sprintf(`{"target_id":%d,"parent_id":%d,"body":"x","reason":"r"}`, fx.aTarget, c.ID),
		fmt.Sprintf(`{"target_id":%d,"body":" ","reason":"r"}`, fx.aTarget),
	} {
		_, err := proposeIn(t, reg, fx.a, "add_comment", args)
		require.ErrorAs(t, err, &verr, args)
	}
}

// Another project's target or comment and a missing one answer the same line
// — no existence oracle.
func TestListComments_RefusesAnotherProjectsTarget(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	for _, id := range []int64{fx.bTarget, 999} {
		_, err := reg.CallRead(context.Background(), "list_comments",
			json.RawMessage(fmt.Sprintf(`{"target_id":%d}`, id)), directBinding(fx.a))
		var verr *ValidationError
		require.ErrorAs(t, err, &verr)
		assert.Equal(t, fmt.Sprintf("target %d is not in this workbench", id), verr.Msg)
	}
	for _, id := range []int64{fx.bComment, 999} {
		_, err := proposeIn(t, reg, fx.a, "resolve_comment", fmt.Sprintf(`{"comment_id":%d,"reason":"r"}`, id))
		var verr *ValidationError
		require.ErrorAs(t, err, &verr)
		assert.Equal(t, fmt.Sprintf("comment %d is not in this workbench", id), verr.Msg)
	}
}

func nullInt(v int64) sql.NullInt64 { return sql.NullInt64{Int64: v, Valid: true} }

// resolve_comment's reply and status change are one transaction: a failure
// resolving the root leaves no reply behind, so a Retry cannot duplicate it.
func TestResolveComment_FailedResolveLeavesNoReply(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	root, err := fx.d.AddWorkbenchComment(db.WorkbenchComment{WorkbenchID: fx.a,
		TargetID: nullInt(fx.aTarget), Author: "owner", Body: "fix it"})
	require.NoError(t, err)
	_, err = fx.d.Exec(`CREATE TRIGGER fail_resolve BEFORE UPDATE OF status ON project_comments
		WHEN NEW.status = 'resolved' BEGIN SELECT RAISE(ABORT, 'boom'); END`)
	require.NoError(t, err)

	rc, err := proposeIn(t, reg, fx.a, "resolve_comment", fmt.Sprintf(`{"comment_id":%d,"reply":"Fixed.","reason":"r"}`, root))
	require.NoError(t, err)
	assert.Equal(t, "failed", rc.Status)
	replies := func() int {
		var n int
		require.NoError(t, fx.d.QueryRow(`SELECT count(*) FROM project_comments WHERE parent_id = ?`, root).Scan(&n))
		return n
	}
	assert.Zero(t, replies(), "no reply survives the failed resolve")

	_, err = fx.d.Exec(`DROP TRIGGER fail_resolve`)
	require.NoError(t, err)
	_, err = reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, 1, replies(), "the retry posts the reply exactly once")
	c, err := fx.d.GetWorkbenchComment(root)
	require.NoError(t, err)
	assert.Equal(t, "resolved", c.Status)
}
