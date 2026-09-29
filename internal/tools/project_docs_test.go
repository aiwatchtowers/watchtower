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
)

// writeProjectFile creates rel (and its directories) inside project id's folder.
func writeProjectFile(t *testing.T, d *db.DB, projectID int64, rel, body string) {
	t.Helper()
	p, err := d.GetProject(projectID)
	require.NoError(t, err)
	path := filepath.Join(p.FolderPath, rel)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(body), 0o644))
}

func countProjectDocuments(t *testing.T, d *db.DB, projectID int64) int {
	t.Helper()
	docs, err := d.ListProjectDocuments(projectID)
	require.NoError(t, err)
	return len(docs)
}

func TestAttachDocument_AttachesAndReattaches(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	writeProjectFile(t, fx.d, fx.a, "docs/plans/x-plan.md", "# Plan\n")

	args := fmt.Sprintf(`{"rel_path":"docs/plans/x-plan.md","kind":"plan","target_id":%d,"reason":"plan for X"}`, fx.aTarget)
	out := mustApply(t, reg, fx.a, "attach_document", args)
	assert.Equal(t, true, out["created"])
	assert.Equal(t, "docs/plans/x-plan.md", out["rel_path"])

	docs, err := fx.d.ListProjectDocuments(fx.a)
	require.NoError(t, err)
	require.Len(t, docs, 1)
	assert.Equal(t, "plan", docs[0].Kind)
	assert.Equal(t, "x-plan", docs[0].Title, "title defaults to the file name")
	assert.Equal(t, fx.aTarget, docs[0].TargetID.Int64)

	out = mustApply(t, reg, fx.a, "attach_document", args)
	assert.Equal(t, false, out["created"], "re-attaching marks the same document revised")
	assert.Equal(t, 1, countProjectDocuments(t, fx.d, fx.a))
}

// DEV-06 / Review Focus #1: attach_document never reaches a file outside the
// project folder — not by `../`, an absolute path, a symlinked file or a
// symlinked directory — and only an existing .md/.txt regular file attaches.
func TestDev06_AttachDocumentStaysInsideTheFolder(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	p, err := fx.d.GetProject(fx.a)
	require.NoError(t, err)
	outsideDir := t.TempDir()
	outsideFile := filepath.Join(outsideDir, "secret.md")
	require.NoError(t, os.WriteFile(outsideFile, []byte("secret"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(filepath.Dir(p.FolderPath), "sibling.md"), []byte("x"), 0o644))
	require.NoError(t, os.MkdirAll(filepath.Join(p.FolderPath, "docs"), 0o755))
	require.NoError(t, os.Symlink(outsideFile, filepath.Join(p.FolderPath, "docs", "link.md")))
	require.NoError(t, os.Symlink(outsideDir, filepath.Join(p.FolderPath, "docs", "ext")))
	writeProjectFile(t, fx.d, fx.a, "docs/diagram.pdf", "%PDF")
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
		args := fmt.Sprintf(`{"rel_path":%q,"kind":"doc","reason":"r"}`, rel)
		_, err := proposeIn(t, reg, fx.a, "attach_document", args)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, name)
	}
	assert.Equal(t, 0, countProjectDocuments(t, fx.d, fx.a), "nothing attached")
	assert.Equal(t, 0, countActions(t, fx.d), "a refused attach writes no audit row")

	// The folder path itself may hold spaces and non-ASCII characters.
	writeProjectFile(t, fx.d, fx.a, "docs/spec ü.md", "# Spec\n")
	mustApply(t, reg, fx.a, "attach_document", `{"rel_path":"docs/spec ü.md","kind":"spec","reason":"r"}`)
	assert.Equal(t, 1, countProjectDocuments(t, fx.d, fx.a))
}

func TestComments_AgentThreadLifecycle(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	writeProjectFile(t, fx.d, fx.a, "docs/spec.md", "# Spec\n")
	doc := mustApply(t, reg, fx.a, "attach_document", `{"rel_path":"docs/spec.md","kind":"spec","reason":"r"}`)
	docID := int64(doc["document_id"].(float64))
	ownerRoot, err := fx.d.AddProjectComment(db.ProjectComment{ProjectID: fx.a,
		DocumentID: nullInt(docID), Author: "owner", Body: "tighten this", AnchorQuote: "Spec", AnchorHeading: "Spec"})
	require.NoError(t, err)

	fresh := callReadIn(t, reg, fx.a, "list_comments", `{}`)
	assert.Contains(t, fresh, `"body":"tighten this"`)
	assert.Contains(t, fresh, `"anchor_quote":"Spec"`)
	assert.NotContains(t, fresh, "why?", "another project's comment is not listed")

	mustApply(t, reg, fx.a, "resolve_comment", fmt.Sprintf(`{"comment_id":%d,"reply":"Tightened.","reason":"addressed"}`, ownerRoot))
	root, err := fx.d.GetProjectComment(ownerRoot)
	require.NoError(t, err)
	assert.Equal(t, "resolved", root.Status)
	thread := callReadIn(t, reg, fx.a, "list_comments", fmt.Sprintf(`{"document_id":%d}`, docID))
	assert.Contains(t, thread, `"body":"Tightened."`)
	assert.Contains(t, thread, `"author":"agent"`)

	out := mustApply(t, reg, fx.a, "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"Which DB?","reason":"blocked"}`, fx.aTarget))
	c, err := fx.d.GetProjectComment(int64(out["comment_id"].(float64)))
	require.NoError(t, err)
	assert.Equal(t, "agent", c.Author)
	assert.Equal(t, "claude-code", c.AgentLabel)
	assert.Equal(t, fx.a, c.ProjectID)

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

func TestListComments_RefusesAnotherProjectsDocument(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	_, err := reg.CallRead(context.Background(), "list_comments",
		json.RawMessage(fmt.Sprintf(`{"document_id":%d}`, fx.bDocument)), directBinding(fx.a))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "not in this project")
}

func nullInt(v int64) sql.NullInt64 { return sql.NullInt64{Int64: v, Valid: true} }
