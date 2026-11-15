// Package chatstore is the Go twin of the Desktop's chat write path
// (ChatViewModel.persistTurnStart, ChatTreeQueries, ChatTurnDriver and
// ChatTurnStore): it starts a turn under the conversation's lease, folds the
// session's protocol-v2 events into chat_messages / chat_turn_steps /
// chat_artifacts exactly as the Mac does, and finalizes the turn. The shared
// fixture testdata/chat_turn_cases.json pins both sides (CHAT-01, CHAT-02,
// LIVE-01). It has no hub imports, so it is tested alone.
package chatstore

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"watchtower/internal/chat"
	"watchtower/internal/db"
)

// Start refusals. ErrBusy: another turn holds the conversation's lease;
// ErrConversationGone: the conversation does not exist (or was deleted
// during the turn); ErrNotFound: the message a regenerate, edit or branch
// select names is not in the conversation; ErrInvalid: the request breaks a
// rule the Mac's composer enforces; ErrAttachmentMissing: an attachment id
// is not a file of this conversation.
var (
	ErrBusy              = errors.New("chatstore: conversation busy")
	ErrConversationGone  = errors.New("chatstore: conversation gone")
	ErrNotFound          = errors.New("chatstore: message not found")
	ErrInvalid           = errors.New("chatstore: invalid request")
	ErrAttachmentMissing = errors.New("chatstore: attachment missing")
)

// Start modes.
const (
	ModeSend       = "send"
	ModeRegenerate = "regenerate"
	ModeEdit       = "edit"
)

// Store writes the hub's chat turns.
type Store struct {
	db        *db.DB
	owner     db.ChatLeaseOwner
	ownerID   string
	now       func() time.Time
	title     func(conv int64)
	preferred string

	mu     sync.Mutex
	titled map[int64]bool

	// failWrite, set by tests only, fails a turn write before it starts
	// (a lock held past busy_timeout, without waiting on the clock).
	failWrite func() error
}

// Option configures a Store.
type Option func(*Store)

// WithClock replaces time.Now (tests drive the flush cadence with it).
func WithClock(now func() time.Time) Option { return func(s *Store) { s.now = now } }

// WithTitleHook is called after a finalize that leaves the conversation with
// its first complete answer and a prefix title (Swift
// ChatConversationQueries.needsAITitle), at most once per conversation per
// Store, like the Mac's titleRequests. It runs on the finalizing goroutine
// after the commit, so it must not block (the hub starts chat.GenerateTitle
// in its own goroutine).
func WithTitleHook(fn func(conv int64)) Option { return func(s *Store) { s.title = fn } }

// WithPreferredProvider is the provider an automatic conversation's session
// config names (the Mac's preferred provider): only the empty reply added
// under a legacy unanswered owner question records it.
func WithPreferredProvider(p string) Option { return func(s *Store) { s.preferred = p } }

// New returns the store of one lease owner (the hub and its id).
func New(d *db.DB, owner db.ChatLeaseOwner, ownerID string, opts ...Option) *Store {
	s := &Store{db: d, owner: owner, ownerID: ownerID, now: time.Now, titled: map[int64]bool{}}
	for _, o := range opts {
		o(s)
	}
	return s
}

// Routing is a turn's provider choice: pinned (Provider, Model) or automatic.
type Routing struct {
	Automatic       bool
	Provider, Model string
}

// StartRequest is one turn to start.
type StartRequest struct {
	ConversationID int64
	Mode           string // send | regenerate | edit
	// MessageID: the assistant message to regenerate, or the owner message to edit.
	MessageID     int64
	Text          string
	AttachmentIDs []int64  // send only: the conversation's pending files
	TurnID        string   // "" = a new UUID
	Routing       *Routing // nil = keep the conversation's
	// ContinuousLeafID is the last message the live session answered (nil
	// for a new session): ChatContinuity decides Replay from it.
	ContinuousLeafID *int64
}

// Started is a turn whose rows are on disk.
type Started struct {
	ConversationID     int64
	UserMessageID      int64
	AssistantMessageID int64
	TurnID             string
	Replay             bool
	// SendText is the turn command's text: the actions-outcome block (a new
	// message only) and the owner's text. The stored row holds only the
	// owner's text.
	SendText    string
	Attachments []chat.Attachment
	Routing     Routing // the session config the turn runs with
	ProjectID   *int64  // the conversation's chat project at start
	// The prefix commands' results (send and edit only): the remember
	// outcome ("" = not a remember message), the chat-born idea written by a
	// knowledge prefix (0 = none) and the first failure of either.
	RememberOutcome string
	IdeaID          int64
	PrefixErr       error
}

type convRow struct {
	title, titleSource, routingMode string
	provider, model, contextType    sql.NullString
	projectID, leaf                 sql.NullInt64
}

type msgRow struct {
	id        int64
	parent    sql.NullInt64
	role      string
	text      string
	turnID    string
	createdAt float64
	errorCode sql.NullString
}

// Start writes a turn's starting rows in one BEGIN IMMEDIATE transaction
// (ChatViewModel.persistTurnStart): the lease claim first — refused, nothing
// is written —, then the owner row (regenerate reuses it), its attachments,
// the prefix title, the routing and the empty `partial` assistant row
// (CHAT-01). Every insert moves the active leaf and updated_at. The prefix
// commands run after the commit, for a new owner row only.
func (s *Store) Start(ctx context.Context, r StartRequest) (Started, error) {
	text := strings.TrimSpace(r.Text)
	if err := validateStart(r, text); err != nil {
		return Started{}, err
	}
	turnID := r.TurnID
	if turnID == "" {
		turnID = newTurnID()
	}
	now := s.now()
	st := Started{ConversationID: r.ConversationID, TurnID: turnID}
	// userText is the stored owner text (the composer's format); titleText
	// the prefix title's source: the owner's own words for a send, the
	// stored text for an edit (the Mac's titleText ?? userText).
	var userText, titleText string
	wroteUser := false

	tx, err := s.db.BeginTx(ctx, nil) // BEGIN IMMEDIATE (_txlock=immediate)
	if err != nil {
		return Started{}, fmt.Errorf("starting chat turn: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	conv, err := readConversationTx(tx, r.ConversationID)
	if err != nil {
		return Started{}, err
	}
	if conv == nil {
		return Started{}, ErrConversationGone
	}
	if conv.contextType.Valid {
		return Started{}, ErrInvalid // a Discuss chat: the embedded store's, not the main chat's
	}
	nowMS := now.UnixMilli()
	ok, err := db.ClaimChatLeaseTx(tx, db.ChatLease{ConversationID: r.ConversationID, Owner: s.owner, OwnerID: s.ownerID,
		TurnID: turnID, StartedAtMS: nowMS, HeartbeatAtMS: nowMS}, nowMS)
	if err != nil {
		return Started{}, err
	}
	if !ok {
		return Started{}, ErrBusy
	}
	routing := s.resolveRouting(conv, r.Routing)
	all, err := loadMessagesTx(tx, r.ConversationID)
	if err != nil {
		return Started{}, err
	}
	byID := make(map[int64]msgRow, len(all))
	for _, m := range all {
		byID[m.id] = m
	}
	createdAt := seconds(now)
	var historyTip *int64
	var outcomes string

	switch r.Mode {
	case ModeSend:
		path := activePath(all, conv.leaf)
		if len(path) > 0 {
			historyTip = &path[len(path)-1].id
		}
		// The floor is the previous owner message, and it alone.
		if floor, ok := lastOwnerCreatedAt(path); ok {
			outcomes, _ = outcomesBlockTx(tx, r.ConversationID, floor) // a failed read sends no block, as on the Mac
		}
		atts, err := pendingAttachmentsTx(tx, r.ConversationID, r.AttachmentIDs)
		if err != nil {
			return Started{}, err
		}
		st.Attachments = atts
		userText, titleText = composeOwnerText(r.Text), text
	case ModeRegenerate:
		m, ok := byID[r.MessageID]
		if !ok {
			return Started{}, ErrNotFound
		}
		owner, hasOwner := byID[m.parent.Int64]
		if m.role != "assistant" || !m.parent.Valid || !hasOwner || owner.role != "user" ||
			m.errorCode.String == codeQuotaExhausted {
			return Started{}, ErrInvalid
		}
		st.UserMessageID = owner.id
		historyTip = nullable(owner.parent)
		userText = owner.text
		if st.Attachments, err = messageAttachmentsTx(tx, owner.id); err != nil {
			return Started{}, err
		}
	case ModeEdit:
		m, ok := byID[r.MessageID]
		if !ok {
			return Started{}, ErrNotFound
		}
		if m.role != "user" {
			return Started{}, ErrInvalid
		}
		historyTip = nullable(m.parent)
		userText = recompose(m.text, r.Text) // keeps the original's skill and REFERENCED lines
		titleText = userText
		// The files are sent again; their rows stay on the original message (v1 limit).
		if st.Attachments, err = messageAttachmentsTx(tx, m.id); err != nil {
			return Started{}, err
		}
	}

	if r.Mode != ModeRegenerate {
		// A legacy owner question that never got a reply gets an empty
		// partial reply, so the new owner message never sits right under it.
		if historyTip != nil {
			if tip, ok := byID[*historyTip]; ok && tip.role == "user" {
				id, err := insertMessageTx(tx, newMessage{conv: r.ConversationID, parent: historyTip, role: "assistant",
					turnID: tip.turnID, status: "partial", provider: sql.NullString{String: routing.Provider, Valid: true},
					createdAt: createdAt})
				if err != nil {
					return Started{}, err
				}
				historyTip = &id
			}
		}
		id, err := insertMessageTx(tx, newMessage{conv: r.ConversationID, parent: historyTip, role: "user", text: userText,
			turnID: turnID, status: "complete", createdAt: createdAt})
		if err != nil {
			return Started{}, err
		}
		st.UserMessageID = id
		wroteUser = true
		// An edit's files stay linked to the original message (the Mac's
		// link of them is a no-op), so only a send links.
		if err := linkAttachmentsTx(tx, r.AttachmentIDs, id); err != nil {
			return Started{}, err
		}
		if err := setPrefixTitleTx(tx, r.ConversationID, titleText); err != nil {
			return Started{}, err
		}
	}
	if err := writeRoutingTx(tx, r.ConversationID, conv, r.Routing, routing); err != nil {
		return Started{}, err
	}
	provider, model := sql.NullString{String: "", Valid: true}, sql.NullString{}
	if !routing.Automatic {
		provider.String = routing.Provider
		model = sql.NullString{String: routing.Model, Valid: routing.Model != ""}
	}
	userID := st.UserMessageID
	asst, err := insertMessageTx(tx, newMessage{conv: r.ConversationID, parent: &userID, role: "assistant",
		turnID: turnID, status: "partial", provider: provider, model: model, createdAt: createdAt})
	if err != nil {
		return Started{}, err
	}
	if err := tx.Commit(); err != nil {
		return Started{}, fmt.Errorf("starting chat turn: %w", err)
	}

	st.AssistantMessageID = asst
	st.Routing = routing
	st.ProjectID = nullable(conv.projectID)
	st.Replay = r.Mode != ModeSend || !sameID(historyTip, r.ContinuousLeafID)
	st.SendText = composeTurnText(userText, outcomes)
	if wroteUser {
		// Remember and the knowledge prefixes get the owner's own words,
		// never the skill or REFERENCED lines.
		_, body, _ := displayParts(userText)
		s.runPrefixes(&st, body)
	}
	return st, nil
}

func validateStart(r StartRequest, text string) error {
	if r.ConversationID <= 0 {
		return ErrInvalid
	}
	switch r.Mode {
	case ModeSend:
		if text == "" && len(r.AttachmentIDs) == 0 {
			return ErrInvalid
		}
	case ModeRegenerate:
		if r.MessageID <= 0 || len(r.AttachmentIDs) > 0 {
			return ErrInvalid
		}
	case ModeEdit:
		if r.MessageID <= 0 || text == "" || len(r.AttachmentIDs) > 0 {
			return ErrInvalid
		}
	default:
		return ErrInvalid
	}
	if r.Routing != nil && !r.Routing.Automatic && !knownProvider(r.Routing.Provider) {
		return ErrInvalid
	}
	return nil
}

func knownProvider(p string) bool { return p == "claude" || p == "codex" || p == "ollama" }

// resolveRouting is the turn's session config: the request's choice, else
// the conversation's own (pinned provider and model, or automatic with the
// preferred provider), as the Mac's applyConversationSettings reads it.
func (s *Store) resolveRouting(conv *convRow, req *Routing) Routing {
	if req != nil {
		r := *req
		if r.Automatic {
			r.Provider, r.Model = s.preferred, ""
		}
		return r
	}
	if conv.routingMode == "pinned" {
		p := conv.provider.String
		if p == "" {
			p = s.preferred
		}
		return Routing{Provider: p, Model: conv.model.String}
	}
	return Routing{Automatic: true, Provider: s.preferred}
}

// writeRoutingTx records a pinned config on every turn, as persistTurnStart
// does (which also clears the sticky actual pair); an automatic config is
// written only when the request switches a pinned conversation to automatic
// (the Mac's picker write) — an ordinary automatic turn never resets the
// sticky metadata.
func writeRoutingTx(tx *sql.Tx, conv int64, row *convRow, req *Routing, r Routing) error {
	var res sql.Result
	var err error
	switch {
	case !r.Automatic:
		if !knownProvider(r.Provider) {
			return ErrInvalid
		}
		res, err = tx.Exec(`UPDATE chat_conversations SET routing_mode = 'pinned', provider = ?, model = ?,
			actual_provider = '', actual_model = '', routing_reason = '' WHERE id = ?`,
			r.Provider, sql.NullString{String: r.Model, Valid: r.Model != ""}, conv)
	case req != nil && row.routingMode == "pinned":
		res, err = tx.Exec(`UPDATE chat_conversations SET routing_mode = 'preferred_reserve', provider = NULL, model = NULL,
			actual_provider = '', actual_model = '', routing_reason = '' WHERE id = ?`, conv)
	default:
		return nil
	}
	if err != nil {
		return fmt.Errorf("setting chat routing: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrConversationGone
	}
	return nil
}

func readConversationTx(tx *sql.Tx, id int64) (*convRow, error) {
	var c convRow
	err := tx.QueryRow(`SELECT title, title_source, routing_mode, provider, model, context_type, project_id, active_leaf_message_id
		FROM chat_conversations WHERE id = ?`, id).
		Scan(&c.title, &c.titleSource, &c.routingMode, &c.provider, &c.model, &c.contextType, &c.projectID, &c.leaf)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil //nolint:nilnil // absent is a normal answer
	}
	if err != nil {
		return nil, fmt.Errorf("reading chat conversation %d: %w", id, err)
	}
	return &c, nil
}

func loadMessagesTx(tx *sql.Tx, conv int64) ([]msgRow, error) {
	rows, err := tx.Query(`SELECT id, parent_id, role, text, turn_id, created_at, error_code
		FROM chat_messages WHERE conversation_id = ? ORDER BY id`, conv)
	if err != nil {
		return nil, fmt.Errorf("reading chat messages of %d: %w", conv, err)
	}
	defer rows.Close()
	var out []msgRow
	for rows.Next() {
		var m msgRow
		if err := rows.Scan(&m.id, &m.parent, &m.role, &m.text, &m.turnID, &m.createdAt, &m.errorCode); err != nil {
			return nil, fmt.Errorf("reading chat messages of %d: %w", conv, err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// activePath is ChatTreeQueries.activePath: root → leaf along parent_id,
// or every message in id order when there is no leaf or it is not in the
// conversation.
func activePath(all []msgRow, leaf sql.NullInt64) []msgRow {
	if !leaf.Valid {
		return all
	}
	byID := make(map[int64]msgRow, len(all))
	for _, m := range all {
		byID[m.id] = m
	}
	var rev []msgRow
	seen := map[int64]bool{}
	cur, ok := byID[leaf.Int64]
	for ok && !seen[cur.id] {
		seen[cur.id] = true
		rev = append(rev, cur)
		if !cur.parent.Valid {
			break
		}
		cur, ok = byID[cur.parent.Int64]
	}
	if len(rev) == 0 {
		return all
	}
	out := make([]msgRow, len(rev))
	for i, m := range rev {
		out[len(rev)-1-i] = m
	}
	return out
}

func lastOwnerCreatedAt(path []msgRow) (float64, bool) {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i].role == "user" {
			return path[i].createdAt, true
		}
	}
	return 0, false
}

type newMessage struct {
	conv            int64
	parent          *int64
	role, text      string
	turnID, status  string
	provider, model sql.NullString
	createdAt       float64
}

// insertMessageTx is ChatTreeQueries.insert: the row, then the conversation's
// active leaf and updated_at.
func insertMessageTx(tx *sql.Tx, m newMessage) (int64, error) {
	res, err := tx.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at, turn_id, status, provider, model)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, m.conv, m.parent, m.role, m.text, m.createdAt, m.turnID, m.status, m.provider, m.model)
	if err != nil {
		return 0, fmt.Errorf("inserting chat message: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("inserting chat message: %w", err)
	}
	if _, err := tx.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ?, updated_at = ? WHERE id = ?`,
		id, m.createdAt, m.conv); err != nil {
		return 0, fmt.Errorf("moving the chat leaf: %w", err)
	}
	return id, nil
}

// setPrefixTitleTx is ChatConversationQueries.setPrefixTitle: the first 80
// characters, only while the conversation has no title of any source.
func setPrefixTitleTx(tx *sql.Tx, conv int64, text string) error {
	_, err := tx.Exec(`UPDATE chat_conversations SET title = ? WHERE id = ? AND title_source = 'prefix' AND title = ''`,
		prefixGraphemes(text, 80), conv)
	if err != nil {
		return fmt.Errorf("setting the prefix title: %w", err)
	}
	return nil
}

// pendingAttachmentsTx returns the requested files in request order; every
// id must be a pending (not yet linked) file of this conversation, as the
// Mac's composer only ever holds those.
func pendingAttachmentsTx(tx *sql.Tx, conv int64, ids []int64) ([]chat.Attachment, error) {
	out := make([]chat.Attachment, 0, len(ids))
	for _, id := range ids {
		var a chat.Attachment
		// A pending file of this conversation only: one already linked to
		// another message would be sent but never linked to this one.
		err := tx.QueryRow(`SELECT path, mime, name FROM chat_attachments WHERE id = ? AND conversation_id = ? AND message_id IS NULL`, id, conv).
			Scan(&a.Path, &a.Mime, &a.Name)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrAttachmentMissing
		}
		if err != nil {
			return nil, fmt.Errorf("reading chat attachment %d: %w", id, err)
		}
		out = append(out, a)
	}
	return out, nil
}

func messageAttachmentsTx(tx *sql.Tx, messageID int64) ([]chat.Attachment, error) {
	rows, err := tx.Query(`SELECT path, mime, name FROM chat_attachments WHERE message_id = ? ORDER BY id`, messageID)
	if err != nil {
		return nil, fmt.Errorf("reading message attachments: %w", err)
	}
	defer rows.Close()
	var out []chat.Attachment
	for rows.Next() {
		var a chat.Attachment
		if err := rows.Scan(&a.Path, &a.Mime, &a.Name); err != nil {
			return nil, fmt.Errorf("reading message attachments: %w", err)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// linkAttachmentsTx is ChatAttachmentQueries.link: pending rows only, never
// a row a previous link claimed.
func linkAttachmentsTx(tx *sql.Tx, ids []int64, messageID int64) error {
	for _, id := range ids {
		if _, err := tx.Exec(`UPDATE chat_attachments SET message_id = ? WHERE id = ? AND message_id IS NULL`, messageID, id); err != nil {
			return fmt.Errorf("linking chat attachment %d: %w", id, err)
		}
	}
	return nil
}

// composeTurnText is ChatTurnText.compose without a screen block.
func composeTurnText(userText, outcomes string) string {
	if outcomes == "" {
		return userText
	}
	return outcomes + "\n\n" + userText
}

// SelectBranch shows messageID's branch: the conversation's leaf moves to
// the newest leaf under it (ChatTreeQueries.selectSibling). Never refused
// during a turn (D17): a turn writes its rows by message id.
func (s *Store) SelectBranch(ctx context.Context, messageID int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("selecting chat branch: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var conv int64
	err = tx.QueryRow(`SELECT conversation_id FROM chat_messages WHERE id = ?`, messageID).Scan(&conv)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("selecting chat branch: %w", err)
	}
	all, err := loadMessagesTx(tx, conv)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`,
		newestLeaf(all, messageID), conv); err != nil {
		return fmt.Errorf("selecting chat branch: %w", err)
	}
	return tx.Commit()
}

// newestLeaf is ChatTree.newestLeaf: the largest id among the leaves of
// id's subtree (id itself when it has no children).
func newestLeaf(all []msgRow, id int64) int64 {
	children := map[int64][]int64{}
	for _, m := range all {
		if m.parent.Valid {
			children[m.parent.Int64] = append(children[m.parent.Int64], m.id)
		}
	}
	best := int64(-1)
	seen := map[int64]bool{}
	stack := []int64{id}
	for len(stack) > 0 {
		n := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[n] {
			continue
		}
		seen[n] = true
		if kids := children[n]; len(kids) > 0 {
			stack = append(stack, kids...)
		} else if n > best {
			best = n
		}
	}
	if best < 0 {
		return id
	}
	return best
}

// MarkRead is ChatConversationQueries.markRead: read_at becomes
// MAX(read_at, created_at of the last complete answer on the active branch),
// never backwards; updated_at is untouched; no complete answer = no change.
// A positive messageID bounds the answer to ids ≤ messageID (what the phone
// showed), so an answer that finished after it stays unread.
func (s *Store) MarkRead(ctx context.Context, conv, messageID int64) error {
	_, err := s.db.ExecContext(ctx, `WITH RECURSIVE path(message_id) AS (
			SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?1 AND active_leaf_message_id IS NOT NULL
			UNION
			SELECT m.parent_id FROM path JOIN chat_messages m ON m.id = path.message_id WHERE m.parent_id IS NOT NULL
		),
		answer(id) AS (
			SELECT CASE
				WHEN (SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?1) IS NULL THEN (
					SELECT MAX(m.id) FROM chat_messages m
					WHERE m.conversation_id = ?1 AND m.role = 'assistant' AND m.status = 'complete' AND (?2 <= 0 OR m.id <= ?2))
				ELSE (
					SELECT MAX(m.id) FROM path JOIN chat_messages m ON m.id = path.message_id AND m.conversation_id = ?1
					WHERE m.role = 'assistant' AND m.status = 'complete' AND (?2 <= 0 OR m.id <= ?2))
			END
		)
		UPDATE chat_conversations SET read_at = MAX(COALESCE(read_at, 0), (SELECT m.created_at FROM chat_messages m JOIN answer a ON m.id = a.id))
		WHERE id = ?1 AND (SELECT id FROM answer) IS NOT NULL`, conv, messageID)
	if err != nil {
		return fmt.Errorf("marking chat %d read: %w", conv, err)
	}
	return nil
}

func nullable(n sql.NullInt64) *int64 {
	if !n.Valid {
		return nil
	}
	v := n.Int64
	return &v
}

func sameID(a, b *int64) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

// seconds is a Swift Date's timeIntervalSince1970.
func seconds(t time.Time) float64 { return float64(t.UnixNano()) / 1e9 }

// newTurnID is a UUID string in Swift's UUID().uuidString form.
func newTurnID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}
