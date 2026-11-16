package chatengine

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/synctest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chatstore"
	"watchtower/internal/db"
)

// finishedTurn sends text to conv and waits until its reply is final.
func finishedTurn(t *testing.T, g *rig, conv int64, text string) chatstore.Started {
	t.Helper()
	st, err := g.r.Turn(context.Background(), turnReq(conv, text, ""))
	require.NoError(t, err)
	synctest.Wait()
	var status string
	require.NoError(t, g.d.QueryRow(`SELECT status FROM chat_messages WHERE id = ?`, st.AssistantMessageID).Scan(&status))
	require.Equal(t, "complete", status)
	return st
}

func messageText(t *testing.T, d *db.DB, id int64) string {
	t.Helper()
	var s string
	require.NoError(t, d.QueryRow(`SELECT text FROM chat_messages WHERE id = ?`, id).Scan(&s))
	return s
}

// TestChatengine_ScreenContextNeverStored: the screen block leads the turn
// command's text, the stored owner row is the composed text without it, and
// a block over 8 KB is refused with nothing written.
func TestChatengine_ScreenContextNeverStored(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		block := "=== CURRENT SCREEN ===\nTab: Inbox\n==="
		req := turnReq(c, "what is this?", "")
		req.ScreenContext = block
		req.Compose = &Compose{Skill: "triage"}
		st, err := g.r.Turn(context.Background(), req)
		require.NoError(t, err)
		synctest.Wait()

		stored := ComposeOwnerText("what is this?", Compose{Skill: "triage"})
		assert.True(t, strings.HasPrefix(st.SendText, block+"\n\n"), st.SendText)
		assert.Equal(t, stored, messageText(t, g.d, st.UserMessageID))
		cmds := g.f.all()[0].turnCommands()
		require.Len(t, cmds, 1)
		assert.Equal(t, block+"\n\n"+stored, cmds[0].Text)
		assert.Equal(t, 0, countRows(t, g.d, `text LIKE '%CURRENT SCREEN%'`))

		req = turnReq(c, "again", "")
		req.ScreenContext = strings.Repeat("x", MaxScreenContextBytes+1)
		_, err = g.r.Turn(context.Background(), req)
		assert.Equal(t, "invalid", ErrorCode(err))
		assert.Equal(t, 1, ownerRows(t, g.d, c))
	})
}

// seedArtifact stores version 1 of key in conv on messageID and n open
// comments on it; it returns the comment ids.
func seedArtifact(t *testing.T, d *db.DB, conv, messageID int64, key string, n int) []int64 {
	t.Helper()
	_, err := d.Exec(`INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, created_at)
		VALUES (?, ?, ?, 1, 'document', 'Plan', 'Step one. Step two.', 1)`, conv, messageID, key)
	require.NoError(t, err)
	var ids []int64
	for i := range n {
		res, err := d.Exec(`INSERT INTO chat_artifact_comments (conversation_id, artifact_key, artifact_version, body, anchor_quote, created_at)
			VALUES (?, ?, 1, ?, ?, 2)`, conv, key, []string{"shorter", "why"}[i%2], []string{"Step one.", "Step two."}[i%2])
		require.NoError(t, err)
		id, _ := res.LastInsertId()
		ids = append(ids, id)
	}
	return ids
}

func commentStatus(t *testing.T, d *db.DB, id int64) (string, sql.NullFloat64) {
	t.Helper()
	var s string
	var at sql.NullFloat64
	require.NoError(t, d.QueryRow(`SELECT status, sent_at FROM chat_artifact_comments WHERE id = ?`, id).Scan(&s, &at))
	return s, at
}

// TestChatengine_ArtifactCommentsMarkedSentInStartTx: the comments become
// the owner message, turn `sent` with sent_at = the owner row's created_at;
// a refused start (busy) leaves them open, and a comment no longer open
// refuses the start.
func TestChatengine_ArtifactCommentsMarkedSentInStartTx(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		first, err := g.r.Turn(context.Background(), turnReq(c, "draft a plan", ""))
		require.NoError(t, err)
		synctest.Wait()
		ids := seedArtifact(t, g.d, c, first.AssistantMessageID, "plan", 2)

		// The first turn still runs: refused, nothing written, still open.
		req := turnReq(c, "", "")
		req.ArtifactCommentIDs = []int64{ids[1], ids[0]}
		_, err = g.r.Turn(context.Background(), req)
		require.ErrorIs(t, err, chatstore.ErrBusy)
		for _, id := range ids {
			s, at := commentStatus(t, g.d, id)
			assert.Equal(t, "open", s)
			assert.False(t, at.Valid)
		}
		g.f.all()[0].finish()
		synctest.Wait()

		st, err := g.r.Turn(context.Background(), req)
		require.NoError(t, err)
		synctest.Wait()
		want := ComposeOwnerText(chatstore.ComposeArtifactComments("Plan", "plan", 1, []chatstore.CommentItem{
			{Quote: "Step two.", Body: "why"}, {Quote: "Step one.", Body: "shorter"}}), Compose{})
		assert.Equal(t, want, messageText(t, g.d, st.UserMessageID))
		var created float64
		require.NoError(t, g.d.QueryRow(`SELECT created_at FROM chat_messages WHERE id = ?`, st.UserMessageID).Scan(&created))
		for _, id := range ids {
			s, at := commentStatus(t, g.d, id)
			assert.Equal(t, "sent", s)
			assert.Equal(t, created, at.Float64)
		}
		g.f.all()[0].finish()
		synctest.Wait()

		// Already sent: refused, nothing written.
		owners := ownerRows(t, g.d, c)
		_, err = g.r.Turn(context.Background(), req)
		assert.Equal(t, "invalid", ErrorCode(err))
		assert.Equal(t, owners, ownerRows(t, g.d, c))

		// Text beside the comments is refused.
		more := seedArtifact(t, g.d, c, first.AssistantMessageID, "notes", 1)
		bad := turnReq(c, "and this", "")
		bad.ArtifactCommentIDs = more
		_, err = g.r.Turn(context.Background(), bad)
		assert.Equal(t, "invalid", ErrorCode(err))
		s, _ := commentStatus(t, g.d, more[0])
		assert.Equal(t, "open", s)
	})
}

// TestChatengine_RetryOnlyRetryable: retry of a reply whose error a retry
// cannot help is invalid; of a retryable one, a new reply sibling under the
// same owner message.
func TestChatengine_RetryOnlyRetryable(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		st := finishedTurn(t, g, c, "hello")
		retry := func() (chatstore.Started, error) {
			return g.r.Turn(context.Background(), TurnRequest{StartRequest: chatstore.StartRequest{ConversationID: c,
				Mode: chatstore.ModeRetry, MessageID: st.AssistantMessageID}})
		}
		for _, code := range []string{"auth", "quota_exhausted", "attachment_unsupported", "workdir_unsafe"} {
			_, err := g.d.Exec(`UPDATE chat_messages SET status = 'error', error_code = ? WHERE id = ?`, code, st.AssistantMessageID)
			require.NoError(t, err)
			_, err = retry()
			assert.Equal(t, "invalid", ErrorCode(err), code)
		}
		assert.Equal(t, 1, countRows(t, g.d, `conversation_id = ? AND role = 'assistant'`, c))

		_, err := g.d.Exec(`UPDATE chat_messages SET error_code = 'rate_limit' WHERE id = ?`, st.AssistantMessageID)
		require.NoError(t, err)
		again, err := retry()
		require.NoError(t, err)
		synctest.Wait()
		assert.Equal(t, st.UserMessageID, again.UserMessageID)
		assert.NotEqual(t, st.AssistantMessageID, again.AssistantMessageID)
		assert.Equal(t, 1, ownerRows(t, g.d, c))
		assert.Equal(t, 2, countRows(t, g.d, `parent_id = ? AND role = 'assistant'`, st.UserMessageID))
	})
}

// TestChatengine_ContinueSendsContinueAfterPartial: continue after the last
// reply when it is partial and not out of quota sends "Continue"; anything
// else is invalid.
func TestChatengine_ContinueSendsContinueAfterPartial(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		first := finishedTurn(t, g, c, "one")
		last := finishedTurn(t, g, c, "two")
		cont := func(id int64) (json.RawMessage, error) {
			return g.r.Do(context.Background(), "chat_turn", json.RawMessage(`{"conversation_id":`+itoa(c)+
				`,"mode":"continue","message_id":`+itoa(id)+`}`), Client{Kind: "mac"})
		}

		_, err := cont(last.AssistantMessageID) // complete: nothing to continue
		assert.Equal(t, "invalid", ErrorCode(err))
		_, err = g.d.Exec(`UPDATE chat_messages SET status = 'partial', error_code = 'quota_exhausted' WHERE id = ?`, last.AssistantMessageID)
		require.NoError(t, err)
		_, err = cont(last.AssistantMessageID)
		assert.Equal(t, "invalid", ErrorCode(err))
		_, err = g.d.Exec(`UPDATE chat_messages SET status = 'partial' WHERE id IN (?, ?)`, first.AssistantMessageID, last.AssistantMessageID)
		require.NoError(t, err)
		_, err = g.d.Exec(`UPDATE chat_messages SET error_code = NULL WHERE id = ?`, last.AssistantMessageID)
		require.NoError(t, err)
		_, err = cont(first.AssistantMessageID) // not the last reply
		assert.Equal(t, "invalid", ErrorCode(err))
		assert.Equal(t, 2, ownerRows(t, g.d, c))

		_, err = cont(last.AssistantMessageID)
		require.NoError(t, err)
		synctest.Wait()
		var text string
		var parent int64
		require.NoError(t, g.d.QueryRow(`SELECT text, parent_id FROM chat_messages WHERE conversation_id = ? AND role = 'user'
			ORDER BY id DESC LIMIT 1`, c).Scan(&text, &parent))
		assert.Equal(t, "Continue", text)
		assert.Equal(t, last.AssistantMessageID, parent)
	})
}

// newProject inserts a chat project and returns its id.
func newProject(t *testing.T, g *rig, name string) int64 {
	t.Helper()
	n := name
	id, err := g.r.ManageProject(context.Background(), ProjectRequest{Op: ProjectCreate, Name: &n})
	require.NoError(t, err)
	return id
}

// TestChatengine_ProjectDeleteDropsWarmSessions: deleting a project closes
// the warm session of a chat in it, detaches the chat, and drops its stored
// session; an instruction edit retires the session too.
func TestChatengine_ProjectDeleteDropsWarmSessions(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		p := newProject(t, g, "  Launch  ")
		var name string
		require.NoError(t, g.d.QueryRow(`SELECT name FROM chat_projects WHERE id = ?`, p).Scan(&name))
		assert.Equal(t, "Launch", name)
		c, err := g.r.NewConversation(context.Background(), &p, nil)
		require.NoError(t, err)
		finishedTurn(t, g, c, "hi")
		_, err = g.d.Exec(`UPDATE chat_conversations SET session_id = 'sid' WHERE id = ?`, c)
		require.NoError(t, err)
		proc := g.f.all()[0]
		require.False(t, proc.isExited())
		assert.Contains(t, strings.Join(proc.argv, " "), "--project-id "+itoa(p))

		pid := p
		_, err = g.r.ManageProject(context.Background(), ProjectRequest{Op: ProjectDelete, ID: &pid})
		require.NoError(t, err)
		synctest.Wait()
		assert.True(t, proc.isExited(), "the warm session of the deleted project's chat closed")
		var project, session sql.NullString
		require.NoError(t, g.d.QueryRow(`SELECT project_id, session_id FROM chat_conversations WHERE id = ?`, c).Scan(&project, &session))
		assert.False(t, project.Valid)
		assert.False(t, session.Valid)
		_, err = g.r.ManageProject(context.Background(), ProjectRequest{Op: ProjectDelete, ID: &pid})
		assert.Equal(t, "not_found", ErrorCode(err))

		// An instruction edit retires the project's warm session as well.
		q := newProject(t, g, "")
		require.NoError(t, g.d.QueryRow(`SELECT name FROM chat_projects WHERE id = ?`, q).Scan(&name))
		assert.Equal(t, DefaultProjectName, name)
		c2, err := g.r.NewConversation(context.Background(), &q, nil)
		require.NoError(t, err)
		finishedTurn(t, g, c2, "hi")
		procs := g.f.all()
		proc2 := procs[len(procs)-1]
		require.False(t, proc2.isExited())
		_, err = g.r.Do(context.Background(), "project_manage",
			json.RawMessage(`{"op":"update","project_id":`+itoa(q)+`,"instructions":"Be brief."}`), Client{Kind: "mac"})
		require.NoError(t, err)
		synctest.Wait()
		assert.True(t, proc2.isExited())
	})
}

// TestChatengine_ProjectWrites: sources, files, archive and rename, each as
// ChatProjectQueries writes them.
func TestChatengine_ProjectWrites(t *testing.T) {
	g := newRig(t, fakeOpts{})
	g.r.c.FilesDir = t.TempDir()
	ctx := context.Background()
	p := newProject(t, g, "Launch")
	pid := p

	src := []ProjectSource{{Kind: "jira_project", Ref: "PAY", Label: "PAY"}, {Kind: "slack_channel", Ref: "1:C1", Label: "#eng"}}
	_, err := g.r.ManageProject(ctx, ProjectRequest{Op: ProjectSourceAdd, ID: &pid, Sources: src})
	require.NoError(t, err)
	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: ProjectSourceAdd, ID: &pid, Sources: src[:1]})
	require.NoError(t, err, "an already pinned source is skipped")
	var n int
	require.NoError(t, g.d.QueryRow(`SELECT COUNT(*) FROM chat_project_sources WHERE project_id = ?`, p).Scan(&n))
	assert.Equal(t, 2, n)
	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: ProjectSourceAdd, ID: &pid, Sources: []ProjectSource{{Kind: "jira", Ref: "PAY-1"}}})
	assert.Equal(t, "invalid", ErrorCode(err), "an issue is mentioned, never pinned")
	var sid int64
	require.NoError(t, g.d.QueryRow(`SELECT id FROM chat_project_sources WHERE kind = 'jira_project'`).Scan(&sid))
	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: ProjectSourceRemove, SourceID: sid})
	require.NoError(t, err)
	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: ProjectSourceRemove, SourceID: sid})
	assert.Equal(t, "not_found", ErrorCode(err))

	file := filepath.Join(t.TempDir(), "brief.md")
	require.NoError(t, os.WriteFile(file, []byte("# Brief"), 0o600))
	for _, kind := range []string{"phone", ""} {
		_, err = g.r.Do(ctx, "project_manage", json.RawMessage(`{"op":"file_add","project_id":`+itoa(p)+`,"path":`+mustJSON(file)+`}`),
			Client{Kind: kind})
		assert.Equal(t, "forbidden", ErrorCode(err), "only the Mac names a path (%q)", kind)
	}
	require.NoError(t, g.d.QueryRow(`SELECT COUNT(*) FROM chat_attachments WHERE project_id = ?`, p).Scan(&n))
	assert.Equal(t, 0, n)
	out, err := g.r.Do(ctx, "project_manage", json.RawMessage(`{"op":"file_add","project_id":`+itoa(p)+`,"path":`+mustJSON(file)+`}`),
		Client{Kind: "mac"})
	require.NoError(t, err)
	var res struct {
		ID int64 `json:"id"`
	}
	require.NoError(t, json.Unmarshal(out, &res))
	fid := res.ID
	require.NoError(t, err)
	var stored string
	require.NoError(t, g.d.QueryRow(`SELECT path FROM chat_attachments WHERE id = ? AND project_id = ?`, fid, p).Scan(&stored))
	assert.True(t, strings.HasPrefix(stored, filepath.Join(g.r.c.FilesDir, "projects", itoa(p))+string(filepath.Separator)), stored)
	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: ProjectFileRemove, FileID: fid})
	require.NoError(t, err)
	_, err = os.Stat(stored)
	assert.True(t, errors.Is(err, os.ErrNotExist), "an unreferenced project file leaves the disk")

	name, empty := "Renamed", "  "
	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: ProjectUpdate, ID: &pid, Name: &name})
	require.NoError(t, err)
	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: ProjectUpdate, ID: &pid, Name: &empty})
	require.NoError(t, err, "a blank name is ignored")
	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: ProjectArchive, ID: &pid})
	require.NoError(t, err)
	var got string
	var archived sql.NullFloat64
	require.NoError(t, g.d.QueryRow(`SELECT name, archived_at FROM chat_projects WHERE id = ?`, p).Scan(&got, &archived))
	assert.Equal(t, "Renamed", got)
	assert.True(t, archived.Valid)
	_, err = g.r.ManageProject(ctx, ProjectRequest{Op: "rename", ID: &pid})
	assert.Equal(t, "invalid", ErrorCode(err))
}

// TestChatengine_ArtifactKeepWritesKnowledgeRow: keep writes the
// chat_knowledge_artifacts row (a newer version updates it), unkeep removes
// it, and a Live Slack conversation is refused (LIVE-01).
func TestChatengine_ArtifactKeepWritesKnowledgeRow(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		st := finishedTurn(t, g, c, "draft")
		seedArtifact(t, g.d, c, st.AssistantMessageID, "plan", 0)
		ctx := context.Background()
		kept := func() (int, bool) {
			var v int
			err := g.d.QueryRow(`SELECT version FROM chat_knowledge_artifacts WHERE conversation_id = ? AND artifact_key = 'plan'`, c).Scan(&v)
			if errors.Is(err, sql.ErrNoRows) {
				return 0, false
			}
			require.NoError(t, err)
			return v, true
		}

		_, err := g.r.Do(ctx, "artifact_manage", json.RawMessage(`{"op":"keep","conversation_id":`+itoa(c)+`,"key":"plan","version":1}`), Client{Kind: "mac"})
		require.NoError(t, err)
		v, ok := kept()
		assert.True(t, ok)
		assert.Equal(t, 1, v)

		// The owner's edit is version 2; keeping it updates the one row.
		v2, err := g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactEdit, Conversation: c, Key: "plan", Version: 1, Content: "Step one only."})
		require.NoError(t, err)
		assert.Equal(t, int64(2), v2)
		_, err = g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactKeep, Conversation: c, Key: "plan", Version: 2})
		require.NoError(t, err)
		v, _ = kept()
		assert.Equal(t, 2, v)
		_, err = g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactKeep, Conversation: c, Key: "plan", Version: 9})
		assert.Equal(t, "not_found", ErrorCode(err))

		_, err = g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactUnkeep, Conversation: c, Key: "plan"})
		require.NoError(t, err)
		_, ok = kept()
		assert.False(t, ok)

		_, err = g.d.Exec(`UPDATE chat_conversations SET live_slack_since = ? WHERE id = ?`, st.AssistantMessageID, c)
		require.NoError(t, err)
		_, err = g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactKeep, Conversation: c, Key: "plan", Version: 1})
		assert.Equal(t, "forbidden", ErrorCode(err))
		_, ok = kept()
		assert.False(t, ok)
	})
}

// TestChatengine_ArtifactCommentWrites: add (trimmed body, quote required),
// delete only while unsent, resolve only once sent, and the re-anchor plan.
func TestChatengine_ArtifactCommentWrites(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		st := finishedTurn(t, g, c, "draft")
		seedArtifact(t, g.d, c, st.AssistantMessageID, "plan", 0)
		ctx := context.Background()
		add := func(body, quote string) (int64, error) {
			return g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactCommentAdd, Conversation: c, Key: "plan", Version: 1,
				Comment: &ArtifactComment{Body: body, Quote: quote, Heading: "Plan"}})
		}
		a, err := add("  tighten  ", "Step one.")
		require.NoError(t, err)
		var body string
		require.NoError(t, g.d.QueryRow(`SELECT body FROM chat_artifact_comments WHERE id = ?`, a).Scan(&body))
		assert.Equal(t, "tighten", body)
		_, err = add(" ", "Step one.")
		assert.Equal(t, "invalid", ErrorCode(err))
		_, err = add("x", " ")
		assert.Equal(t, "invalid", ErrorCode(err))

		b, err := add("why", "Step two.")
		require.NoError(t, err)
		_, err = g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactCommentResolve, Conversation: c, CommentID: b})
		assert.Equal(t, "not_found", ErrorCode(err), "an unsent comment is deleted, not resolved")
		_, err = g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactCommentDelete, Conversation: c, CommentID: b})
		require.NoError(t, err)

		_, err = g.d.Exec(`UPDATE chat_artifact_comments SET status = 'sent', sent_at = 3 WHERE id = ?`, a)
		require.NoError(t, err)
		_, err = g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactCommentDelete, Conversation: c, CommentID: a})
		assert.Equal(t, "not_found", ErrorCode(err), "a sent comment is part of the chat")

		v2, err := g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactEdit, Conversation: c, Key: "plan", Version: 1, Content: "New."})
		require.NoError(t, err)
		d, err := add("keep", "Step one.")
		require.NoError(t, err)
		_, err = g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactCommentReanchor, Conversation: c, Key: "plan",
			Version: int(v2), Moved: []int64{d}, Lost: []int64{a}})
		require.NoError(t, err)
		s, _ := commentStatus(t, g.d, a)
		assert.Equal(t, "outdated", s)
		var ver int
		require.NoError(t, g.d.QueryRow(`SELECT artifact_version FROM chat_artifact_comments WHERE id = ?`, d).Scan(&ver))
		assert.Equal(t, int(v2), ver)
		_, err = g.r.ManageArtifact(ctx, ArtifactRequest{Op: ArtifactCommentResolve, Conversation: c, CommentID: a})
		require.NoError(t, err)
		s, _ = commentStatus(t, g.d, a)
		assert.Equal(t, "resolved", s)
	})
}

func attachRows(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_attachments`).Scan(&n))
	return n
}

func filesUnder(t *testing.T, dir string) int {
	t.Helper()
	n := 0
	require.NoError(t, filepath.Walk(dir, func(_ string, fi os.FileInfo, err error) error {
		if err == nil && !fi.IsDir() {
			n++
		}
		return err
	}))
	return n
}

// TestChatengine_AttachRefusesMissingAndOversize: a missing path and a file
// over its kind's limit (a PDF past MaxAttachmentBytes, never read) are
// invalid with the Mac's line; no row and no file are left. A good file is
// stored 0600 as a pending attachment and can be discarded.
func TestChatengine_AttachRefusesMissingAndOversize(t *testing.T) {
	g := newRig(t, fakeOpts{})
	g.r.c.FilesDir = t.TempDir()
	c := newConversation(t, g.d)
	ctx := context.Background()
	dir := t.TempDir()

	_, err := g.r.AttachPath(ctx, c, filepath.Join(dir, "gone.txt"))
	assert.Equal(t, "invalid", ErrorCode(err))
	assert.Equal(t, "gone.txt could not be read", err.Error())

	big := filepath.Join(dir, "huge.pdf")
	f, err := os.Create(big)
	require.NoError(t, err)
	_, err = f.WriteString("%PDF-1.7\n")
	require.NoError(t, err)
	require.NoError(t, f.Truncate(chatstore.MaxAttachmentBytes+1))
	require.NoError(t, f.Close())
	_, err = g.r.Do(ctx, "attach", json.RawMessage(`{"conversation_id":`+itoa(c)+`,"path":`+mustJSON(big)+`}`), Client{Kind: "mac"})
	assert.Equal(t, "invalid", ErrorCode(err))
	assert.Equal(t, (&chatstore.Rejection{Reason: chatstore.RejectTooLarge, FileName: "huge.pdf", Limit: chatstore.PDFLimit}).Message(), err.Error())
	assert.Equal(t, 0, attachRows(t, g.d))
	assert.Equal(t, 0, filesUnder(t, g.r.c.FilesDir))

	good := filepath.Join(dir, "notes.md")
	require.NoError(t, os.WriteFile(good, []byte("# notes"), 0o644))
	for _, kind := range []string{"phone", ""} {
		_, err = g.r.Do(ctx, "attach", json.RawMessage(`{"conversation_id":`+itoa(c)+`,"path":`+mustJSON(good)+`}`), Client{Kind: kind})
		assert.Equal(t, "forbidden", ErrorCode(err), "only the Mac names a path (%q)", kind)
	}
	assert.Equal(t, 0, attachRows(t, g.d))
	id, err := g.r.AttachPath(ctx, c, good)
	require.NoError(t, err)
	var path, name string
	require.NoError(t, g.d.QueryRow(`SELECT path, name FROM chat_attachments WHERE id = ? AND conversation_id = ? AND message_id IS NULL`,
		id, c).Scan(&path, &name))
	assert.Equal(t, "notes.md", name)
	fi, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())

	_, err = g.r.Do(ctx, "attach_discard", json.RawMessage(`{"conversation_id":`+itoa(c)+`,"attachment_id":`+itoa(id)+`}`), Client{Kind: "mac"})
	require.NoError(t, err)
	assert.Equal(t, 0, attachRows(t, g.d))
	_, err = os.Stat(path)
	assert.True(t, errors.Is(err, os.ErrNotExist))
	assert.Equal(t, "not_found", ErrorCode(g.r.DiscardAttachment(ctx, c, id)))
}

// TestChatengine_AttachRefusesSymlinkAndDir: a symlink (even to a good file)
// and a folder are refused with nothing written.
func TestChatengine_AttachRefusesSymlinkAndDir(t *testing.T) {
	g := newRig(t, fakeOpts{})
	g.r.c.FilesDir = t.TempDir()
	c := newConversation(t, g.d)
	ctx := context.Background()
	dir := t.TempDir()
	good := filepath.Join(dir, "notes.md")
	require.NoError(t, os.WriteFile(good, []byte("# notes"), 0o600))
	link := filepath.Join(dir, "link.md")
	require.NoError(t, os.Symlink(good, link))

	_, err := g.r.AttachPath(ctx, c, link)
	assert.Equal(t, "invalid", ErrorCode(err))
	assert.Equal(t, "link.md could not be read", err.Error())

	sub := filepath.Join(dir, "folder")
	require.NoError(t, os.Mkdir(sub, 0o700))
	_, err = g.r.AttachPath(ctx, c, sub)
	assert.Equal(t, "invalid", ErrorCode(err))
	assert.Equal(t, "folder is a folder; attach the files inside it instead", err.Error())

	assert.Equal(t, 0, attachRows(t, g.d))
	assert.Equal(t, 0, filesUnder(t, g.r.c.FilesDir))
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
