package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ChatTurn is one message of a Desktop assistant conversation, projected for
// the Go side (the next-step prompt builder). Role is verbatim from
// chat_messages.role — 'user', 'assistant' or 'system'; system turns carry the
// "Action applied: ..." lines the Desktop writes after an approved action and
// are the highest-signal record of what was actually done.
type ChatTurn struct {
	ID        int64  // chat_messages.id
	Role      string // user | assistant | system
	Text      string // verbatim message text
	CreatedAt int64  // created_at truncated to whole unix seconds
}

// ListRecentChatTurns returns up to limit most recent messages across every
// conversation of one (context_type, context_id) pair — e.g. ("target", "42") —
// ordered oldest-first (newest LAST), so the caller can render them as a
// chronological excerpt. A context may own several conversations (the assistant
// tabs), and they are read together.
//
// The chat tables are goose-owned since migration 00076, so they always exist
// after Open; ChatTablesPresent stays as a cheap guard for a handle opened on a
// pre-00076 file. A non-positive limit is a clean empty read.
func (db *DB) ListRecentChatTurns(contextType, contextID string, limit int) ([]ChatTurn, error) {
	if contextType == "" || contextID == "" || limit <= 0 {
		return nil, nil
	}
	present, err := db.ChatTablesPresent()
	if err != nil {
		return nil, err
	}
	if !present {
		return nil, nil
	}

	// Newest first so LIMIT keeps the RECENT tail, then reversed below. Only
	// the active branch counts (spec §2.2): an edited or regenerated message's
	// abandoned sibling never reaches the next-step prompt.
	rows, err := db.Query(activeBranchCTE+`SELECT m.id, m.role, m.text, CAST(m.created_at AS INTEGER)
		FROM chat_messages m
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE c.context_type = ? AND c.context_id = ? AND `+onActiveBranch+`
		ORDER BY m.created_at DESC, m.id DESC
		LIMIT ?`, contextType, contextID, limit)
	if err != nil {
		return nil, fmt.Errorf("listing recent chat turns for %s/%s: %w", contextType, contextID, err)
	}
	defer rows.Close()

	var newestFirst []ChatTurn
	for rows.Next() {
		var t ChatTurn
		if err := rows.Scan(&t.ID, &t.Role, &t.Text, &t.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning chat turn: %w", err)
		}
		newestFirst = append(newestFirst, t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out := make([]ChatTurn, 0, len(newestFirst))
	for i := len(newestFirst) - 1; i >= 0; i-- {
		out = append(out, newestFirst[i])
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

// activeBranchCTE yields active_path(id, parent_id): every message on its
// conversation's active branch (root → active_leaf_message_id). Paired with
// onActiveBranch. The p.id < a.id guard makes a malformed parent cycle
// terminate instead of recursing forever (a parent always predates its child).
const activeBranchCTE = `WITH RECURSIVE active_path(id, parent_id) AS (
	SELECT m.id, m.parent_id FROM chat_messages m
	JOIN chat_conversations c ON c.id = m.conversation_id AND c.active_leaf_message_id = m.id
	UNION ALL
	SELECT p.id, p.parent_id FROM chat_messages p
	JOIN active_path a ON p.id = a.parent_id AND p.id < a.id
)
`

// onActiveBranch filters messages m of conversation c to the active branch. A
// conversation without an active leaf — every Discuss chat and every legacy
// row — keeps all its messages (linear), as does one whose leaf row is gone.
const onActiveBranch = `(c.active_leaf_message_id IS NULL
	OR NOT EXISTS (SELECT 1 FROM chat_messages leaf
		WHERE leaf.id = c.active_leaf_message_id AND leaf.conversation_id = c.id)
	OR m.id IN (SELECT id FROM active_path))`

// ChatMessage is one chat_messages row, as the chat engine reads it.
type ChatMessage struct {
	ID, ConversationID         int64
	ParentID                   sql.NullInt64
	Role, Text, TurnID, Status string
	Provider, Model, ErrorCode string
	CreatedAt                  float64
}

const chatMessageColumns = `m.id, m.conversation_id, m.parent_id, m.role, m.text, m.turn_id, m.status,
	COALESCE(m.provider, ''), COALESCE(m.model, ''), COALESCE(m.error_code, ''), m.created_at`

func scanChatMessages(rows *sql.Rows) ([]ChatMessage, error) {
	defer rows.Close()
	var out []ChatMessage
	for rows.Next() {
		var m ChatMessage
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.ParentID, &m.Role, &m.Text, &m.TurnID, &m.Status,
			&m.Provider, &m.Model, &m.ErrorCode, &m.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning chat message: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ActiveChatPath returns the conversation's visible thread, root first: the
// parent chain of active_leaf_message_id. When the leaf is NULL (a legacy or
// Discuss conversation) or points at a deleted row, it falls back to every
// message in id order. An unknown conversation is (nil, nil).
func (db *DB) ActiveChatPath(conversationID int64) ([]ChatMessage, error) {
	var leaf sql.NullInt64
	err := db.QueryRow(`SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?`, conversationID).Scan(&leaf)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading active leaf of conversation %d: %w", conversationID, err)
	}
	if leaf.Valid {
		rows, err := db.Query(`WITH RECURSIVE path(id, parent_id, depth) AS (
				SELECT id, parent_id, 0 FROM chat_messages WHERE id = ? AND conversation_id = ?
				UNION ALL
				SELECT p.id, p.parent_id, path.depth + 1 FROM chat_messages p
				JOIN path ON p.id = path.parent_id AND p.id < path.id
			)
			SELECT `+chatMessageColumns+` FROM chat_messages m JOIN path ON path.id = m.id
			ORDER BY path.depth DESC`, leaf.Int64, conversationID)
		if err != nil {
			return nil, fmt.Errorf("reading active path of conversation %d: %w", conversationID, err)
		}
		out, err := scanChatMessages(rows)
		if err != nil || len(out) > 0 {
			return out, err
		}
	}
	rows, err := db.Query(`SELECT `+chatMessageColumns+` FROM chat_messages m
		WHERE m.conversation_id = ? ORDER BY m.id`, conversationID)
	if err != nil {
		return nil, fmt.Errorf("reading messages of conversation %d: %w", conversationID, err)
	}
	return scanChatMessages(rows)
}

// ChatConversation is the part of a chat_conversations row the Go side reads.
type ChatConversation struct {
	ID                                                                     int64
	Title, TitleSource, SessionID, ContextType, ContextID, Provider, Model string
	ProjectID                                                              sql.NullInt64
}

// GetChatConversation reads one conversation; (nil, nil) when absent.
func (db *DB) GetChatConversation(id int64) (*ChatConversation, error) {
	var c ChatConversation
	err := db.QueryRow(`SELECT id, title, title_source, COALESCE(session_id, ''), COALESCE(context_type, ''),
			COALESCE(context_id, ''), COALESCE(provider, ''), COALESCE(model, ''), project_id
		FROM chat_conversations WHERE id = ?`, id).Scan(&c.ID, &c.Title, &c.TitleSource, &c.SessionID,
		&c.ContextType, &c.ContextID, &c.Provider, &c.Model, &c.ProjectID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading chat conversation %d: %w", id, err)
	}
	return &c, nil
}

// SetChatTitle writes a conversation title and its source. It never
// overwrites an owner-set title: when the stored title_source is 'user' it
// writes nothing and returns false. The Go side only ever writes 'ai'
// (`watchtower chat title`); Swift owns 'prefix' and 'user'.
func (db *DB) SetChatTitle(id int64, title, source string) (bool, error) {
	switch source {
	case "prefix", "ai", "user":
	default:
		return false, fmt.Errorf("invalid chat title source %q", source)
	}
	res, err := db.Exec(`UPDATE chat_conversations SET title = ?, title_source = ?
		WHERE id = ? AND title_source != 'user'`, title, source, id)
	if err != nil {
		return false, fmt.Errorf("setting title of conversation %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting title of conversation %d: %w", id, err)
	}
	return n > 0, nil
}

// ChatProjectSource is one pinned source of a chat project.
type ChatProjectSource struct{ Kind, Ref, Label string }

// ChatProjectFile is one file attached to a chat project.
type ChatProjectFile struct {
	ID               int64
	Name, Mime, Path string
	Size             int64
}

// ChatProjectContext is what a chat session needs from a project: its
// instructions, pinned sources and files, split into text-like files (inlined
// into the prompt) and binaries (images/PDFs, attached to the first turn).
type ChatProjectContext struct {
	Name, Instructions string
	Sources            []ChatProjectSource
	TextFiles          []ChatProjectFile
	BinaryFiles        []ChatProjectFile
}

// isBinaryChatMime reports whether a project file travels as a content block
// (image or PDF) rather than as inlined text.
func isBinaryChatMime(mime string) bool {
	return strings.HasPrefix(mime, "image/") || mime == "application/pdf"
}

// GetChatProjectContext reads a project with its sources and files; (nil, nil)
// when the project does not exist.
func (db *DB) GetChatProjectContext(projectID int64) (*ChatProjectContext, error) {
	var pc ChatProjectContext
	err := db.QueryRow(`SELECT name, instructions FROM chat_projects WHERE id = ?`, projectID).
		Scan(&pc.Name, &pc.Instructions)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading chat project %d: %w", projectID, err)
	}
	if pc.Sources, err = db.chatProjectSources(projectID); err != nil {
		return nil, err
	}
	rows, err := db.Query(`SELECT id, name, mime, path, size FROM chat_attachments
		WHERE project_id = ? ORDER BY id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading files of chat project %d: %w", projectID, err)
	}
	defer rows.Close()
	for rows.Next() {
		var f ChatProjectFile
		if err := rows.Scan(&f.ID, &f.Name, &f.Mime, &f.Path, &f.Size); err != nil {
			return nil, fmt.Errorf("scanning chat project file: %w", err)
		}
		if isBinaryChatMime(f.Mime) {
			pc.BinaryFiles = append(pc.BinaryFiles, f)
		} else {
			pc.TextFiles = append(pc.TextFiles, f)
		}
	}
	return &pc, rows.Err()
}

func (db *DB) chatProjectSources(projectID int64) ([]ChatProjectSource, error) {
	rows, err := db.Query(`SELECT kind, ref, label FROM chat_project_sources WHERE project_id = ? ORDER BY id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading sources of chat project %d: %w", projectID, err)
	}
	defer rows.Close()
	var out []ChatProjectSource
	for rows.Next() {
		var s ChatProjectSource
		if err := rows.Scan(&s.Kind, &s.Ref, &s.Label); err != nil {
			return nil, fmt.Errorf("scanning chat project source: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// ChatStepSummaries returns, per assistant message, one line per tool step in
// seq order — "name: summary", or "name (failed): summary" — for the replay
// transcript (tool steps are replayed as one-line summaries, never in full).
func (db *DB) ChatStepSummaries(messageIDs []int64) (map[int64][]string, error) {
	if len(messageIDs) == 0 {
		return nil, nil
	}
	ph := make([]string, len(messageIDs))
	args := make([]any, len(messageIDs))
	for i, id := range messageIDs {
		ph[i] = "?"
		args[i] = id
	}
	rows, err := db.Query(`SELECT message_id, name, ok, summary FROM chat_turn_steps
		WHERE message_id IN (`+strings.Join(ph, ",")+`) ORDER BY message_id, seq`, args...)
	if err != nil {
		return nil, fmt.Errorf("reading chat turn steps: %w", err)
	}
	defer rows.Close()
	out := map[int64][]string{}
	for rows.Next() {
		var (
			msgID         int64
			name, summary string
			ok            sql.NullInt64
		)
		if err := rows.Scan(&msgID, &name, &ok, &summary); err != nil {
			return nil, fmt.Errorf("scanning chat turn step: %w", err)
		}
		label := name
		if ok.Valid && ok.Int64 == 0 {
			label += " (failed)"
		}
		if summary != "" {
			label += ": " + summary
		}
		out[msgID] = append(out[msgID], label)
	}
	return out, rows.Err()
}
