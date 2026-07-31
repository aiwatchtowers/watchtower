package meeting

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func followupTestInput() FollowupInput {
	return FollowupInput{
		MeetingTitle:  "Weekly Sync",
		MeetingDate:   "2026-07-30",
		Participants:  []string{"Я", "Speaker 1"},
		Decisions:     []string{"Ship v2 on Friday"},
		ActionItems:   []string{"Alice prepares the changelog"},
		OpenQuestions: []string{"Who signs off Q3?"},
	}
}

func TestGenerateFollowupDraft(t *testing.T) {
	mock := &recordingMockGenerator{response: "Коллеги, по итогам: шипим v2 в пятницу."}
	pipe := &Pipeline{generator: mock}

	draft, usage, err := pipe.GenerateFollowupDraft(context.Background(), followupTestInput())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if draft != "Коллеги, по итогам: шипим v2 в пятницу." {
		t.Errorf("draft = %q", draft)
	}
	if usage == nil {
		t.Error("usage is nil, want non-nil")
	}
	// Stated content travels in the USER message (intent-draft contract:
	// the model renders it, nothing else).
	for _, want := range []string{"Ship v2 on Friday", "Alice prepares the changelog", "Who signs off Q3?"} {
		if !strings.Contains(mock.lastUserMessage, want) {
			t.Errorf("user message should contain %q, got: %q", want, mock.lastUserMessage)
		}
	}
	if !strings.Contains(mock.lastSystemPrompt, "Weekly Sync") {
		t.Errorf("system prompt should contain the meeting title, got: %.300s", mock.lastSystemPrompt)
	}
	if !strings.Contains(mock.lastSystemPrompt, "no stored style profile") {
		t.Errorf("system prompt should fall back to the neutral-tone style block, got: %.500s", mock.lastSystemPrompt)
	}
}

func TestGenerateFollowupDraftUsesStyleProfile(t *testing.T) {
	database := openTestDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "W1", Name: "test"}))
	require.NoError(t, database.SetStyleProfile("Short sentences, no pleasantries."))

	mock := &recordingMockGenerator{response: "ok"}
	pipe := New(database, nil, mock, nil)

	_, _, err := pipe.GenerateFollowupDraft(context.Background(), followupTestInput())
	require.NoError(t, err)
	if !strings.Contains(mock.lastSystemPrompt, "Short sentences, no pleasantries.") {
		t.Errorf("system prompt should contain the stored style profile, got: %.500s", mock.lastSystemPrompt)
	}
}

func TestGenerateFollowupDraftEmptyContentFailsBeforeAI(t *testing.T) {
	mock := &recordingMockGenerator{response: "should not be called"}
	pipe := &Pipeline{generator: mock}

	// Degenerate but valid chapter shape: every category empty — there is
	// nothing stated to render, so no AI call may happen (it would invent).
	_, _, err := pipe.GenerateFollowupDraft(context.Background(), FollowupInput{
		MeetingTitle: "Empty", MeetingDate: "2026-07-30",
		Decisions: []string{"  "}, ActionItems: nil, OpenQuestions: []string{},
	})
	if err == nil {
		t.Fatal("empty stated content must fail")
	}
	if mock.lastUserMessage != "" {
		t.Error("the AI must not be called when there is nothing to render")
	}
}

func TestGenerateFollowupDraftSingleCategory(t *testing.T) {
	// Degenerate valid: only open questions — still draftable.
	mock := &recordingMockGenerator{response: "draft"}
	pipe := &Pipeline{generator: mock}
	draft, _, err := pipe.GenerateFollowupDraft(context.Background(), FollowupInput{
		MeetingTitle: "Q&A", OpenQuestions: []string{"Who signs off Q3?"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if draft != "draft" {
		t.Errorf("draft = %q", draft)
	}
	if strings.Contains(mock.lastUserMessage, "Decisions:") {
		t.Error("empty groups must be omitted from the stated content")
	}
	if !strings.Contains(mock.lastUserMessage, "Open questions:") {
		t.Errorf("open questions group missing, got: %q", mock.lastUserMessage)
	}
}

func TestGenerateFollowupDraftStripsFence(t *testing.T) {
	mock := &recordingMockGenerator{response: "```\nthe draft\n```"}
	pipe := &Pipeline{generator: mock}
	draft, _, err := pipe.GenerateFollowupDraft(context.Background(), followupTestInput())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if draft != "the draft" {
		t.Errorf("draft = %q, want fence stripped", draft)
	}
}

func TestGenerateFollowupDraftAIError(t *testing.T) {
	pipe := &Pipeline{generator: &recordingMockGenerator{err: errors.New("boom")}}
	_, _, err := pipe.GenerateFollowupDraft(context.Background(), followupTestInput())
	if err == nil || !strings.Contains(err.Error(), "boom") {
		t.Errorf("err = %v, want the AI error surfaced", err)
	}
}
