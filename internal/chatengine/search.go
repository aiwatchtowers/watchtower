package chatengine

import (
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/wiretime"
)

// The search caps (iPhone chat spec §4.6).
const (
	MaxSearchHits    = 50
	MaxSearchSnippet = 200
)

// SearchHit is one hit of the Mac's ⌘K chat search (db.SearchChats), its
// title and snippet clipped.
type SearchHit struct {
	ConversationID int64         `json:"conversation_id"`
	Title          string        `json:"title"`
	Snippet        string        `json:"snippet"`
	MessageID      *int64        `json:"message_id,omitempty"`
	Date           wiretime.Time `json:"date"`
}

// SearchResult is a query and its hits, best first.
type SearchResult struct {
	Query string      `json:"query"`
	Hits  []SearchHit `json:"hits"`
}

// ReadSearch runs the chat search for q: up to MaxSearchHits hits, titles
// clipped at 200 characters and snippets at MaxSearchSnippet.
func ReadSearch(d *db.DB, q string) (SearchResult, error) {
	hits, err := d.SearchChats(q, MaxSearchHits)
	if err != nil {
		return SearchResult{}, err
	}
	out := SearchResult{Query: q, Hits: make([]SearchHit, 0, len(hits))}
	for _, h := range hits {
		title, _ := clipText(h.Title, maxLabel)
		hit := SearchHit{ConversationID: h.ConversationID, Title: title, Snippet: clipSnippet(h.Snippet), Date: secondsTime(h.Date)}
		if h.MessageID != 0 {
			hit.MessageID = int64Ptr(h.MessageID)
		}
		out.Hits = append(out.Hits, hit)
	}
	return out, nil
}

// clipSnippet cuts a snippet to MaxSearchSnippet characters, closing a
// match marker the cut left open.
func clipSnippet(s string) string {
	out, _ := clipText(s, MaxSearchSnippet)
	if strings.Count(out, db.ChatSearchMarkStart) > strings.Count(out, db.ChatSearchMarkEnd) {
		out, _ = clipText(s, MaxSearchSnippet-1)
		out += db.ChatSearchMarkEnd
	}
	return out
}
