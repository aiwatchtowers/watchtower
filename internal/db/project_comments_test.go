package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func addComment(t *testing.T, d *DB, c ProjectComment) int64 {
	t.Helper()
	id, err := d.AddProjectComment(c)
	require.NoError(t, err)
	return id
}

func commentIDs(cs []ProjectComment) []int64 {
	ids := make([]int64, 0, len(cs))
	for _, c := range cs {
		ids = append(ids, c.ID)
	}
	return ids
}

func TestAddProjectComment_ReplyInheritsTheRootAndThreadsStayFlat(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	docID, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/plan.md", Kind: "plan"})
	require.NoError(t, err)

	root := addComment(t, d, ProjectComment{ProjectID: pid, DocumentID: nullID(docID), Author: "owner",
		Body: "split this", AnchorQuote: "Task 3", AnchorHeading: "Tasks"})
	reply := addComment(t, d, ProjectComment{ProjectID: pid, ParentID: nullID(root), Author: "agent", Body: "done"})
	nested := addComment(t, d, ProjectComment{ProjectID: pid, ParentID: nullID(reply), Author: "owner",
		Body: "thanks", AnchorQuote: "ignored on a reply"})

	got, err := d.GetProjectComment(nested)
	require.NoError(t, err)
	assert.Equal(t, nullID(root), got.ParentID, "a reply to a reply hangs off the thread root")
	assert.Equal(t, nullID(docID), got.DocumentID, "a reply inherits the root's document")
	assert.Empty(t, got.AnchorQuote, "only a root carries an anchor")
	assert.Equal(t, "open", got.Status)
}

func TestAddProjectComment_RefusesRefsOutsideTheProject(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	other := newTestProject(t, d)
	foreignTarget := insertProjectTargetRow(t, d, other, "other board")
	foreignDoc, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: other, RelPath: "a.md"})
	require.NoError(t, err)
	foreignRoot := addComment(t, d, ProjectComment{ProjectID: other, TargetID: nullID(foreignTarget), Author: "owner", Body: "x"})
	personal, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	for name, c := range map[string]ProjectComment{
		"target of another project":   {ProjectID: pid, TargetID: nullID(foreignTarget), Author: "agent", Body: "x"},
		"personal target":             {ProjectID: pid, TargetID: nullID(personal), Author: "agent", Body: "x"},
		"document of another project": {ProjectID: pid, DocumentID: nullID(foreignDoc), Author: "agent", Body: "x"},
		"thread of another project":   {ProjectID: pid, ParentID: nullID(foreignRoot), Author: "agent", Body: "x"},
	} {
		_, err := d.AddProjectComment(c)
		assert.ErrorIs(t, err, ErrNotInProject, name)
	}

	tid := insertProjectTargetRow(t, d, pid, "mine")
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, Author: "agent", Body: "x"})
	assert.Error(t, err, "a comment needs a target, a document or a parent")
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: nullID(tid), Author: "bot", Body: "x"})
	assert.Error(t, err, "unknown author")
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: nullID(tid), Author: "agent", Body: "  "})
	assert.Error(t, err, "empty body")
}

// TestListProjectComments_NewForAgent pins spec §3: new for the agent = open
// owner roots, plus owner replies newer than their thread's latest agent reply.
func TestListProjectComments_NewForAgent(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	tid := insertProjectTargetRow(t, d, pid, "feature")
	docID, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, RelPath: "docs/plan.md", Kind: "plan"})
	require.NoError(t, err)
	onTarget := func(author, body string) ProjectComment {
		return ProjectComment{ProjectID: pid, TargetID: nullID(tid), Author: author, Body: body}
	}
	reply := func(root int64, author, body string) ProjectComment {
		return ProjectComment{ProjectID: pid, ParentID: nullID(root), Author: author, Body: body}
	}

	openRoot := addComment(t, d, onTarget("owner", "A: open owner root"))
	resolvedRoot := addComment(t, d, onTarget("owner", "B: resolved owner root"))
	require.NoError(t, d.SetProjectCommentStatus(resolvedRoot, "resolved"))
	agentRoot := addComment(t, d, onTarget("agent", "C: agent asks"))
	ownerAnswer := addComment(t, d, reply(agentRoot, "owner", "C1: owner answers"))
	docRoot := addComment(t, d, ProjectComment{ProjectID: pid, DocumentID: nullID(docID), Author: "owner", Body: "D: on the plan"})
	addComment(t, d, reply(docRoot, "agent", "D1: agent replies"))
	ownerFollowUp := addComment(t, d, reply(docRoot, "owner", "D2: owner follows up"))
	secondRoot := addComment(t, d, onTarget("owner", "E: another open root"))
	addComment(t, d, reply(secondRoot, "owner", "E1: before the agent reply"))
	addComment(t, d, reply(secondRoot, "agent", "E2: agent replies"))

	got, err := d.ListProjectComments(ProjectCommentFilter{ProjectID: pid, NewForAgent: true})
	require.NoError(t, err)
	assert.Equal(t, []int64{openRoot, ownerAnswer, docRoot, ownerFollowUp, secondRoot}, commentIDs(got))

	onDoc, err := d.ListProjectComments(ProjectCommentFilter{ProjectID: pid, DocumentID: docID})
	require.NoError(t, err)
	assert.Len(t, onDoc, 3, "the document filter returns the whole thread")
}

func TestSetProjectCommentStatus_RootsOnly(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	tid := insertProjectTargetRow(t, d, pid, "feature")
	root := addComment(t, d, ProjectComment{ProjectID: pid, TargetID: nullID(tid), Author: "owner", Body: "q"})
	reply := addComment(t, d, ProjectComment{ProjectID: pid, ParentID: nullID(root), Author: "agent", Body: "a"})

	require.NoError(t, d.SetProjectCommentStatus(root, "resolved"))
	require.NoError(t, d.SetProjectCommentStatus(root, "open"), "the owner can reopen")
	assert.Error(t, d.SetProjectCommentStatus(reply, "resolved"), "status is meaningful on roots only")
	assert.Error(t, d.SetProjectCommentStatus(root, "closed"), "unknown status")
}

func TestMarkProjectCommentsRead_OnlyAgentCommentsOfTheScope(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	t1 := insertProjectTargetRow(t, d, pid, "one")
	t2 := insertProjectTargetRow(t, d, pid, "two")
	agentOnT1 := addComment(t, d, ProjectComment{ProjectID: pid, TargetID: nullID(t1), Author: "agent", Body: "a"})
	agentOnT2 := addComment(t, d, ProjectComment{ProjectID: pid, TargetID: nullID(t2), Author: "agent", Body: "b"})
	ownerOnT1 := addComment(t, d, ProjectComment{ProjectID: pid, TargetID: nullID(t1), Author: "owner", Body: "c"})

	require.NoError(t, d.MarkProjectCommentsRead(pid, t1, 0))

	read := func(id int64) string {
		c, err := d.GetProjectComment(id)
		require.NoError(t, err)
		return c.ReadAt
	}
	assert.NotEmpty(t, read(agentOnT1))
	assert.Empty(t, read(agentOnT2), "another target's comments stay unread")
	assert.Empty(t, read(ownerOnT1), "owner comments are never marked")
}
