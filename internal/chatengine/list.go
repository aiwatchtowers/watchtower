package chatengine

// The list: the Chats panel's read (ChatHistoryQueries.panelRows), its
// projects and the composer's models.

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/providers"
	"watchtower/internal/wiretime"
)

// The list caps (iPhone chat spec §4.6).
const (
	MaxListConversations = 200
	MaxLastLine          = 120
)

// The list row states, by precedence (ChatPanelRowState).
const (
	StateWaiting   = "waiting"
	StateAnswering = "answering"
	StateUnread    = "unread"
	StateRead      = "read"
)

// ReadList reads the main chat's list: its conversations (not archived,
// pinned first then newest, at most MaxListConversations), its projects
// and the provider catalog's models (RegistryChatModels).
func ReadList(ctx context.Context, d *db.DB, now time.Time) (List, error) {
	out := List{Conversations: []ListConversation{}, Projects: []ListProject{}, Models: RegistryChatModels()}
	if out.Models == nil {
		out.Models = []ChatModel{}
	}
	err := readTx(ctx, d, func(tx *sql.Tx) error {
		var err error
		if out.Conversations, err = chatListRows(ctx, tx, now); err != nil {
			return err
		}
		out.Projects, err = chatListProjects(ctx, tx)
		return err
	})
	return out, err
}

// ChatModel is one model the phone's composer offers (chat_list models[]).
type ChatModel struct {
	Provider    string `json:"provider"`
	Model       string `json:"model"`
	DisplayName string `json:"display_name"`
	Images      bool   `json:"images"`
	PDF         bool   `json:"pdf"`
}

// RegistryChatModels is the provider catalog as the composer needs it: each
// provider the MDM policy allows, with its known models and tier defaults
// (a live-listed provider's installed models are not read here: they need
// a network call) and the attachments its transport takes.
func RegistryChatModels() []ChatModel {
	var out []ChatModel
	for _, p := range providers.All() {
		if providers.Allowed(p.ID) != nil {
			continue
		}
		var models []string
		for _, m := range append(append([]string(nil), p.KnownModels...), p.DefaultLight, p.DefaultStrong) {
			if m != "" && !slices.Contains(models, m) {
				models = append(models, m)
			}
		}
		for _, m := range models {
			out = append(out, ChatModel{Provider: p.ID, Model: m, DisplayName: p.DisplayName, Images: p.Caps.Images, PDF: p.Caps.PDFs})
		}
	}
	return out
}

type ListProject struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

type ListConversation struct {
	ID         int64         `json:"id"`
	Title      string        `json:"title"`
	Pinned     bool          `json:"pinned"`
	UpdatedAt  wiretime.Time `json:"updated_at"`
	Project    *ListProject  `json:"project,omitempty"`
	State      string        `json:"state"`
	LastLine   string        `json:"last_line"`
	LeaseOwner *string       `json:"lease_owner,omitempty"`
	// TurnID is the running turn's id while LeaseOwner is set: the Mac's
	// Inbox strip tells a connector call its chat still holds from one whose
	// session ended.
	TurnID string `json:"turn_id,omitempty"`
	// LastAnswerAt is when the last answer was written (nil before any):
	// the Mac's panel counts a row's age from it, as it did before the
	// unified chat (ChatPanelRowState.secondLine).
	LastAnswerAt *wiretime.Time `json:"last_answer_at,omitempty"`
	// PendingTool is the tool of the oldest pending approval ("" when none
	// waits): the panel's "Waiting for approval: <tool's title>".
	PendingTool string `json:"pending_tool,omitempty"`
	// Unread: a complete answer the owner has not seen, whatever State
	// shows first (the panel's title is semibold while unread).
	Unread bool `json:"unread,omitempty"`
}

type List struct {
	Conversations []ListConversation `json:"conversations"`
	Projects      []ListProject      `json:"projects"`
	Models        []ChatModel        `json:"models"`
	// Routing is the routing pill's catalog (the hub's chat_list fills it;
	// nil leaves the key out, as an older daemon sends).
	Routing *RoutingCatalog `json:"routing,omitempty"`
	Error   *string         `json:"error,omitempty"`
}

// chatListRows is the Chats panel's read (ChatHistoryQueries.panelRows)
// for the phone: the main chat's conversations, not archived, pinned first
// then newest, at most 200, each with its state and its last answer's first
// line. The last answer is the newest complete assistant message on the
// active branch (every message when there is no leaf). waiting = a
// pending agent_actions row of the conversation, the oldest one's tool
// carried as pending_tool (panelRows' pending_tool); answering = a lease with a heartbeat in the last
// 60 s.
func chatListRows(ctx context.Context, tx *sql.Tx, now time.Time) ([]ListConversation, error) {
	rows, err := tx.QueryContext(ctx, `
WITH RECURSIVE listed AS (
    SELECT id, title, pinned, updated_at, project_id, read_at, active_leaf_message_id
    FROM chat_conversations WHERE context_type IS NULL AND archived_at IS NULL
    ORDER BY pinned DESC, updated_at DESC, id DESC LIMIT ?
),
path(conversation_id, message_id) AS (
    SELECT id, active_leaf_message_id FROM listed WHERE active_leaf_message_id IS NOT NULL
    UNION
    SELECT path.conversation_id, m.parent_id FROM path
    JOIN chat_messages m ON m.id = path.message_id
    WHERE m.parent_id IS NOT NULL
),
branch_answer(conversation_id, message_id) AS (
    SELECT path.conversation_id, MAX(m.id) FROM path
    JOIN chat_messages m ON m.id = path.message_id AND m.conversation_id = path.conversation_id
    WHERE m.role = 'assistant' AND m.status = 'complete'
    GROUP BY path.conversation_id
),
last_answer(conversation_id, message_id) AS (
    SELECT c.id, CASE
        WHEN c.active_leaf_message_id IS NULL THEN (
            SELECT MAX(m.id) FROM chat_messages m
            WHERE m.conversation_id = c.id AND m.role = 'assistant' AND m.status = 'complete')
        ELSE (SELECT b.message_id FROM branch_answer b WHERE b.conversation_id = c.id)
    END
    FROM listed c
)
SELECT c.id, c.title, c.pinned, c.updated_at, c.project_id, p.name, c.read_at,
       answer.created_at, substr(answer.text, 1, 2000),
       (SELECT x.tool FROM agent_actions x
        WHERE x.conversation_id = c.id AND x.status = 'pending'
        ORDER BY x.created_at, x.id LIMIT 1),
       l.owner, l.heartbeat_at_ms, l.turn_id
FROM listed c
LEFT JOIN chat_projects p ON p.id = c.project_id
LEFT JOIN last_answer la ON la.conversation_id = c.id
LEFT JOIN chat_messages answer ON answer.id = la.message_id
LEFT JOIN chat_turn_leases l ON l.conversation_id = c.id
ORDER BY c.pinned DESC, c.updated_at DESC, c.id DESC`, MaxListConversations)
	if err != nil {
		return nil, fmt.Errorf("reading the chat list: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []ListConversation{}
	for rows.Next() {
		var (
			c          ListConversation
			updated    float64
			projectID  sql.NullInt64
			project    sql.NullString
			readAt     sql.NullFloat64
			answeredAt sql.NullFloat64
			answer     sql.NullString
			pending    sql.NullString
			owner      sql.NullString
			heartbeat  sql.NullInt64
			turnID     sql.NullString
		)
		if err := rows.Scan(&c.ID, &c.Title, &c.Pinned, &updated, &projectID, &project, &readAt,
			&answeredAt, &answer, &pending, &owner, &heartbeat, &turnID); err != nil {
			return nil, fmt.Errorf("reading the chat list: %w", err)
		}
		c.Title, _ = clipText(c.Title, maxLabel)
		c.UpdatedAt = secondsTime(updated)
		if projectID.Valid {
			name, _ := clipText(project.String, maxLabel)
			c.Project = &ListProject{ID: projectID.Int64, Name: name}
		}
		live := owner.Valid && liveLease(heartbeat.Int64, now)
		if live {
			o := owner.String
			c.LeaseOwner = &o
			c.TurnID = turnID.String
		}
		unread := answeredAt.Valid && (!readAt.Valid || answeredAt.Float64 > readAt.Float64)
		c.State = chatRowState(pending.Valid, live, unread)
		c.Unread = unread
		c.PendingTool, _ = clipText(pending.String, maxLabel)
		if answeredAt.Valid {
			at := secondsTime(answeredAt.Float64)
			c.LastAnswerAt = &at
		}
		c.LastLine, _ = clipText(chatPreview(answer.String), MaxLastLine)
		out = append(out, c)
	}
	return out, rows.Err()
}

// chatRowState is ChatPanelRowState's precedence: waiting > answering >
// unread > read.
func chatRowState(waiting, answering, unread bool) string {
	switch {
	case waiting:
		return StateWaiting
	case answering:
		return StateAnswering
	case unread:
		return StateUnread
	}
	return StateRead
}

// liveLease: a heartbeat at heartbeatMS (Unix ms) is at most
// db.ChatLeaseStaleMS old — nobody may take the lease yet (the claim needs
// older), as Swift's ChatLease.isLive.
func liveLease(heartbeatMS int64, now time.Time) bool {
	return now.UnixMilli()-heartbeatMS <= db.ChatLeaseStaleMS
}

// chatListProjects is the chat projects that are not archived, by name.
func chatListProjects(ctx context.Context, tx *sql.Tx) ([]ListProject, error) {
	rows, err := tx.QueryContext(ctx, `SELECT id, name FROM chat_projects WHERE archived_at IS NULL ORDER BY name, id`)
	if err != nil {
		return nil, fmt.Errorf("reading the chat projects: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []ListProject{}
	for rows.Next() {
		var p ListProject
		if err := rows.Scan(&p.ID, &p.Name); err != nil {
			return nil, fmt.Errorf("reading the chat projects: %w", err)
		}
		p.Name, _ = clipText(p.Name, maxLabel)
		out = append(out, p)
	}
	return out, rows.Err()
}

var (
	mdLink       = regexp.MustCompile(`!?\[([^\]]*)\]\([^)]*\)`)
	mdLineMarker = regexp.MustCompile(`^\s*(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)`)
	mdInline     = strings.NewReplacer("**", "", "__", "", "~~", "", "`", "")
)

// chatPreview is ChatPanelRow.preview, lighter: the first line of markdown
// that has text once its block marker, links, emphasis and code ticks are
// dropped (a fence line has none), with whitespace runs as one space.
func chatPreview(markdown string) string {
	for _, line := range strings.Split(markdown, "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~") {
			continue
		}
		t = mdLineMarker.ReplaceAllString(t, "")
		t = mdLink.ReplaceAllString(t, "$1")
		t = strings.Join(strings.Fields(mdInline.Replace(t)), " ")
		if t != "" {
			return t
		}
	}
	return ""
}
