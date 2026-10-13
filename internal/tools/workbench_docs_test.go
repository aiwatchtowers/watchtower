package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/workbenchfiles"
)

// writeWorkbenchFile creates rel (and its directories) inside project id's folder.
func writeWorkbenchFile(t *testing.T, d *db.DB, workbenchID int64, rel, body string) {
	t.Helper()
	p, err := d.GetWorkbench(workbenchID)
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

// seedAgentSession inserts a terminal session of kind for workbench
// workbenchID; a codex row has no agent session id before its first
// SessionStart.
func seedAgentSession(t *testing.T, d *db.DB, workbenchID int64, kind string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, ?, 'Session', '/tmp/acme', CASE WHEN ? = 'claude' THEN 'uuid' END)`, workbenchID, kind, kind)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// commentLabels posts an add_comment and a resolve_comment reply under b
// with the terminal session env env, and returns both comments' labels.
func commentLabels(t *testing.T, fx workbenchFixture, env string, agent agentkind.Kind) (string, string) {
	t.Helper()
	reg := askRegistry(t, fx.d, env)
	b := directBinding(fx.a)
	b.Agent = agent
	rc, err := reg.Propose(context.Background(), "add_comment",
		json.RawMessage(fmt.Sprintf(`{"target_id":%d,"body":"Which DB?","reason":"r"}`, fx.aTarget)), b)
	require.NoError(t, err)
	require.Equal(t, "applied", rc.Status, "receipt: %+v", rc)
	added, err := fx.d.GetWorkbenchComment(int64(rc.Result.(map[string]any)["comment_id"].(float64)))
	require.NoError(t, err)
	rc, err = reg.Propose(context.Background(), "resolve_comment",
		json.RawMessage(fmt.Sprintf(`{"comment_id":%d,"reply":"Done.","reason":"r"}`, added.ID)), b)
	require.NoError(t, err)
	require.Equal(t, "applied", rc.Status, "receipt: %+v", rc)
	reply, err := fx.d.GetWorkbenchComment(int64(rc.Result.(map[string]any)["reply_id"].(float64)))
	require.NoError(t, err)
	return added.AgentLabel, reply.AgentLabel
}

// Spec 2026-10-12 §6.5: a comment from a codex session row is labelled
// codex-cli whatever the MCP's --agent says, a claude row claude-code.
func TestAgentLabel_CodexRowIsCodexCLI(t *testing.T) {
	codexRow := &db.TerminalSession{Kind: "codex"}
	for _, flag := range []agentkind.Kind{"", agentkind.Claude, agentkind.Codex} {
		assert.Equal(t, "codex-cli", agentLabelFor(codexRow, flag), "flag %q", flag)
		assert.Equal(t, "claude-code", agentLabelFor(&db.TerminalSession{Kind: "claude"}, flag), "flag %q", flag)
	}

	fx := newWorkbenchFixture(t)
	codex := seedAgentSession(t, fx.d, fx.a, "codex")
	added, reply := commentLabels(t, fx, strconv.FormatInt(codex, 10), agentkind.Claude)
	assert.Equal(t, "codex-cli", added)
	assert.Equal(t, "codex-cli", reply, "a resolve_comment reply carries the same label")

	claude := seedAgentSession(t, fx.d, fx.a, "claude")
	added, reply = commentLabels(t, fx, strconv.FormatInt(claude, 10), agentkind.Codex)
	assert.Equal(t, "claude-code", added)
	assert.Equal(t, "claude-code", reply)
}

// Without a session row of this workbench naming an agent — no env, garbage,
// a gone row, another workbench's row, a shell row — the label is the
// --agent flag, and without the flag claude-code (the label before Codex).
func TestAgentLabel_NoRowUsesFlagThenDefault(t *testing.T) {
	for _, tc := range []struct {
		row  *db.TerminalSession
		flag agentkind.Kind
		want string
	}{
		{nil, "", "claude-code"},
		{nil, agentkind.Claude, "claude-code"},
		{nil, agentkind.Codex, "codex-cli"},
		{nil, "gemini", "claude-code"},
		{&db.TerminalSession{Kind: "shell"}, agentkind.Codex, "codex-cli"},
		{&db.TerminalSession{Kind: "shell"}, "", "claude-code"},
	} {
		assert.Equal(t, tc.want, agentLabelFor(tc.row, tc.flag), "row %+v flag %q", tc.row, tc.flag)
	}

	fx := newWorkbenchFixture(t)
	theirs := seedAgentSession(t, fx.d, fx.b, "claude")
	shell := seedAgentSession(t, fx.d, fx.a, "shell")
	for _, env := range []string{"", "garbage", "999999", strconv.FormatInt(theirs, 10), strconv.FormatInt(shell, 10)} {
		for flag, want := range map[agentkind.Kind]string{"": "claude-code", agentkind.Codex: "codex-cli", agentkind.Claude: "claude-code"} {
			added, reply := commentLabels(t, fx, env, flag)
			assert.Equal(t, want, added, "env %q flag %q", env, flag)
			assert.Equal(t, want, reply, "env %q flag %q", env, flag)
		}
	}
}

// A later Apply of a stored row (no live binding) has no flag: claude-code.
func TestAgentLabel_StoredRowApplyFallsBackToClaude(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	id, err := fx.d.InsertAgentAction(db.AgentAction{Tool: "add_comment", Status: "approved", Surface: WorkbenchSurface,
		ContextType: WorkbenchContextType, ContextID: strconv.FormatInt(fx.a, 10),
		ArgsJSON: fmt.Sprintf(`{"target_id":%d,"body":"Later.","reason":"r"}`, fx.aTarget)})
	require.NoError(t, err)
	row, err := reg.Apply(context.Background(), id)
	require.NoError(t, err)
	require.Equal(t, "applied", row.Status, row.Error)
	var label string
	require.NoError(t, fx.d.QueryRow(`SELECT agent_label FROM project_comments WHERE body = 'Later.'`).Scan(&label))
	assert.Equal(t, "claude-code", label)
}
