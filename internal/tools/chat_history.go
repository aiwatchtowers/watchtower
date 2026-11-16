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
	chatArtifactDefaultChars = 20000
	chatArtifactMaxChars     = 50000
	chatArtifactListLimit    = 50
	// chatTextBudget bounds the JSON-encoded text of one response, so a
	// default call stays under READ-01's MaxReadResultBytes even for text
	// json.Marshal escapes to six bytes a character (<, >, & in HTML).
	chatTextBudget = 160 * 1024
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
	ErrorCode string `json:"error_code,omitempty"`
	CreatedAt string `json:"created_at"`
	Text      string `json:"text"`
	Chars     int    `json:"chars"`
	Truncated bool   `json:"truncated"`
}

type chatHistoryResult struct {
	// Total is the messages in the conversation's visible thread; Matched
	// the ones the before/query filters leave, this page included.
	Total      int                  `json:"total"`
	Matched    int                  `json:"matched"`
	Messages   []chatHistoryMessage `json:"messages"`
	HasMore    bool                 `json:"has_more"`
	NextBefore int64                `json:"next_before,omitempty"`
}

type listChatArtifactsArgs struct {
	Limit int `json:"limit,omitempty" jsonschema:"max artifacts, the most recently changed ones, 0 = default (50), capped at 200"`
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

// boundConversation is the conversation the session is bound to. A session
// bound to none, to one since deleted, or to an isolated thread is refused
// rather than shown an empty chat: code questions, spec review threads,
// tuning chats and branch reviewer threads stay in their own card
// (TestCodeQuestionGuard_NoGoToolReadsChatHistory).
func boundConversation(ctx context.Context, d *db.DB, call Call) (int64, error) {
	id := call.Binding.ConversationID
	if id <= 0 {
		return 0, &ValidationError{Msg: "this session is not bound to a chat conversation, so there is no chat history to read"}
	}
	var isolated bool
	err := d.QueryRowContext(ctx, `SELECT COALESCE(context_type, '') IN
  ('code_question', 'spec_review_thread', 'analytics_tuning', 'review_reviewer')
FROM chat_conversations WHERE id = ?`, id).Scan(&isolated)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, &ValidationError{Msg: fmt.Sprintf("chat conversation %d no longer exists", id)}
	}
	if err != nil {
		return 0, fmt.Errorf("reading chat conversation %d: %w", id, err)
	}
	if isolated {
		return 0, &ValidationError{Msg: "this chat's history is not readable through tools"}
	}
	return id, nil
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
			"made earlier that you no longer see. Returns the newest page of messages in chronological order; page back " +
			"with before = next_before, or filter with query (total = messages in the chat, matched = after the filters). " +
			"Artifacts you made: list_chat_artifacts / get_chat_artifact.",
		InputSchema: mustSchema[getChatHistoryArgs]("get_chat_history"),
		Access:      AccessRead,
		CompanyData: true,
		Surfaces:    chatHistorySurfaces(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getChatHistoryArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments", Err: err}
			}
			conv, err := boundConversation(ctx, d, call)
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

// pageChatHistory picks the page a asks for from path (root first): the
// newest matching messages, at most limit of them and chatTextBudget encoded
// bytes of text (always at least one message).
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
	res := chatHistoryResult{Total: len(path), Matched: len(picked), Messages: []chatHistoryMessage{}}
	var page []chatHistoryMessage // newest first
	start, left := len(picked), chatTextBudget
	for i := len(picked) - 1; i >= 0 && len(page) < limit && left > 0; i-- {
		m := picked[i]
		text, cut, used := cutText(m.Text, 0, maxChars, left)
		if used == 0 && m.Text != "" && len(page) > 0 {
			break
		}
		left -= used
		page = append(page, chatHistoryMessage{
			ID: m.ID, Role: m.Role, Status: m.Status, ErrorCode: m.ErrorCode, CreatedAt: chatTime(m.CreatedAt),
			Text: text, Chars: utf8.RuneCountInString(m.Text), Truncated: cut,
		})
		start = i
	}
	for i := len(page) - 1; i >= 0; i-- {
		res.Messages = append(res.Messages, page[i])
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
		Description: "List the artifacts (documents, tables, code, pages, drafts) made in this chat — every branch of it — " +
			"the latest version of each with its key, kind, title, version count, size and whether the owner edited it, " +
			"in the order they last changed (the most recent limit of them). Open one with get_chat_artifact.",
		InputSchema: mustSchema[listChatArtifactsArgs]("list_chat_artifacts"),
		Access:      AccessRead,
		CompanyData: true,
		Surfaces:    chatHistorySurfaces(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a listChatArtifactsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments", Err: err}
			}
			conv, err := boundConversation(ctx, d, call)
			if err != nil {
				return nil, err
			}
			limit := clampInt(a.Limit, chatArtifactListLimit, MaxListLimit)
			rows, err := d.QueryContext(ctx, `SELECT * FROM (
  SELECT a.id, a.artifact_key, a.kind, a.title, a.version, a.message_id, a.edited,
    length(a.content), a.created_at,
    (SELECT COUNT(*) FROM chat_artifacts c WHERE c.conversation_id = a.conversation_id AND c.artifact_key = a.artifact_key)
  FROM chat_artifacts a
  WHERE a.conversation_id = ? AND a.version = (SELECT MAX(b.version) FROM chat_artifacts b
    WHERE b.conversation_id = a.conversation_id AND b.artifact_key = a.artifact_key)
  ORDER BY a.id DESC LIMIT ?) ORDER BY 1`, conv, limit+1)
			if err != nil {
				return nil, fmt.Errorf("listing chat artifacts: %w", err)
			}
			defer rows.Close()
			out := []chatArtifactRow{}
			for rows.Next() {
				var r chatArtifactRow
				var id int64
				var created float64
				if err := rows.Scan(&id, &r.Key, &r.Kind, &r.Title, &r.Version, &r.MessageID, &r.Edited,
					&r.Chars, &created, &r.Versions); err != nil {
					return nil, fmt.Errorf("scanning chat artifact: %w", err)
				}
				r.CreatedAt = chatTime(created)
				out = append(out, r)
			}
			if err := rows.Err(); err != nil {
				return nil, fmt.Errorf("listing chat artifacts: %w", err)
			}
			more := len(out) > limit
			if more {
				out = out[1:] // the oldest of limit+1
			}
			return map[string]any{"artifacts": out, "has_more": more}, nil
		},
	}
}

// NewGetChatArtifact returns one artifact of the bound conversation — the
// stored version, owner edits included.
func NewGetChatArtifact() *Tool {
	return &Tool{
		Name: "get_chat_artifact",
		Description: "Open an artifact made in this chat by its key (from list_chat_artifacts): the stored content and " +
			"attributes (meta: recipients, subject, channel, times, language) of the latest version, owner edits included, " +
			"or of the version you name. To revise it, emit it again in full with the same key and these attributes. " +
			"Page a long one with from_char = next_from_char.",
		InputSchema: mustSchema[getChatArtifactArgs]("get_chat_artifact"),
		Access:      AccessRead,
		CompanyData: true,
		Surfaces:    chatHistorySurfaces(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getChatArtifactArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments", Err: err}
			}
			conv, err := boundConversation(ctx, d, call)
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
			r, content, meta, err := readChatArtifact(ctx, d, conv, key, a.Version)
			if err != nil {
				return nil, err
			}
			if a.FromChar > 0 && a.FromChar >= r.Chars {
				return nil, &ValidationError{Msg: fmt.Sprintf("from_char %d is past the end: the artifact has %d characters", a.FromChar, r.Chars)}
			}
			text, more, _ := cutText(content, a.FromChar, clampInt(a.MaxChars, chatArtifactDefaultChars, chatArtifactMaxChars), chatTextBudget)
			out := map[string]any{"artifact": r, "meta": meta, "from_char": a.FromChar, "content": text, "has_more": more}
			if more {
				out["next_from_char"] = a.FromChar + utf8.RuneCountInString(text)
			}
			return out, nil
		},
	}
}

// readChatArtifact reads one version (0 = the latest) of key in conv.
func readChatArtifact(ctx context.Context, d *db.DB, conv int64, key string, version int) (chatArtifactRow, string, json.RawMessage, error) {
	var r chatArtifactRow
	var content, meta string
	var created float64
	err := d.QueryRowContext(ctx, `SELECT a.artifact_key, a.kind, a.title, a.version, a.message_id, a.edited,
  a.content, a.meta_json, a.created_at,
  (SELECT COUNT(*) FROM chat_artifacts c WHERE c.conversation_id = a.conversation_id AND c.artifact_key = a.artifact_key)
FROM chat_artifacts a
WHERE a.conversation_id = ? AND a.artifact_key = ? AND (? = 0 OR a.version = ?)
ORDER BY a.version DESC LIMIT 1`, conv, key, version, version).Scan(
		&r.Key, &r.Kind, &r.Title, &r.Version, &r.MessageID, &r.Edited, &content, &meta, &created, &r.Versions)
	if errors.Is(err, sql.ErrNoRows) {
		return r, "", nil, missingArtifact(ctx, d, conv, key, version)
	}
	if err != nil {
		return r, "", nil, fmt.Errorf("reading chat artifact: %w", err)
	}
	r.CreatedAt = chatTime(created)
	r.Chars = utf8.RuneCountInString(content)
	if !json.Valid([]byte(meta)) {
		meta = "{}"
	}
	return r, content, json.RawMessage(meta), nil
}

// missingArtifact says whether the key or only the version is missing.
func missingArtifact(ctx context.Context, d *db.DB, conv int64, key string, version int) error {
	var n int
	if err := d.QueryRowContext(ctx, `SELECT COUNT(*) FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ?`,
		conv, key).Scan(&n); err != nil {
		return fmt.Errorf("reading chat artifact: %w", err)
	}
	if n == 0 {
		return &ValidationError{Msg: fmt.Sprintf("no artifact %q in this chat — see list_chat_artifacts", key)}
	}
	return &ValidationError{Msg: fmt.Sprintf("artifact %q has no version %d (it has %d)", key, version, n)}
}

// clampInt is v, or def when v <= 0, never above hi.
func clampInt(v, def, hi int) int {
	if v <= 0 {
		return def
	}
	return min(v, hi)
}

// cutText returns s's runes from index from on, at most n of them and at most
// maxBytes JSON-encoded bytes, whether s goes on past them, and the encoded
// bytes used.
func cutText(s string, from, n, maxBytes int) (string, bool, int) {
	var b strings.Builder
	idx, taken, used := 0, 0, 0
	for _, r := range s {
		if idx < from {
			idx++
			continue
		}
		if taken == n {
			return b.String(), true, used
		}
		w := jsonRuneLen(r)
		if used+w > maxBytes {
			return b.String(), true, used
		}
		b.WriteRune(r)
		taken++
		idx++
		used += w
	}
	return b.String(), false, used
}

// jsonRuneLen is how many bytes encoding/json writes for r inside a string.
func jsonRuneLen(r rune) int {
	switch {
	case r == '"' || r == '\\' || r == '\n' || r == '\r' || r == '\t':
		return 2
	case r < 0x20 || r == '<' || r == '>' || r == '&' || r == 0x2028 || r == 0x2029 || r == utf8.RuneError:
		return 6
	default:
		return utf8.RuneLen(r)
	}
}
