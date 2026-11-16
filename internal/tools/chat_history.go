package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/db"
)

// A chat turn replays only the newest part of its own conversation (the
// replay cap in internal/chat), so a long chat loses its early messages and
// the artifacts made in them. These reads let the assistant open the rest of
// its own conversation — the bound one only, never another chat's.

const (
	chatHistoryDefaultLimit  = 20
	chatHistoryMaxLimit      = 50
	chatHistoryDefaultChars  = 6000
	chatHistoryMaxChars      = 30000
	chatHistoryResponseChars = 60000
	chatArtifactDefaultChars = 20000
	chatArtifactMaxChars     = 50000
)

// chatHistorySurfaces are the chats that have a conversation of their own to read.
func chatHistorySurfaces() []string { return []string{"main", "target", AutomationEditorSurface} }

type getChatHistoryArgs struct {
	Before   int64  `json:"before,omitempty" jsonschema:"only messages older than this message id (page back with next_before); 0 = from the newest"`
	Limit    int    `json:"limit,omitempty" jsonschema:"max messages, 0 = default (20), capped at 50"`
	Query    string `json:"query,omitempty" jsonschema:"only messages whose text contains this (case-insensitive)"`
	MaxChars int    `json:"max_chars,omitempty" jsonschema:"max characters per message, 0 = default (6000), capped at 30000"`
}

type chatHistoryMessage struct {
	ID        int64  `json:"id"`
	Role      string `json:"role"`
	Status    string `json:"status"`
	CreatedAt string `json:"created_at"`
	Text      string `json:"text"`
	Chars     int    `json:"chars"`
	Truncated bool   `json:"truncated"`
}

type chatHistoryResult struct {
	Total      int                  `json:"total"`
	Messages   []chatHistoryMessage `json:"messages"`
	HasMore    bool                 `json:"has_more"`
	NextBefore int64                `json:"next_before,omitempty"`
}

type getChatArtifactArgs struct {
	Key      string `json:"key" jsonschema:"artifact key from list_chat_artifacts"`
	Version  int    `json:"version,omitempty" jsonschema:"artifact version, 0 = the latest"`
	FromChar int    `json:"from_char,omitempty" jsonschema:"start the content at this character (page through a long artifact); 0 = the start"`
	MaxChars int    `json:"max_chars,omitempty" jsonschema:"max characters of content, 0 = default (20000), capped at 50000"`
}

type chatArtifactRow struct {
	Key       string `json:"key"`
	Kind      string `json:"kind"`
	Title     string `json:"title"`
	Version   int    `json:"version"`
	Versions  int    `json:"versions"`
	MessageID int64  `json:"message_id"`
	Edited    bool   `json:"edited_by_owner"`
	Chars     int    `json:"chars"`
	CreatedAt string `json:"created_at"`
}

func boundConversation(call Call) (int64, error) {
	if call.Binding.ConversationID <= 0 {
		return 0, &ValidationError{Msg: "this session is not bound to a chat conversation, so there is no chat history to read"}
	}
	return call.Binding.ConversationID, nil
}

func chatTime(sec float64) string {
	return time.Unix(int64(sec), 0).UTC().Format(time.RFC3339)
}

// NewGetChatHistory reads the bound conversation's own messages, newest
// first by page, so the assistant can see what fell out of its replay.
func NewGetChatHistory() *Tool {
	return &Tool{
		Name: "get_chat_history",
		Description: "Read this chat's own earlier messages (the owner's and yours) from Watchtower's history. Your turn " +
			"replays only the newest part of a long conversation, so use this when the owner refers to something said or " +
			"made earlier that you no longer see. Returns the newest messages first page in chronological order; page back " +
			"with before = next_before, or filter with query. Artifacts you made: list_chat_artifacts / get_chat_artifact.",
		InputSchema: mustSchema[getChatHistoryArgs]("get_chat_history"),
		Access:      AccessRead,
		CompanyData: true,
		Surfaces:    chatHistorySurfaces(),
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getChatHistoryArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments", Err: err}
			}
			conv, err := boundConversation(call)
			if err != nil {
				return nil, err
			}
			path, err := d.ActiveChatPath(conv)
			if err != nil {
				return nil, err
			}
			return pageChatHistory(path, a), nil
		},
	}
}

// pageChatHistory picks the page a asks for from path (root first).
func pageChatHistory(path []db.ChatMessage, a getChatHistoryArgs) chatHistoryResult {
	limit := clampInt(a.Limit, chatHistoryDefaultLimit, chatHistoryMaxLimit)
	maxChars := clampInt(a.MaxChars, chatHistoryDefaultChars, chatHistoryMaxChars)
	query := strings.ToLower(strings.TrimSpace(a.Query))

	var picked []db.ChatMessage
	for _, m := range path {
		if a.Before > 0 && m.ID >= a.Before {
			continue
		}
		if query != "" && !strings.Contains(strings.ToLower(m.Text), query) {
			continue
		}
		picked = append(picked, m)
	}
	res := chatHistoryResult{Total: len(path), Messages: []chatHistoryMessage{}}
	start, used := len(picked), 0
	for i := len(picked) - 1; i >= 0 && len(picked)-i <= limit; i-- {
		n := min(utf8.RuneCountInString(picked[i].Text), maxChars)
		if used+n > chatHistoryResponseChars && start < len(picked) {
			break
		}
		used += n
		start = i
	}
	for _, m := range picked[start:] {
		text, cut := cutRunes(m.Text, 0, maxChars)
		res.Messages = append(res.Messages, chatHistoryMessage{
			ID: m.ID, Role: m.Role, Status: m.Status, CreatedAt: chatTime(m.CreatedAt),
			Text: text, Chars: utf8.RuneCountInString(m.Text), Truncated: cut,
		})
	}
	if start > 0 {
		res.HasMore = true
		res.NextBefore = picked[start].ID
	}
	return res
}

// NewListChatArtifacts lists the artifacts made in the bound conversation,
// latest version of each.
func NewListChatArtifacts() *Tool {
	return &Tool{
		Name: "list_chat_artifacts",
		Description: "List the artifacts (documents, tables, code, pages, drafts) made in this chat, oldest first, the " +
			"latest version of each with its key, kind, title, version count, size and whether the owner edited it. " +
			"Open one with get_chat_artifact.",
		InputSchema: mustSchema[struct{}]("list_chat_artifacts"),
		Access:      AccessRead,
		CompanyData: true,
		Surfaces:    chatHistorySurfaces(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			conv, err := boundConversation(call)
			if err != nil {
				return nil, err
			}
			rows, err := d.QueryContext(ctx, `SELECT a.artifact_key, a.kind, a.title, a.version, a.message_id, a.edited,
  length(a.content), a.created_at,
  (SELECT COUNT(*) FROM chat_artifacts c WHERE c.conversation_id = a.conversation_id AND c.artifact_key = a.artifact_key)
FROM chat_artifacts a
WHERE a.conversation_id = ? AND a.version = (SELECT MAX(b.version) FROM chat_artifacts b
  WHERE b.conversation_id = a.conversation_id AND b.artifact_key = a.artifact_key)
ORDER BY a.id`, conv)
			if err != nil {
				return nil, fmt.Errorf("listing chat artifacts: %w", err)
			}
			defer rows.Close()
			out := []chatArtifactRow{}
			for rows.Next() {
				var r chatArtifactRow
				var created float64
				if err := rows.Scan(&r.Key, &r.Kind, &r.Title, &r.Version, &r.MessageID, &r.Edited,
					&r.Chars, &created, &r.Versions); err != nil {
					return nil, fmt.Errorf("scanning chat artifact: %w", err)
				}
				r.CreatedAt = chatTime(created)
				out = append(out, r)
			}
			if err := rows.Err(); err != nil {
				return nil, fmt.Errorf("listing chat artifacts: %w", err)
			}
			return map[string]any{"artifacts": out}, nil
		},
	}
}

// NewGetChatArtifact returns one artifact of the bound conversation — the
// stored version, owner edits included.
func NewGetChatArtifact() *Tool {
	return &Tool{
		Name: "get_chat_artifact",
		Description: "Open an artifact made in this chat by its key (from list_chat_artifacts): the stored content of the " +
			"latest version (owner edits included) or of the version you name. Page a long one with from_char.",
		InputSchema: mustSchema[getChatArtifactArgs]("get_chat_artifact"),
		Access:      AccessRead,
		CompanyData: true,
		Surfaces:    chatHistorySurfaces(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getChatArtifactArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments", Err: err}
			}
			conv, err := boundConversation(call)
			if err != nil {
				return nil, err
			}
			key := strings.TrimSpace(a.Key)
			if key == "" {
				return nil, &ValidationError{Msg: "key is required (from list_chat_artifacts)"}
			}
			if a.Version < 0 || a.FromChar < 0 {
				return nil, &ValidationError{Msg: "version and from_char must not be negative"}
			}
			var r chatArtifactRow
			var content string
			var created float64
			err = d.QueryRowContext(ctx, `SELECT a.artifact_key, a.kind, a.title, a.version, a.message_id, a.edited,
  a.content, a.created_at,
  (SELECT COUNT(*) FROM chat_artifacts c WHERE c.conversation_id = a.conversation_id AND c.artifact_key = a.artifact_key)
FROM chat_artifacts a
WHERE a.conversation_id = ? AND a.artifact_key = ? AND (? = 0 OR a.version = ?)
ORDER BY a.version DESC LIMIT 1`, conv, key, a.Version, a.Version).Scan(
				&r.Key, &r.Kind, &r.Title, &r.Version, &r.MessageID, &r.Edited, &content, &created, &r.Versions)
			if errors.Is(err, sql.ErrNoRows) {
				return nil, &ValidationError{Msg: "no artifact " + key + " (that version) in this chat — see list_chat_artifacts"}
			}
			if err != nil {
				return nil, fmt.Errorf("reading chat artifact: %w", err)
			}
			r.CreatedAt = chatTime(created)
			r.Chars = utf8.RuneCountInString(content)
			text, more := cutRunes(content, a.FromChar, clampInt(a.MaxChars, chatArtifactDefaultChars, chatArtifactMaxChars))
			out := map[string]any{"artifact": r, "from_char": a.FromChar, "content": text, "has_more": more}
			if more {
				out["next_from_char"] = a.FromChar + utf8.RuneCountInString(text)
			}
			return out, nil
		},
	}
}

// clampInt is v, or def when v <= 0, never above hi.
func clampInt(v, def, hi int) int {
	if v <= 0 {
		return def
	}
	return min(v, hi)
}

// cutRunes returns s's runes [from, from+n) and whether s goes on past them.
func cutRunes(s string, from, n int) (string, bool) {
	r := []rune(s)
	if from >= len(r) {
		return "", false
	}
	end := min(from+n, len(r))
	return string(r[from:end]), end < len(r)
}
