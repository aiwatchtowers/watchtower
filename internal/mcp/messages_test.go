package mcp

import (
	"context"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

func seedMessagesDB(t *testing.T) *db.DB {
	t.Helper()
	database := seedDB(t)
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	must(database.UpsertUser(db.User{ID: "U001", Name: "esaenko", DisplayName: "Женя Саенко"}))
	must(database.UpsertUser(db.User{ID: "U002", Name: "bogdan", DisplayName: "Богдан"}))
	must(database.UpsertMessage(db.Message{ChannelID: "C1", TS: "1700000001.0001", UserID: "U001", Text: "open questions for Cloudflare: latency and billing", Permalink: "https://slack/1", RawJSON: "{}"}))
	must(database.UpsertMessage(db.Message{ChannelID: "C1", TS: "1700000002.0001", UserID: "U002", Text: "unrelated chatter", RawJSON: "{}"}))
	must(database.UpsertMessage(db.Message{ChannelID: "C1", TS: "1700000003.0001", UserID: "U001", Text: "Cloudflare follow-up still open", Permalink: "https://slack/3", RawJSON: "{}"}))
	return database
}

func TestListMessages_ByPersonName(t *testing.T) {
	cs := newTestSession(t, seedMessagesDB(t))

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_messages",
		Arguments: map[string]any{"person": "Саенко"},
	})
	if err != nil {
		t.Fatalf("call list_messages: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	// Both of U001's messages, none of U002's.
	if !strings.Contains(got, "open questions for Cloudflare") || !strings.Contains(got, "Cloudflare follow-up") {
		t.Fatalf("expected Saenko's messages, got: %s", got)
	}
	if strings.Contains(got, "unrelated chatter") {
		t.Fatalf("must not include other users' messages, got: %s", got)
	}
	// Sender rendered as display name, not raw id.
	if !strings.Contains(got, "Женя Саенко") || strings.Contains(got, "U001") {
		t.Fatalf("sender must render as display name, got: %s", got)
	}
}

func TestListMessages_PersonPlusKeyword(t *testing.T) {
	cs := newTestSession(t, seedMessagesDB(t))

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_messages",
		Arguments: map[string]any{"person": "Саенко", "query": "billing"},
	})
	if err != nil {
		t.Fatalf("call list_messages: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "latency and billing") {
		t.Fatalf("keyword must match the billing message, got: %s", got)
	}
	if strings.Contains(got, "follow-up still open") {
		t.Fatalf("keyword must exclude the non-matching message, got: %s", got)
	}
}

func TestListMessages_NoFilterErrors(t *testing.T) {
	cs := newTestSession(t, seedMessagesDB(t))

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_messages",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("call list_messages: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected an error when no filter is given, got: %s", textContent(t, res))
	}
}

func TestListMessages_LowercaseNameNotTreatedAsID(t *testing.T) {
	cs := newTestSession(t, seedMessagesDB(t))

	// "Ulyana" starts with U but is a name, not a Slack id (ids are ALL-CAPS
	// alnum like U08UA26G342). It must go through name resolution and, with no
	// matching user, error out — not be treated as a bogus id that silently
	// returns zero messages.
	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_messages",
		Arguments: map[string]any{"person": "Ulyana"},
	})
	if err != nil {
		t.Fatalf("call list_messages: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected an error for an unmatched name, got: %s", textContent(t, res))
	}
}

func TestListMessages_UnknownPersonErrors(t *testing.T) {
	cs := newTestSession(t, seedMessagesDB(t))

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_messages",
		Arguments: map[string]any{"person": "Nonexistent Person"},
	})
	if err != nil {
		t.Fatalf("call list_messages: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected an error for an unknown person, got: %s", textContent(t, res))
	}
}
