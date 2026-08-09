package mcp

import (
	"context"
	"database/sql"
	"testing"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
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
	parentTS := "1690000000.000100"
	replyTS := "1690000000.000200"
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
