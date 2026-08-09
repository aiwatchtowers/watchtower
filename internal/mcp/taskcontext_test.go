package mcp

import (
	"context"
	"database/sql"
	"encoding/json"
	"testing"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// taskContextFixtureParentTS/ReplyTS are shared between
// seedTaskContextFixture and TestGetTaskContextThreadMessagesAreUniqueAndOrdered
// so the test can assert on the exact timestamps the fixture wrote.
const (
	taskContextFixtureParentTS = "1690000000.000100"
	taskContextFixtureReplyTS  = "1690000000.000200"
)

func TestGetTaskContextAssemblesTheDossier(t *testing.T) {
	database := seedDB(t)
	seedTaskContextFixture(t, database)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_task_context",
		Arguments: map[string]any{"key": "PROJ-1"},
	})
	if err != nil {
		t.Fatalf("calling get_task_context: %v", err)
	}
	if res.IsError {
		t.Fatalf("tool error: %s", textContent(t, res))
	}
	out := textContent(t, res)

	for _, want := range []string{
		"Rewrite the payment flow",           // the issue itself
		"do not touch the legacy adapter",    // a comment
		"we agreed to keep the old endpoint", // a linked thread reply
		"keep tokens in a file",              // a meeting transcript hit
		"Token storage: file, not keychain",  // a registry decision
	} {
		if !contains(out, want) {
			t.Fatalf("dossier missing %q; got: %s", want, out)
		}
	}
}

// TestGetTaskContextThreadMessagesAreUniqueAndOrdered pins the fix for a bug
// where the anchor message was prepended manually on top of
// GetThreadReplies's own (parent-inclusive) result, duplicating it out of
// chronological order. A substring/containment check cannot catch this
// class of defect — it has to count messages and check their sequence.
func TestGetTaskContextThreadMessagesAreUniqueAndOrdered(t *testing.T) {
	database := seedDB(t)
	seedTaskContextFixture(t, database)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_task_context",
		Arguments: map[string]any{"key": "PROJ-1"},
	})
	if err != nil {
		t.Fatalf("calling get_task_context: %v", err)
	}
	if res.IsError {
		t.Fatalf("tool error: %s", textContent(t, res))
	}

	var got taskContext
	if err := json.Unmarshal([]byte(textContent(t, res)), &got); err != nil {
		t.Fatalf("unmarshaling dossier: %v", err)
	}
	if len(got.Threads) != 1 {
		t.Fatalf("expected exactly 1 thread, got %d: %+v", len(got.Threads), got.Threads)
	}
	msgs := got.Threads[0].Messages
	if len(msgs) != 2 {
		t.Fatalf("expected exactly 2 messages (parent + reply, no duplicate), got %d: %+v", len(msgs), msgs)
	}
	if msgs[0].TS != taskContextFixtureParentTS || msgs[1].TS != taskContextFixtureReplyTS {
		t.Fatalf("expected chronological order [parent, reply], got %+v", msgs)
	}
}

func TestGetTaskContextOnUnknownKeyIsSoftError(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_task_context",
		Arguments: map[string]any{"key": "NOPE-1"},
	})
	if err != nil {
		t.Fatalf("calling get_task_context: %v", err)
	}
	if !res.IsError {
		t.Fatalf("unknown key must be a soft tool error, got: %s", textContent(t, res))
	}
}

func TestGetTaskContextOmitsEmptySections(t *testing.T) {
	database := seedDB(t)
	seedJiraIssueOnly(t, database) // issue exists, nothing else does
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_task_context",
		Arguments: map[string]any{"key": "PROJ-2"},
	})
	if err != nil {
		t.Fatalf("calling get_task_context: %v", err)
	}
	if res.IsError {
		t.Fatalf("an issue with no surrounding material must still return a dossier: %s", textContent(t, res))
	}
	out := textContent(t, res)
	for _, absent := range []string{"\"threads\"", "\"meetings\"", "\"decisions\""} {
		if contains(out, absent) {
			t.Fatalf("empty section %s must be omitted, got: %s", absent, out)
		}
	}
}

// seedTaskContextFixture seeds a full dossier's worth of material for
// PROJ-1: the issue, a comment, a Slack thread (parent + reply) linked via
// jira_slack_links, a meeting transcript that mentions the key, and a
// registry decision mentioning it.
func seedTaskContextFixture(t *testing.T, database *db.DB) {
	t.Helper()

	accountID := db.SeedTestJiraAccount(t, database)

	now := time.Now().UTC().Format(time.RFC3339)
	if err := database.UpsertJiraIssue(db.JiraIssue{
		AccountID:      accountID,
		Key:            "PROJ-1",
		ID:             "10001",
		ProjectKey:     "PROJ",
		Summary:        "Rewrite the payment flow",
		Status:         "In Progress",
		StatusCategory: "In Progress",
		CreatedAt:      now,
		UpdatedAt:      now,
		SyncedAt:       now,
	}); err != nil {
		t.Fatalf("seeding jira issue: %v", err)
	}

	if err := database.UpsertJiraComments([]db.JiraComment{{
		AccountID: accountID,
		IssueKey:  "PROJ-1",
		ID:        "20001",
		Author:    "Alex",
		BodyText:  "do not touch the legacy adapter",
		CreatedAt: now,
		UpdatedAt: now,
	}}); err != nil {
		t.Fatalf("seeding jira comment: %v", err)
	}

	if err := database.EnsureChannel("C001", "eng-payments", "public", ""); err != nil {
		t.Fatalf("seeding channel: %v", err)
	}
	parentTS := taskContextFixtureParentTS
	replyTS := taskContextFixtureReplyTS
	if err := database.UpsertMessage(db.Message{
		ChannelID: "C001", TS: parentTS, UserID: "U001",
		Text: "does PROJ-1 touch the legacy adapter?", RawJSON: "{}",
	}); err != nil {
		t.Fatalf("seeding parent message: %v", err)
	}
	if err := database.UpsertMessage(db.Message{
		ChannelID: "C001", TS: replyTS, UserID: "U002",
		Text:     "we agreed to keep the old endpoint",
		ThreadTS: sql.NullString{String: parentTS, Valid: true},
		RawJSON:  "{}",
	}); err != nil {
		t.Fatalf("seeding reply message: %v", err)
	}
	if err := database.UpsertJiraSlackLink(db.JiraSlackLink{
		IssueKey: "PROJ-1", ChannelID: "C001", MessageTS: parentTS, LinkType: "mention",
	}); err != nil {
		t.Fatalf("seeding jira slack link: %v", err)
	}

	if _, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Payments sync",
		TranscriptText: "Meeting notes for PROJ-1: we decided to keep tokens in a file, not the keychain.",
	}); err != nil {
		t.Fatalf("seeding meeting transcript: %v", err)
	}

	tx, err := database.Begin()
	if err != nil {
		t.Fatalf("beginning idea tx: %v", err)
	}
	ideaID, err := database.CreateIdeaTx(tx, db.Idea{
		Kind:    "decision",
		Title:   "Token storage: file, not keychain",
		Essence: "Keep tokens in a plain file, not the Keychain",
		Status:  "active",
		Source:  "mined",
	})
	if err != nil {
		t.Fatalf("creating idea: %v", err)
	}
	if err := database.InsertIdeaMentionTx(tx, db.IdeaMention{
		IdeaID: ideaID, Source: "jira", Ref: "PROJ-1", Quote: "token storage decision", SaidAt: now,
	}); err != nil {
		t.Fatalf("inserting idea mention: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("committing idea tx: %v", err)
	}
}

// TestGetTaskContextThreadWithNoRepliesHasNoNote pins the distinction the
// degrade-to-a-note contract depends on: a thread that genuinely has no
// replies must come back with just the anchor message and NO note, so it
// reads differently from a thread whose replies could not be read (which
// gets a note — see collectTaskThreads). Forcing GetThreadReplies itself to
// fail is not practical here: it queries the same messages table and
// connection as GetMessagesByTS (the anchor lookup), which runs first in
// the same loop iteration — any read-only-safe way to break the table
// (e.g. dropping it before the session goes query_only) breaks the anchor
// lookup too, and the anchor lookup already has its own error path. So this
// test asserts the reachable half of the contract only.
func TestGetTaskContextThreadWithNoRepliesHasNoNote(t *testing.T) {
	database := seedDB(t)
	seedTaskContextNoReplyThreadFixture(t, database)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_task_context",
		Arguments: map[string]any{"key": "PROJ-3"},
	})
	if err != nil {
		t.Fatalf("calling get_task_context: %v", err)
	}
	if res.IsError {
		t.Fatalf("tool error: %s", textContent(t, res))
	}
	out := textContent(t, res)

	if !contains(out, "no one has replied yet") {
		t.Fatalf("dossier missing the anchor message; got: %s", out)
	}
	if contains(out, "unavailable") {
		t.Fatalf("a thread with genuinely no replies must carry no note, got: %s", out)
	}
}

// seedTaskContextNoReplyThreadFixture seeds an issue linked to a single
// Slack message with no replies — the genuinely-empty case that must stay
// silent (no note), as opposed to a read failure (which must produce one).
func seedTaskContextNoReplyThreadFixture(t *testing.T, database *db.DB) {
	t.Helper()
	accountID := db.SeedTestJiraAccount(t, database)
	now := time.Now().UTC().Format(time.RFC3339)
	if err := database.UpsertJiraIssue(db.JiraIssue{
		AccountID:      accountID,
		Key:            "PROJ-3",
		ID:             "10003",
		ProjectKey:     "PROJ",
		Summary:        "A quiet ticket",
		Status:         "To Do",
		StatusCategory: "To Do",
		CreatedAt:      now,
		UpdatedAt:      now,
		SyncedAt:       now,
	}); err != nil {
		t.Fatalf("seeding jira issue: %v", err)
	}
	if err := database.EnsureChannel("C002", "eng-quiet", "public", ""); err != nil {
		t.Fatalf("seeding channel: %v", err)
	}
	anchorTS := "1690000500.000100"
	if err := database.UpsertMessage(db.Message{
		ChannelID: "C002", TS: anchorTS, UserID: "U003",
		Text: "PROJ-3: no one has replied yet", RawJSON: "{}",
	}); err != nil {
		t.Fatalf("seeding anchor message: %v", err)
	}
	if err := database.UpsertJiraSlackLink(db.JiraSlackLink{
		IssueKey: "PROJ-3", ChannelID: "C002", MessageTS: anchorTS, LinkType: "mention",
	}); err != nil {
		t.Fatalf("seeding jira slack link: %v", err)
	}
}

// seedJiraIssueOnly seeds a bare issue with nothing else attached, so the
// dossier's other sections have no material.
func seedJiraIssueOnly(t *testing.T, database *db.DB) {
	t.Helper()
	accountID := db.SeedTestJiraAccount(t, database)
	now := time.Now().UTC().Format(time.RFC3339)
	if err := database.UpsertJiraIssue(db.JiraIssue{
		AccountID:      accountID,
		Key:            "PROJ-2",
		ID:             "10002",
		ProjectKey:     "PROJ",
		Summary:        "A lonely ticket",
		Status:         "To Do",
		StatusCategory: "To Do",
		CreatedAt:      now,
		UpdatedAt:      now,
		SyncedAt:       now,
	}); err != nil {
		t.Fatalf("seeding jira issue: %v", err)
	}
}
