package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func addComment(t *testing.T, d *DB, c WorkbenchComment) int64 {
	t.Helper()
	id, err := d.AddWorkbenchComment(c)
	require.NoError(t, err)
	return id
}

func commentIDs(cs []WorkbenchComment) []int64 {
	ids := make([]int64, 0, len(cs))
	for _, c := range cs {
		ids = append(ids, c.ID)
	}
	return ids
}

func TestAddProjectComment_ReplyInheritsTheRootAndThreadsStayFlat(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	docID, _, err := d.UpsertWorkbenchDocument(WorkbenchDocument{WorkbenchID: pid, RelPath: "docs/plan.md", Kind: "plan"})
	require.NoError(t, err)

	root := addComment(t, d, WorkbenchComment{WorkbenchID: pid, DocumentID: nullID(docID), Author: "owner",
		Body: "split this", AnchorQuote: "Task 3", AnchorHeading: "Tasks"})
	reply := addComment(t, d, WorkbenchComment{WorkbenchID: pid, ParentID: nullID(root), Author: "agent", Body: "done"})
	nested := addComment(t, d, WorkbenchComment{WorkbenchID: pid, ParentID: nullID(reply), Author: "owner",
		Body: "thanks", AnchorQuote: "ignored on a reply"})

	got, err := d.GetWorkbenchComment(nested)
	require.NoError(t, err)
	assert.Equal(t, nullID(root), got.ParentID, "a reply to a reply hangs off the thread root")
	assert.Equal(t, nullID(docID), got.DocumentID, "a reply inherits the root's document")
	assert.Empty(t, got.AnchorQuote, "only a root carries an anchor")
	assert.Equal(t, "open", got.Status)
}

func TestAddProjectComment_RefusesRefsOutsideTheProject(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	foreignTarget := insertWorkbenchTargetRow(t, d, other, "other board")
	foreignDoc, _, err := d.UpsertWorkbenchDocument(WorkbenchDocument{WorkbenchID: other, RelPath: "a.md"})
	require.NoError(t, err)
	foreignRoot := addComment(t, d, WorkbenchComment{WorkbenchID: other, TargetID: nullID(foreignTarget), Author: "owner", Body: "x"})
	personal, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	for name, c := range map[string]WorkbenchComment{
		"target of another project":   {WorkbenchID: pid, TargetID: nullID(foreignTarget), Author: "agent", Body: "x"},
		"personal target":             {WorkbenchID: pid, TargetID: nullID(personal), Author: "agent", Body: "x"},
		"document of another project": {WorkbenchID: pid, DocumentID: nullID(foreignDoc), Author: "agent", Body: "x"},
		"thread of another project":   {WorkbenchID: pid, ParentID: nullID(foreignRoot), Author: "agent", Body: "x"},
	} {
		_, err := d.AddWorkbenchComment(c)
		assert.ErrorIs(t, err, ErrNotInWorkbench, name)
	}

	tid := insertWorkbenchTargetRow(t, d, pid, "mine")
	_, err = d.AddWorkbenchComment(WorkbenchComment{WorkbenchID: pid, Author: "agent", Body: "x"})
	assert.Error(t, err, "a comment needs a target, a document or a parent")
	_, err = d.AddWorkbenchComment(WorkbenchComment{WorkbenchID: pid, TargetID: nullID(tid), Author: "bot", Body: "x"})
	assert.Error(t, err, "unknown author")
	_, err = d.AddWorkbenchComment(WorkbenchComment{WorkbenchID: pid, TargetID: nullID(tid), Author: "agent", Body: "  "})
	assert.Error(t, err, "empty body")
}

// TestListProjectComments_NewForAgent pins spec §3: new for the agent = open
// owner roots, plus owner replies newer than their thread's latest agent reply.
func TestListProjectComments_NewForAgent(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	tid := insertWorkbenchTargetRow(t, d, pid, "feature")
	docID, _, err := d.UpsertWorkbenchDocument(WorkbenchDocument{WorkbenchID: pid, RelPath: "docs/plan.md", Kind: "plan"})
	require.NoError(t, err)
	onTarget := func(author, body string) WorkbenchComment {
		return WorkbenchComment{WorkbenchID: pid, TargetID: nullID(tid), Author: author, Body: body}
	}
	reply := func(root int64, author, body string) WorkbenchComment {
		return WorkbenchComment{WorkbenchID: pid, ParentID: nullID(root), Author: author, Body: body}
	}

	openRoot := addComment(t, d, onTarget("owner", "A: open owner root"))
	resolvedRoot := addComment(t, d, onTarget("owner", "B: resolved owner root"))
	require.NoError(t, d.SetWorkbenchCommentStatus(resolvedRoot, "resolved"))
	agentRoot := addComment(t, d, onTarget("agent", "C: agent asks"))
	ownerAnswer := addComment(t, d, reply(agentRoot, "owner", "C1: owner answers"))
	docRoot := addComment(t, d, WorkbenchComment{WorkbenchID: pid, DocumentID: nullID(docID), Author: "owner", Body: "D: on the plan"})
	addComment(t, d, reply(docRoot, "agent", "D1: agent replies"))
	ownerFollowUp := addComment(t, d, reply(docRoot, "owner", "D2: owner follows up"))
	secondRoot := addComment(t, d, onTarget("owner", "E: another open root"))
	addComment(t, d, reply(secondRoot, "owner", "E1: before the agent reply"))
	addComment(t, d, reply(secondRoot, "agent", "E2: agent replies"))
	closedThread := addComment(t, d, onTarget("owner", "F: owner root"))
	addComment(t, d, reply(closedThread, "owner", "F1: owner adds more"))
	require.NoError(t, d.SetWorkbenchCommentStatus(closedThread, "resolved"))

	got, err := d.ListWorkbenchComments(WorkbenchCommentFilter{WorkbenchID: pid, NewForAgent: true})
	require.NoError(t, err)
	assert.Equal(t, []int64{openRoot, ownerAnswer, docRoot, ownerFollowUp, secondRoot}, commentIDs(got))

	onDoc, err := d.ListWorkbenchComments(WorkbenchCommentFilter{WorkbenchID: pid, DocumentID: docID})
	require.NoError(t, err)
	assert.Len(t, onDoc, 3, "the document filter returns the whole thread")
}

// TestAddProjectComment_OwnerReplyReopensAClosedThread: an owner reply under
// a resolved or outdated root reopens it, so the reply reaches the agent's
// new-for-agent channel; an agent reply leaves the status alone.
func TestAddProjectComment_OwnerReplyReopensAClosedThread(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	tid := insertWorkbenchTargetRow(t, d, pid, "feature")
	root := func(status string) int64 {
		id := addComment(t, d, WorkbenchComment{WorkbenchID: pid, TargetID: nullID(tid), Author: "owner", Body: status})
		require.NoError(t, d.SetWorkbenchCommentStatus(id, status))
		return id
	}
	reply := func(root int64, author string) int64 {
		return addComment(t, d, WorkbenchComment{WorkbenchID: pid, ParentID: nullID(root), Author: author, Body: "more"})
	}
	status := func(id int64) string {
		c, err := d.GetWorkbenchComment(id)
		require.NoError(t, err)
		return c.Status
	}

	resolved, outdated := root("resolved"), root("outdated")
	agentOnly := root("resolved")
	resolvedReply := reply(resolved, "owner")
	outdatedReply := reply(outdated, "owner")
	reply(agentOnly, "agent")

	assert.Equal(t, "open", status(resolved), "an owner reply reopens a resolved thread")
	assert.Equal(t, "open", status(outdated), "an owner reply reopens an outdated thread")
	assert.Equal(t, "resolved", status(agentOnly), "an agent reply never reopens")

	got, err := d.ListWorkbenchComments(WorkbenchCommentFilter{WorkbenchID: pid, NewForAgent: true})
	require.NoError(t, err)
	assert.Equal(t, []int64{resolved, outdated, resolvedReply, outdatedReply}, commentIDs(got))
}

func TestSetProjectCommentStatus_RootsOnly(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	tid := insertWorkbenchTargetRow(t, d, pid, "feature")
	root := addComment(t, d, WorkbenchComment{WorkbenchID: pid, TargetID: nullID(tid), Author: "owner", Body: "q"})
	reply := addComment(t, d, WorkbenchComment{WorkbenchID: pid, ParentID: nullID(root), Author: "agent", Body: "a"})

	require.NoError(t, d.SetWorkbenchCommentStatus(root, "resolved"))
	require.NoError(t, d.SetWorkbenchCommentStatus(root, "open"), "the owner can reopen")
	assert.Error(t, d.SetWorkbenchCommentStatus(reply, "resolved"), "status is meaningful on roots only")
	assert.Error(t, d.SetWorkbenchCommentStatus(root, "closed"), "unknown status")
}

func TestGetProjectCommentAndDocument_MissingIsNilNil(t *testing.T) {
	d := openTestDB(t)
	c, err := d.GetWorkbenchComment(999)
	require.NoError(t, err)
	assert.Nil(t, c)
	doc, err := d.GetWorkbenchDocument(999)
	require.NoError(t, err)
	assert.Nil(t, doc)
}
