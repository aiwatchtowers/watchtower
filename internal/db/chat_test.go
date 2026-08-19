package db

import (
	"testing"
	"time"
)

// TestListRecentChatTurnsAbsentTables: a CLI-only install has never run the
// Desktop app, so the Swift-owned chat tables do not exist — the read is a
// clean empty no-op, never an error.
func TestListRecentChatTurnsAbsentTables(t *testing.T) {
	db := openTestDB(t)

	turns, err := db.ListRecentChatTurns("target", "7", 10)
	if err != nil {
		t.Fatalf("absent chat tables must read empty, got error: %v", err)
	}
	if turns != nil {
		t.Fatalf("absent chat tables must yield nil turns, got %+v", turns)
	}
}

// TestListRecentChatTurnsOrderingAndLimit: the reader returns the most recent
// turns for one (context_type, context_id) pair, newest LAST, spanning every
// conversation of that context, and never leaks another context's turns.
func TestListRecentChatTurnsOrderingAndLimit(t *testing.T) {
	db := openTestDB(t)
	createChatTablesForTest(t, db)

	base := float64(time.Now().Add(-time.Hour).Unix())
	convA := insertChatConversation(t, db, "target", "7")
	convB := insertChatConversation(t, db, "target", "7") // a second tab on the same target
	other := insertChatConversation(t, db, "target", "8")
	situation := insertChatConversation(t, db, "situation", "7")

	insertChatMessage(t, db, convA, "user", "first", base)
	insertChatMessage(t, db, convA, "assistant", "second", base+10)
	insertChatMessage(t, db, convB, "system", "Action applied: marked sub-item done.", base+20)
	insertChatMessage(t, db, convA, "user", "fourth", base+30)
	insertChatMessage(t, db, other, "user", "other target", base+40)
	insertChatMessage(t, db, situation, "user", "other context type", base+40)

	turns, err := db.ListRecentChatTurns("target", "7", 10)
	if err != nil {
		t.Fatalf("ListRecentChatTurns: %v", err)
	}
	if len(turns) != 4 {
		t.Fatalf("expected 4 turns for target/7, got %d: %+v", len(turns), turns)
	}
	wantTexts := []string{"first", "second", "Action applied: marked sub-item done.", "fourth"}
	for i, want := range wantTexts {
		if turns[i].Text != want {
			t.Errorf("turn %d text = %q, want %q (newest must be last)", i, turns[i].Text, want)
		}
	}
	if turns[2].Role != "system" {
		t.Errorf("system turns must be included with their role, got %q", turns[2].Role)
	}
	if turns[3].CreatedAt != int64(base+30) {
		t.Errorf("created_at = %d, want %d", turns[3].CreatedAt, int64(base+30))
	}

	// The limit keeps the RECENT tail, still newest-last.
	capped, err := db.ListRecentChatTurns("target", "7", 2)
	if err != nil {
		t.Fatalf("ListRecentChatTurns capped: %v", err)
	}
	if len(capped) != 2 {
		t.Fatalf("expected 2 capped turns, got %d: %+v", len(capped), capped)
	}
	if capped[0].Text != "Action applied: marked sub-item done." || capped[1].Text != "fourth" {
		t.Errorf("cap must keep the newest turns, got %+v", capped)
	}
}

// TestListRecentChatTurnsDegenerateArgs: valid-but-degenerate input (no
// context, no limit, an unknown context) is a clean empty read, not an error.
func TestListRecentChatTurnsDegenerateArgs(t *testing.T) {
	db := openTestDB(t)
	createChatTablesForTest(t, db)
	conv := insertChatConversation(t, db, "target", "7")
	insertChatMessage(t, db, conv, "user", "hello", float64(time.Now().Unix()))

	cases := []struct {
		name    string
		ctxType string
		ctxID   string
		limit   int
	}{
		{"zero limit", "target", "7", 0},
		{"negative limit", "target", "7", -3},
		{"empty context type", "", "7", 10},
		{"empty context id", "target", "", 10},
		{"unknown target", "target", "999", 10},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			turns, err := db.ListRecentChatTurns(tc.ctxType, tc.ctxID, tc.limit)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(turns) != 0 {
				t.Fatalf("expected no turns, got %+v", turns)
			}
		})
	}
}
