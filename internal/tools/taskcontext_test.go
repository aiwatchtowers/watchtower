package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

const (
	taskContextFixtureParentTS = "1690000000.000100"
	taskContextFixtureReplyTS  = "1690000000.000200"
)

func taskContextRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewGetTaskContext()))
	return reg
}

func taskContextDossier(t *testing.T, d *db.DB, key string) taskContext {
	t.Helper()
	var got taskContext
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, taskContextRegistry(t, d), "get_task_context", `{"key":"`+key+`"}`)), &got))
	return got
}

// The dossier gathers the issue, a comment, a linked thread reply, a meeting
// hit, and a registry decision.
func TestGetTaskContext_AssemblesTheDossier(t *testing.T) {
	d := openDB(t)
	seedTaskContextFixture(t, d)
	got := callReadString(t, taskContextRegistry(t, d), "get_task_context", `{"key":"PROJ-1"}`)
	for _, want := range []string{
		"Rewrite the payment flow", "do not touch the legacy adapter",
		"we agreed to keep the old endpoint", "keep tokens in a file",
		"Token storage: file, not keychain",
	} {
		assert.Contains(t, got, want)
	}
}

// The anchor message is not duplicated on top of the parent-inclusive replies:
// exactly parent + reply, in chronological order.
func TestGetTaskContext_ThreadMessagesUniqueAndOrdered(t *testing.T) {
	d := openDB(t)
	seedTaskContextFixture(t, d)
	got := taskContextDossier(t, d, "PROJ-1")
	require.Len(t, got.Threads, 1)
	msgs := got.Threads[0].Messages
	require.Len(t, msgs, 2, "parent + reply, no duplicate")
	assert.Equal(t, taskContextFixtureParentTS, msgs[0].TS)
	assert.Equal(t, taskContextFixtureReplyTS, msgs[1].TS)
}

// Truncation keeps the anchor + newest replies (never the oldest), in order,
// and records a note.
func TestGetTaskContext_ThreadTruncationKeepsRecentReplies(t *testing.T) {
	d := openDB(t)
	seedTaskContextManyRepliesFixture(t, d)
	got := taskContextDossier(t, d, "PROJ-4")
	require.Len(t, got.Threads, 1)
	msgs := got.Threads[0].Messages
	require.LessOrEqual(t, len(msgs), taskContextMaxReplies)

	var texts []string
	for _, m := range msgs {
		texts = append(texts, m.Text)
	}
	assert.Contains(t, texts, "PROJ-4: the anchor question", "anchor survives truncation")
	assert.Contains(t, texts, "reply 30: the decision that matters", "newest reply survives")
	assert.NotContains(t, texts, "reply 1: ancient chatter", "oldest reply is dropped")
	for i := 1; i < len(msgs); i++ {
		assert.Less(t, msgs[i-1].TS, msgs[i].TS, "messages stay ordered")
	}
	var note bool
	for _, n := range got.Notes {
		if strings.Contains(n, "more replies than shown") {
			note = true
		}
	}
	assert.True(t, note, "expected a truncation note")
}

func TestGetTaskContext_UnknownKeyIsError(t *testing.T) {
	_, err := taskContextRegistry(t, openDB(t)).CallRead(context.Background(), "get_task_context", json.RawMessage(`{"key":"NOPE-1"}`))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no issue with key NOPE-1")
}

// An issue with no surrounding material still returns a dossier, with empty
// sections omitted.
func TestGetTaskContext_OmitsEmptySections(t *testing.T) {
	d := openDB(t)
	seedJiraIssueOnly(t, d)
	got := callReadString(t, taskContextRegistry(t, d), "get_task_context", `{"key":"PROJ-2"}`)
	for _, absent := range []string{`"threads"`, `"meetings"`, `"decisions"`} {
		assert.NotContains(t, got, absent, "empty section must be omitted")
	}
}

// A thread that genuinely has no replies comes back with just the anchor and no
// note (distinct from a read failure, which gets a note).
func TestGetTaskContext_ThreadWithNoRepliesHasNoNote(t *testing.T) {
	d := openDB(t)
	seedTaskContextNoReplyThreadFixture(t, d)
	got := callReadString(t, taskContextRegistry(t, d), "get_task_context", `{"key":"PROJ-3"}`)
	assert.Contains(t, got, "no one has replied yet")
	assert.NotContains(t, got, "unavailable", "a genuinely empty thread carries no note")
}

func seedTaskContextFixture(t *testing.T, d *db.DB) {
	t.Helper()
	accountID := db.SeedTestJiraAccount(t, d)
	now := time.Now().UTC().Format(time.RFC3339)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: accountID, Key: "PROJ-1", ID: "10001", ProjectKey: "PROJ", Summary: "Rewrite the payment flow",
		Status: "In Progress", StatusCategory: "In Progress", CreatedAt: now, UpdatedAt: now, SyncedAt: now,
	}))
	require.NoError(t, d.UpsertJiraComments([]db.JiraComment{{
		AccountID: accountID, IssueKey: "PROJ-1", ID: "20001", Author: "Alex",
		BodyText: "do not touch the legacy adapter", CreatedAt: now, UpdatedAt: now,
	}}))
	require.NoError(t, d.EnsureChannel("C001", "eng-payments", "public", ""))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C001", TS: taskContextFixtureParentTS, UserID: "U001", Text: "does PROJ-1 touch the legacy adapter?", RawJSON: "{}"}))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C001", TS: taskContextFixtureReplyTS, UserID: "U002", Text: "we agreed to keep the old endpoint", ThreadTS: sql.NullString{String: taskContextFixtureParentTS, Valid: true}, RawJSON: "{}"}))
	require.NoError(t, d.UpsertJiraSlackLink(db.JiraSlackLink{IssueKey: "PROJ-1", ChannelID: "C001", MessageTS: taskContextFixtureParentTS, LinkType: "mention"}))
	_, err := d.InsertMeetingTranscript(db.MeetingTranscript{Title: "Payments sync", TranscriptText: "Meeting notes for PROJ-1: we decided to keep tokens in a file, not the keychain."})
	require.NoError(t, err)

	tx, err := d.Begin()
	require.NoError(t, err)
	ideaID, err := d.CreateIdeaTx(tx, db.Idea{Kind: "decision", Title: "Token storage: file, not keychain", Essence: "Keep tokens in a plain file, not the Keychain", Status: "active", Source: "mined"})
	require.NoError(t, err)
	require.NoError(t, d.InsertIdeaMentionTx(tx, db.IdeaMention{IdeaID: ideaID, Source: "jira", Ref: "PROJ-1", Quote: "token storage decision", SaidAt: now}))
	require.NoError(t, tx.Commit())
}

func seedTaskContextManyRepliesFixture(t *testing.T, d *db.DB) {
	t.Helper()
	accountID := db.SeedTestJiraAccount(t, d)
	now := time.Now().UTC().Format(time.RFC3339)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: accountID, Key: "PROJ-4", ID: "10004", ProjectKey: "PROJ", Summary: "A busy ticket",
		Status: "In Progress", StatusCategory: "In Progress", CreatedAt: now, UpdatedAt: now, SyncedAt: now,
	}))
	require.NoError(t, d.EnsureChannel("C003", "eng-busy", "public", ""))
	anchorTS := "1690001000.000100"
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C003", TS: anchorTS, UserID: "U004", Text: "PROJ-4: the anchor question", RawJSON: "{}"}))
	require.NoError(t, d.UpsertJiraSlackLink(db.JiraSlackLink{IssueKey: "PROJ-4", ChannelID: "C003", MessageTS: anchorTS, LinkType: "mention"}))
	for i := 1; i <= 30; i++ {
		text := fmt.Sprintf("reply %d: filler discussion", i)
		if i == 1 {
			text = "reply 1: ancient chatter"
		}
		if i == 30 {
			text = "reply 30: the decision that matters"
		}
		replyTS := fmt.Sprintf("1690001%03d.000100", i)
		require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C003", TS: replyTS, UserID: fmt.Sprintf("U%03d", 100+i), Text: text, ThreadTS: sql.NullString{String: anchorTS, Valid: true}, RawJSON: "{}"}))
	}
}

func seedJiraIssueOnly(t *testing.T, d *db.DB) {
	t.Helper()
	accountID := db.SeedTestJiraAccount(t, d)
	now := time.Now().UTC().Format(time.RFC3339)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: accountID, Key: "PROJ-2", ID: "10002", ProjectKey: "PROJ", Summary: "A lonely ticket",
		Status: "To Do", StatusCategory: "To Do", CreatedAt: now, UpdatedAt: now, SyncedAt: now,
	}))
}

func seedTaskContextNoReplyThreadFixture(t *testing.T, d *db.DB) {
	t.Helper()
	accountID := db.SeedTestJiraAccount(t, d)
	now := time.Now().UTC().Format(time.RFC3339)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: accountID, Key: "PROJ-3", ID: "10003", ProjectKey: "PROJ", Summary: "A quiet ticket",
		Status: "To Do", StatusCategory: "To Do", CreatedAt: now, UpdatedAt: now, SyncedAt: now,
	}))
	require.NoError(t, d.EnsureChannel("C002", "eng-quiet", "public", ""))
	anchorTS := "1690000500.000100"
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C002", TS: anchorTS, UserID: "U003", Text: "PROJ-3: no one has replied yet", RawJSON: "{}"}))
	require.NoError(t, d.UpsertJiraSlackLink(db.JiraSlackLink{IssueKey: "PROJ-3", ChannelID: "C002", MessageTS: anchorTS, LinkType: "mention"}))
}
