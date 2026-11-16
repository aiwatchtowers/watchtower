package db

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type chatSearchFixture struct {
	Comment       string `json:"_comment"`
	Conversations []struct {
		ID          int64    `json:"id"`
		Title       string   `json:"title"`
		ContextType *string  `json:"context_type,omitempty"`
		ArchivedAt  *float64 `json:"archived_at,omitempty"`
		UpdatedAt   float64  `json:"updated_at"`
	} `json:"conversations"`
	Messages []struct {
		ID             int64   `json:"id"`
		ConversationID int64   `json:"conversation_id"`
		Role           string  `json:"role"`
		Text           string  `json:"text"`
		CreatedAt      float64 `json:"created_at"`
	} `json:"messages"`
	Cases []struct {
		Name  string           `json:"name"`
		Query string           `json:"query"`
		Limit int              `json:"limit"`
		Hits  []chatSearchCase `json:"hits"`
	} `json:"cases"`
}

type chatSearchCase struct {
	ConversationID int64  `json:"conversation_id"`
	MessageID      *int64 `json:"message_id"`
	Title          string `json:"title"`
	Snippet        string `json:"snippet"`
}

// TestChatSearch_SharedCases runs testdata/chat_search_cases.json, which
// the Swift ChatSearchQueriesFixtureTests runs through ChatSearchQueries:
// the phone's search returns the Mac's hits. -update rewrites the hits from
// the Go port (then the Swift test must still pass).
func TestChatSearch_SharedCases(t *testing.T) {
	path := filepath.Join("testdata", "chat_search_cases.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var fx chatSearchFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) < 8 {
		t.Fatalf("only %d cases", len(fx.Cases))
	}
	d := OpenTestDB(t)
	for _, c := range fx.Conversations {
		if _, err := d.Exec(`INSERT INTO chat_conversations (id, title, context_type, archived_at, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?)`, c.ID, c.Title, c.ContextType, c.ArchivedAt, c.UpdatedAt, c.UpdatedAt); err != nil {
			t.Fatal(err)
		}
	}
	for _, m := range fx.Messages {
		if _, err := d.Exec(`INSERT INTO chat_messages (id, conversation_id, role, text, created_at) VALUES (?, ?, ?, ?, ?)`,
			m.ID, m.ConversationID, m.Role, m.Text, m.CreatedAt); err != nil {
			t.Fatal(err)
		}
	}
	for i, c := range fx.Cases {
		hits, err := d.SearchChats(c.Query, c.Limit)
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		got := []chatSearchCase{}
		for _, h := range hits {
			var mid *int64
			if h.MessageID != 0 {
				mid = &h.MessageID
			}
			got = append(got, chatSearchCase{ConversationID: h.ConversationID, MessageID: mid, Title: h.Title, Snippet: h.Snippet})
		}
		if *updateGolden {
			fx.Cases[i].Hits = got
			continue
		}
		want := c.Hits
		if want == nil {
			want = []chatSearchCase{}
		}
		gb, _ := json.Marshal(got)
		wb, _ := json.Marshal(want)
		if string(gb) != string(wb) {
			t.Errorf("%s:\n got %s\nwant %s", c.Name, gb, wb)
		}
	}
	if *updateGolden {
		out, err := json.MarshalIndent(fx, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, append(out, '\n'), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestChatSearchFTSQuery(t *testing.T) {
	got, ok := ChatSearchFTSQuery(`payments  roll-out "x"`)
	if !ok || got != `"payments"* "roll"* "out"* "x"*` {
		t.Fatalf("got %q %v", got, ok)
	}
	if _, ok := ChatSearchFTSQuery("  -- "); ok {
		t.Fatal("no token")
	}
}
