package sources

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"regexp"
	"slices"
	"strings"
	"time"

	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
	"watchtower/internal/providers"
)

// The chat_list caps (iPhone chat spec §4.6).
const (
	MaxChatListConversations = 200
	MaxChatLastLine          = 120
	// chatLeaseStale is the lease rule: a heartbeat older than this is dead
	// (spec §4.4).
	chatLeaseStale = 60 * time.Second
	// chatListReadFailed is the chat_list error when the read failed
	// ("Couldn't load chats" on the phone, mockup 1h).
	chatListReadFailed = "read_failed"
)

// The chat_list row states, by precedence (ChatPanelRowState).
const (
	ChatStateWaiting   = "waiting"
	ChatStateAnswering = "answering"
	ChatStateUnread    = "unread"
	ChatStateRead      = "read"
)

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

// ChatGrant says whether a linked phone holds the chat grant
// (state.Store.AnyChatPhone): every chat source publishes only then.
type ChatGrant func() (bool, error)

// ChatListOptions wires the chat_list source. Grant is required; Models nil
// is RegistryChatModels; Now nil is time.Now.
type ChatListOptions struct {
	Grant  ChatGrant
	Models func() []ChatModel
	Now    func() time.Time
}

// ChatListSource is the `chat_list` slice, one record `chat_list-main`: the
// main chat's conversations (up to 200, not archived; titles and project
// names clipped at 200 characters, within MaxChatFeedBytes), its projects
// and the composer's models (iPhone chat spec §4.6). It is rebuilt on every
// data_version change, not urgent, and published only while a phone holds
// the chat grant. A failed read publishes the list with `error` and nothing
// else, so the phone shows "Couldn't load chats" and Retry.
type ChatListSource struct {
	d *db.DB
	o ChatListOptions
}

// ChatListID is the chat_list record's id.
const ChatListID = "main"

// ChatList builds the chat_list source.
func ChatList(d *db.DB, o ChatListOptions) *ChatListSource {
	if o.Models == nil {
		o.Models = RegistryChatModels
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	return &ChatListSource{d: d, o: o}
}

// Kind is "chat_list".
func (s *ChatListSource) Kind() hubslices.Kind { return hubslices.KindChatList }

type chatListProject struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

type chatListConversation struct {
	ID         int64            `json:"id"`
	Title      string           `json:"title"`
	Pinned     bool             `json:"pinned"`
	UpdatedAt  wire.Time        `json:"updated_at"`
	Project    *chatListProject `json:"project,omitempty"`
	State      string           `json:"state"`
	LastLine   string           `json:"last_line"`
	LeaseOwner *string          `json:"lease_owner,omitempty"`
}

type chatListPayload struct {
	Conversations []chatListConversation `json:"conversations"`
	Projects      []chatListProject      `json:"projects"`
	Models        []ChatModel            `json:"models"`
	Error         *string                `json:"error,omitempty"`
}

// Items is the one chat_list record, or none without a chat phone.
func (s *ChatListSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	if ok, err := s.o.Grant(); err != nil || !ok {
		return nil, err
	}
	payload := chatListPayload{Conversations: []chatListConversation{}, Projects: []chatListProject{}, Models: s.o.Models()}
	if payload.Models == nil {
		payload.Models = []ChatModel{}
	}
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		var err error
		if payload.Conversations, err = chatListRows(ctx, tx, s.o.Now()); err != nil {
			return err
		}
		payload.Projects, err = chatListProjects(ctx, tx)
		return err
	})
	if err != nil {
		if ctx.Err() != nil {
			return nil, err
		}
		log.Printf("hub slices: reading the chat list failed (%s)", errClass(err))
		code := chatListReadFailed
		payload = chatListPayload{Conversations: []chatListConversation{}, Projects: []chatListProject{}, Models: []ChatModel{}, Error: &code}
	}
	b, err := encodeChatList(payload)
	if err != nil {
		return nil, fmt.Errorf("hub slices: encoding the chat list: %w", err)
	}
	return []hubslices.Item{{ID: ChatListID, Payload: b}}, nil
}

// encodeChatList encodes p within MaxChatFeedBytes, always: titles and
// names are already clipped at 200 and last lines at 120, so 200 rows fit;
// should they ever not, the oldest conversations (the list's tail) go.
func encodeChatList(p chatListPayload) ([]byte, error) {
	for {
		b, err := wire.Marshal(p)
		if err != nil || len(b) <= MaxChatFeedBytes || len(p.Conversations) == 0 {
			return b, err
		}
		p.Conversations = p.Conversations[:len(p.Conversations)-1]
	}
}

// chatListRows is the Chats panel's read (ChatHistoryQueries.panelRows)
// for the phone: the main chat's conversations, not archived, pinned first
// then newest, at most 200, each with its state and its last answer's first
// line. The last answer is the newest complete assistant message on the
// active branch (every message when there is no leaf). waiting = any
// pending agent_actions row of the conversation (panelRows'
// pending_approvals > 0); answering = a lease with a heartbeat in the last
// 60 s.
func chatListRows(ctx context.Context, tx *sql.Tx, now time.Time) ([]chatListConversation, error) {
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
       EXISTS (SELECT 1 FROM agent_actions x
               WHERE x.conversation_id = c.id AND x.status = 'pending'),
       l.owner, l.heartbeat_at_ms
FROM listed c
LEFT JOIN chat_projects p ON p.id = c.project_id
LEFT JOIN last_answer la ON la.conversation_id = c.id
LEFT JOIN chat_messages answer ON answer.id = la.message_id
LEFT JOIN chat_turn_leases l ON l.conversation_id = c.id
ORDER BY c.pinned DESC, c.updated_at DESC, c.id DESC`, MaxChatListConversations)
	if err != nil {
		return nil, fmt.Errorf("reading the chat list: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []chatListConversation{}
	for rows.Next() {
		var (
			c          chatListConversation
			updated    float64
			projectID  sql.NullInt64
			project    sql.NullString
			readAt     sql.NullFloat64
			answeredAt sql.NullFloat64
			answer     sql.NullString
			waiting    bool
			owner      sql.NullString
			heartbeat  sql.NullInt64
		)
		if err := rows.Scan(&c.ID, &c.Title, &c.Pinned, &updated, &projectID, &project, &readAt,
			&answeredAt, &answer, &waiting, &owner, &heartbeat); err != nil {
			return nil, fmt.Errorf("reading the chat list: %w", err)
		}
		c.Title, _ = clipText(c.Title, maxChatLabel)
		c.UpdatedAt = secondsTime(updated)
		if projectID.Valid {
			name, _ := clipText(project.String, maxChatLabel)
			c.Project = &chatListProject{ID: projectID.Int64, Name: name}
		}
		live := owner.Valid && liveLease(heartbeat.Int64, now)
		if live {
			o := owner.String
			c.LeaseOwner = &o
		}
		unread := answeredAt.Valid && (!readAt.Valid || answeredAt.Float64 > readAt.Float64)
		c.State = chatRowState(waiting, live, unread)
		c.LastLine, _ = clipText(chatPreview(answer.String), MaxChatLastLine)
		out = append(out, c)
	}
	return out, rows.Err()
}

// chatRowState is ChatPanelRowState's precedence: waiting > answering >
// unread > read.
func chatRowState(waiting, answering, unread bool) string {
	switch {
	case waiting:
		return ChatStateWaiting
	case answering:
		return ChatStateAnswering
	case unread:
		return ChatStateUnread
	}
	return ChatStateRead
}

// liveLease: a heartbeat at heartbeatMS (Unix ms) is less than 60 s old.
func liveLease(heartbeatMS int64, now time.Time) bool {
	return now.UnixMilli()-heartbeatMS < chatLeaseStale.Milliseconds()
}

// chatListProjects is the chat projects that are not archived, by name.
func chatListProjects(ctx context.Context, tx *sql.Tx) ([]chatListProject, error) {
	rows, err := tx.QueryContext(ctx, `SELECT id, name FROM chat_projects WHERE archived_at IS NULL ORDER BY name, id`)
	if err != nil {
		return nil, fmt.Errorf("reading the chat projects: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []chatListProject{}
	for rows.Next() {
		var p chatListProject
		if err := rows.Scan(&p.ID, &p.Name); err != nil {
			return nil, fmt.Errorf("reading the chat projects: %w", err)
		}
		p.Name, _ = clipText(p.Name, maxChatLabel)
		out = append(out, p)
	}
	return out, rows.Err()
}

// secondsTime is a REAL Unix-seconds column as a wire time.
func secondsTime(sec float64) wire.Time {
	whole := int64(sec)
	return wire.Time{Time: time.Unix(whole, int64((sec-float64(whole))*1e9)).UTC()}
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
