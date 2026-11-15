package db

import (
	"fmt"
	"strings"
	"unicode"

	"github.com/rivo/uniseg"
)

// The snippet markers around a matched term (ChatSearchQueries.markStart and
// markEnd).
const (
	ChatSearchMarkStart = "\u0002"
	ChatSearchMarkEnd   = "\u0003"
)

// ChatSearchHit is one hit of the main chat's search (the Swift
// ChatSearchHit): a title match has MessageID 0 and its title as the
// snippet; a message match's snippet wraps the matched terms in
// ChatSearchMarkStart/ChatSearchMarkEnd. Date is what the phone shows next
// to it: the message's created_at, or the conversation's updated_at for a
// title match (Unix seconds; the Swift hit carries none).
type ChatSearchHit struct {
	ConversationID int64
	MessageID      int64
	Title          string
	Snippet        string
	Date           float64
}

// ChatSearchFTSQuery is ChatSearchQueries.ftsQuery: every letter/number run
// of raw quoted (so FTS syntax in it is inert) and prefix-matched, joined by
// spaces (FTS5's AND); false when raw has none. Runs split per grapheme
// cluster, as Swift's Character does, on its first scalar.
func ChatSearchFTSQuery(raw string) (string, bool) {
	var tokens []string
	var cur strings.Builder
	g := uniseg.NewGraphemes(raw)
	for g.Next() {
		if r := g.Runes(); len(r) > 0 && isSwiftLetterOrNumber(r[0]) {
			cur.WriteString(g.Str())
			continue
		}
		if cur.Len() > 0 {
			tokens = append(tokens, cur.String())
			cur.Reset()
		}
	}
	if cur.Len() > 0 {
		tokens = append(tokens, cur.String())
	}
	if len(tokens) == 0 {
		return "", false
	}
	for i, t := range tokens {
		tokens[i] = `"` + t + `"*`
	}
	return strings.Join(tokens, " "), true
}

// isSwiftLetterOrNumber is Character.isLetter || isNumber on a first
// scalar: the Alphabetic property (letters, letter numbers, other
// alphabetic marks) or any numeric type.
func isSwiftLetterOrNumber(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.Is(unicode.Other_Alphabetic, r)
}

// SearchChats is the Go port of the Mac's ⌘K reader (ChatSearchQueries.search,
// shared fixture testdata/chat_search_cases.json): the title matches (LIKE,
// newest first) then the message matches (chat_fts MATCH, bm25 order, owner
// and assistant rows only), both over main-chat conversations that are not
// archived, cut to limit. A query with no letter or number finds nothing.
// Display only (LIVE-01): the hits are shown on the phone, never stored.
func (db *DB) SearchChats(q string, limit int) ([]ChatSearchHit, error) {
	match, ok := ChatSearchFTSQuery(q)
	if !ok || limit <= 0 {
		return nil, nil
	}
	titles, err := db.chatTitleMatches(strings.TrimSpace(q), limit)
	if err != nil {
		return nil, err
	}
	messages, err := db.chatMessageMatches(match, limit)
	if err != nil {
		return nil, err
	}
	out := append(titles, messages...)
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (db *DB) chatTitleMatches(q string, limit int) ([]ChatSearchHit, error) {
	escaped := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(q)
	rows, err := db.Query(`SELECT id, title, updated_at FROM chat_conversations
		WHERE context_type IS NULL AND archived_at IS NULL AND title LIKE ? ESCAPE '\'
		ORDER BY updated_at DESC LIMIT ?`, "%"+escaped+"%", limit)
	if err != nil {
		return nil, fmt.Errorf("searching chat titles: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []ChatSearchHit
	for rows.Next() {
		var h ChatSearchHit
		if err := rows.Scan(&h.ConversationID, &h.Title, &h.Date); err != nil {
			return nil, fmt.Errorf("searching chat titles: %w", err)
		}
		h.Snippet = h.Title
		out = append(out, h)
	}
	return out, rows.Err()
}

func (db *DB) chatMessageMatches(match string, limit int) ([]ChatSearchHit, error) {
	rows, err := db.Query(`SELECT m.conversation_id, m.id, c.title,
			snippet(chat_fts, 0, ?, ?, '…', 12), m.created_at
		FROM chat_fts
		JOIN chat_messages m ON m.id = chat_fts.rowid
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE chat_fts MATCH ? AND c.context_type IS NULL AND c.archived_at IS NULL
		  AND m.role IN ('user', 'assistant')
		ORDER BY bm25(chat_fts) LIMIT ?`, ChatSearchMarkStart, ChatSearchMarkEnd, match, limit)
	if err != nil {
		return nil, fmt.Errorf("searching chat messages: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []ChatSearchHit
	for rows.Next() {
		var h ChatSearchHit
		if err := rows.Scan(&h.ConversationID, &h.MessageID, &h.Title, &h.Snippet, &h.Date); err != nil {
			return nil, fmt.Errorf("searching chat messages: %w", err)
		}
		out = append(out, h)
	}
	return out, rows.Err()
}
