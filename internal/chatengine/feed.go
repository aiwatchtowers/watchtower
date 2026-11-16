package chatengine

// The feed: a conversation's last PageSize active-branch messages, the
// latest version of each artifact and the actions of those turns (iPhone
// chat spec §4.6), read in one snapshot, with a running engine turn's live
// text and steps over the last flush. The hub fits it to its record caps.

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/rivo/uniseg"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
	"watchtower/internal/tools"
	"watchtower/internal/wiretime"
)

// The feed's caps (iPhone chat spec §4.6).
const (
	MaxMessageText     = 40_000
	maxActionArgsBytes = 4000
	// maxLabel caps titles, names and error messages (SliceClip's 200).
	maxLabel = 200
)

// LiveTurn is a running engine turn as a reader overlays it: its text and
// steps so far and whether it waits for a free session slot.
type LiveTurn struct {
	TurnID      string
	Text        string
	Steps       []chatstore.Step
	WaitingSlot bool
}

// LiveRouting is the routing a conversation's live session reported in its
// session_ready (the row `ai session` writes beside it may lag).
type LiveRouting struct {
	Mode            string // the session's routing mode ("pinned", …)
	Provider, Model string // the actual pair
}

// Overlay is the live state a feed read shows over the database: the
// engine's running turn and its session's routing. nil = none.
type Overlay interface {
	LiveTurn(conv int64) (LiveTurn, bool)
	LiveRouting(conv int64) (LiveRouting, bool)
}

// ReadFeed reads conv's feed: before 0 is the latest page with the
// conversation's meta, artifacts and actions; before > 0 the PageSize
// messages before that message (only Messages and HasMore; a message no
// longer on the active branch gives an empty page).
// chatstore.ErrConversationGone when conv is gone or not a main chat.
func ReadFeed(ctx context.Context, d *db.DB, conv, before int64, now time.Time, live Overlay) (Feed, error) {
	var out Feed
	err := readTx(ctx, d, func(tx *sql.Tx) error {
		meta, leaf, ok, err := chatFeedConversationTx(ctx, tx, conv, now)
		if err != nil {
			return err
		}
		if !ok {
			return chatstore.ErrConversationGone
		}
		path, err := chatBranchTx(ctx, tx, conv, leaf)
		if err != nil {
			return err
		}
		if before > 0 {
			out.Messages = []FeedMessage{}
			if at := slices.IndexFunc(path.nodes, func(n chatNode) bool { return n.id == before }); at > 0 {
				window := path.nodes[max(at-PageSize, 0):at]
				if out.Messages, err = chatFeedMessagesTx(ctx, tx, path, window); err != nil {
					return err
				}
				pageActions, err := chatFeedActionsTx(ctx, tx, conv, window)
				if err != nil {
					return err
				}
				fillParts(out.Messages, FeedConversation{LiveSlackSince: meta.LiveSlackSince}, pageActions)
				out.HasMore = at > PageSize
			}
			return nil
		}
		window := path.nodes[max(len(path.nodes)-PageSize, 0):]
		msgs, err := chatFeedMessagesTx(ctx, tx, path, window)
		if err != nil {
			return err
		}
		if live != nil {
			if t, ok := live.LiveTurn(conv); ok {
				if meta.Lease != nil && meta.Lease.TurnID == t.TurnID {
					meta.Lease.WaitingSlot = t.WaitingSlot
				}
				applyLiveText(msgs, t.TurnID, t.Text, t.Steps)
			}
			if r, ok := live.LiveRouting(conv); ok {
				applyLiveRouting(&meta, r)
			}
		}
		artifacts, err := chatFeedArtifactsTx(ctx, tx, conv)
		if err != nil {
			return err
		}
		actions, err := chatFeedActionsTx(ctx, tx, conv, window)
		if err != nil {
			return err
		}
		fillParts(msgs, meta, actions)
		out = Feed{Conversation: meta, Messages: msgs, HasMore: len(window) < len(path.nodes), Artifacts: artifacts, Actions: actions}
		return nil
	})
	return out, err
}

// fillParts builds every message's parts, last, so the live text and
// routing are in.
func fillParts(msgs []FeedMessage, conv FeedConversation, actions []FeedAction) {
	for i := range msgs {
		msgs[i].liveSince = conv.LiveSlackSince
		msgs[i].Parts = BuildParts(msgs[i], conv, actions)
	}
}

// applyLiveRouting puts a live session's reported routing on the meta.
func applyLiveRouting(c *FeedConversation, r LiveRouting) {
	if r.Mode != "" {
		c.Routing = FeedRouting{Mode: "auto"}
		if r.Mode == "pinned" {
			c.Routing.Mode = "pinned"
			if r.Provider != "" {
				p := r.Provider
				c.Routing.Provider = &p
			}
			if r.Model != "" {
				m := r.Model
				c.Routing.Model = &m
			}
		}
	}
	if r.Provider != "" {
		c.ActualProvider, c.ActualModel = r.Provider, r.Model
	}
}

// TurnID is the turn the message belongs to (not on the wire: the hub's
// cap drops the actions of the turns it cut).
func (m FeedMessage) TurnID() string { return m.turnID }

// TurnID is the turn the action belongs to.
func (a FeedAction) TurnID() string { return a.turnID }

// readTx runs fn in one read-only transaction, so a read sees one snapshot
// and never blocks a writer.
func readTx(ctx context.Context, d *db.DB, fn func(*sql.Tx) error) error {
	tx, err := d.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return fmt.Errorf("chatengine: opening a read: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	return fn(tx)
}

// inList is "?,?,…" and its arguments for ids.
func inList(ids []int64) (string, []any) {
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return strings.TrimSuffix(strings.Repeat("?,", len(ids)), ","), args
}

func int64Ptr(v int64) *int64 { return &v }

// clipText is SliceClip.text: value cut to at most limit grapheme clusters,
// the ellipsis included, and a true flag (nil when not clipped).
func clipText(value string, limit int) (string, *bool) {
	if uniseg.GraphemeClusterCount(value) <= limit {
		return value, nil
	}
	clipped := true
	if limit <= 0 {
		return "", &clipped
	}
	var b strings.Builder
	g := uniseg.NewGraphemes(value)
	for n := 0; n < limit-1 && g.Next(); n++ {
		b.WriteString(g.Str())
	}
	b.WriteString("…")
	return b.String(), &clipped
}

// secondsTime is a REAL Unix-seconds column as a wire time.
func secondsTime(sec float64) wiretime.Time {
	whole := int64(sec)
	return wiretime.Time{Time: time.Unix(whole, int64((sec-float64(whole))*1e9)).UTC()}
}

type FeedRouting struct {
	Mode     string  `json:"mode"`
	Provider *string `json:"provider,omitempty"`
	Model    *string `json:"model,omitempty"`
}

type FeedLease struct {
	Owner       string `json:"owner"`
	TurnID      string `json:"turn_id"`
	WaitingSlot bool   `json:"waiting_slot"`
}

type FeedConversation struct {
	ID             int64        `json:"id"`
	Title          string       `json:"title"`
	Project        *ListProject `json:"project,omitempty"`
	Routing        FeedRouting  `json:"routing"`
	ActualProvider string       `json:"actual_provider"`
	ActualModel    string       `json:"actual_model"`
	LiveSlackSince *int64       `json:"live_slack_since,omitempty"`
	Lease          *FeedLease   `json:"lease,omitempty"`
}

type FeedSiblings struct {
	Index int `json:"index"`
	Count int `json:"count"`
	// IDs are the siblings' message ids in order, only when there is more
	// than one: the phone's ‹ i/n › names the sibling it selects
	// (chat_branch_select).
	IDs []int64 `json:"ids,omitempty"`
}

type FeedAttachment struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
	Mime string `json:"mime"`
	Size int64  `json:"size"`
}

type FeedStep struct {
	Name    string        `json:"name"`
	OK      *bool         `json:"ok,omitempty"`
	Summary string        `json:"summary"`
	Sources []chat.Source `json:"sources"`
}

type FeedMessage struct {
	ID           int64            `json:"id"`
	Role         string           `json:"role"`
	Text         string           `json:"text"`
	TextCut      bool             `json:"text_cut"`
	Status       string           `json:"status"`
	ErrorCode    *string          `json:"error_code,omitempty"`
	ErrorMessage *string          `json:"error_message,omitempty"`
	CreatedAt    wiretime.Time    `json:"created_at"`
	Siblings     FeedSiblings     `json:"siblings"`
	Attachments  []FeedAttachment `json:"attachments"`
	Steps        []FeedStep       `json:"steps"`
	// Parts are the typed pieces with their fallbacks (BuildParts); the flat
	// fields above stay for a client one version behind.
	Parts []Part `json:"parts"`

	turnID string
	// liveSince is the conversation's live_slack_since, kept so a refit
	// after a record cut builds the marks the same way.
	liveSince *int64
}

type FeedArtifact struct {
	Key        string  `json:"key"`
	Kind       string  `json:"kind"`
	Title      string  `json:"title"`
	Version    int     `json:"version"`
	Content    *string `json:"content,omitempty"`
	ContentCut bool    `json:"content_cut"`
}

type FeedAction struct {
	ID          int64   `json:"id"`
	Tool        string  `json:"tool"`
	Title       string  `json:"title"`
	ArgsDisplay string  `json:"args_display"`
	ArgsSHA256  string  `json:"args_sha256"`
	Status      string  `json:"status"`
	Reason      *string `json:"reason,omitempty"`

	turnID string
}

type Feed struct {
	Conversation FeedConversation `json:"conversation"`
	Messages     []FeedMessage    `json:"messages"`
	HasMore      bool             `json:"has_more"`
	Artifacts    []FeedArtifact   `json:"artifacts"`
	Actions      []FeedAction     `json:"actions"`
}

// chatFeedConversationTx is the feed's conversation meta and its leaf; ok
// is false when the conversation is gone or is not a main chat (spec §1). The lease is shown only while
// its heartbeat is less than 60 s old.
func chatFeedConversationTx(ctx context.Context, tx *sql.Tx, conv int64, now time.Time) (FeedConversation, sql.NullInt64, bool, error) {
	var (
		c                       FeedConversation
		leaf, projectID, slack  sql.NullInt64
		project, provider, mdl  sql.NullString
		mode                    string
		leaseOwner, leaseTurnID sql.NullString
		heartbeat               sql.NullInt64
	)
	err := tx.QueryRowContext(ctx, `
SELECT c.id, c.title, c.active_leaf_message_id, c.project_id, p.name, c.routing_mode, c.provider, c.model,
       c.actual_provider, c.actual_model, c.live_slack_since, l.owner, l.turn_id, l.heartbeat_at_ms
FROM chat_conversations c
LEFT JOIN chat_projects p ON p.id = c.project_id
LEFT JOIN chat_turn_leases l ON l.conversation_id = c.id
WHERE c.id = ? AND c.context_type IS NULL`, conv).Scan(&c.ID, &c.Title, &leaf, &projectID, &project, &mode, &provider, &mdl,
		&c.ActualProvider, &c.ActualModel, &slack, &leaseOwner, &leaseTurnID, &heartbeat)
	if errors.Is(err, sql.ErrNoRows) {
		return c, leaf, false, nil
	}
	if err != nil {
		return c, leaf, false, fmt.Errorf("reading a chat conversation: %w", err)
	}
	if projectID.Valid {
		c.Project = &ListProject{ID: projectID.Int64, Name: project.String}
	}
	c.Routing = FeedRouting{Mode: "auto"}
	if mode == "pinned" {
		c.Routing.Mode = "pinned"
	}
	if provider.String != "" {
		c.Routing.Provider = &provider.String
	}
	if mdl.String != "" {
		c.Routing.Model = &mdl.String
	}
	if slack.Valid {
		c.LiveSlackSince = int64Ptr(slack.Int64)
	}
	if leaseOwner.Valid && liveLease(heartbeat.Int64, now) {
		c.Lease = &FeedLease{Owner: leaseOwner.String, TurnID: leaseTurnID.String}
	}
	return c, leaf, true, nil
}

// chatNode is one message of a conversation's tree, without its text.
type chatNode struct {
	id     int64
	parent sql.NullInt64
}

// chatBranch is a conversation's active branch, root first, and each
// message's siblings (ChatTreeQueries.thread): without a leaf every message
// in id order and no branches.
type chatBranch struct {
	nodes    []chatNode
	siblings map[int64]FeedSiblings
}

// chatBranchTx reads conv's tree and resolves its active branch
// (ChatTreeQueries.activePath + ChatTree.siblings, 1-based index).
func chatBranchTx(ctx context.Context, tx *sql.Tx, conv int64, leaf sql.NullInt64) (chatBranch, error) {
	rows, err := tx.QueryContext(ctx, `SELECT id, parent_id FROM chat_messages WHERE conversation_id = ? ORDER BY id`, conv)
	if err != nil {
		return chatBranch{}, fmt.Errorf("reading a chat tree: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var all []chatNode
	for rows.Next() {
		var n chatNode
		if err := rows.Scan(&n.id, &n.parent); err != nil {
			return chatBranch{}, fmt.Errorf("reading a chat tree: %w", err)
		}
		all = append(all, n)
	}
	if err := rows.Err(); err != nil {
		return chatBranch{}, fmt.Errorf("reading a chat tree: %w", err)
	}
	b := chatBranch{siblings: map[int64]FeedSiblings{}}
	byID := make(map[int64]chatNode, len(all))
	children := map[int64][]int64{}
	var roots []int64
	for _, n := range all {
		byID[n.id] = n
		if n.parent.Valid {
			children[n.parent.Int64] = append(children[n.parent.Int64], n.id)
		} else {
			roots = append(roots, n.id)
		}
	}
	if _, ok := byID[leaf.Int64]; !leaf.Valid || !ok {
		b.nodes = all
		for _, n := range all {
			b.siblings[n.id] = FeedSiblings{Index: 1, Count: 1}
		}
		return b, nil
	}
	seen := map[int64]bool{}
	for cur, ok := byID[leaf.Int64]; ok && !seen[cur.id]; {
		seen[cur.id] = true
		b.nodes = append(b.nodes, cur)
		if !cur.parent.Valid {
			break
		}
		cur, ok = byID[cur.parent.Int64]
	}
	slices.Reverse(b.nodes)
	for _, n := range b.nodes {
		sibs := roots
		if n.parent.Valid {
			sibs = children[n.parent.Int64]
		}
		if len(sibs) == 0 {
			sibs = []int64{n.id}
		}
		sib := FeedSiblings{Index: max(slices.Index(sibs, n.id), 0) + 1, Count: len(sibs)}
		if len(sibs) > 1 {
			sib.IDs = slices.Clone(sibs)
		}
		b.siblings[n.id] = sib
	}
	return b, nil
}

// chatFeedMessagesTx reads window's messages with their attachments and
// steps; every text is cut at MaxMessageText.
func chatFeedMessagesTx(ctx context.Context, tx *sql.Tx, b chatBranch, window []chatNode) ([]FeedMessage, error) {
	out := []FeedMessage{}
	if len(window) == 0 {
		return out, nil
	}
	ids := make([]int64, len(window))
	for i, n := range window {
		ids[i] = n.id
	}
	in, args := inList(ids)
	byID, err := chatFeedMessageRowsTx(ctx, tx, b, in, args)
	if err != nil {
		return nil, err
	}
	if err := chatFeedAttachmentsTx(ctx, tx, in, args, byID); err != nil {
		return nil, err
	}
	if err := chatFeedStepsTx(ctx, tx, in, args, byID); err != nil {
		return nil, err
	}
	for _, id := range ids {
		if m, ok := byID[id]; ok {
			out = append(out, *m)
		}
	}
	return out, nil
}

// chatFeedMessageRowsTx reads the messages of ids (in, args) by id, their
// attachments and steps still empty.
func chatFeedMessageRowsTx(ctx context.Context, tx *sql.Tx, b chatBranch, in string, args []any) (map[int64]*FeedMessage, error) {
	//nolint:gosec // G202: in is "?,?,…" placeholders only
	rows, err := tx.QueryContext(ctx, `SELECT id, role, text, status, error_code, error_message, created_at, turn_id
		FROM chat_messages WHERE id IN (`+in+`) ORDER BY id`, args...)
	if err != nil {
		return nil, fmt.Errorf("reading chat messages: %w", err)
	}
	defer func() { _ = rows.Close() }()
	byID := map[int64]*FeedMessage{}
	for rows.Next() {
		var (
			m             FeedMessage
			text          string
			code, message sql.NullString
			created       float64
		)
		if err := rows.Scan(&m.ID, &m.Role, &text, &m.Status, &code, &message, &created, &m.turnID); err != nil {
			return nil, fmt.Errorf("reading chat messages: %w", err)
		}
		m.setText(text)
		if code.String != "" {
			m.ErrorCode = &code.String
		}
		if message.String != "" {
			msg, _ := clipText(message.String, maxLabel)
			m.ErrorMessage = &msg
		}
		m.CreatedAt = secondsTime(created)
		m.Siblings = b.siblings[m.ID]
		m.Attachments, m.Steps = []FeedAttachment{}, []FeedStep{}
		byID[m.ID] = &m
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading chat messages: %w", err)
	}
	return byID, nil
}

func (m *FeedMessage) setText(text string) {
	cut, clipped := clipText(text, MaxMessageText)
	m.Text, m.TextCut = cut, clipped != nil
}

func chatFeedAttachmentsTx(ctx context.Context, tx *sql.Tx, in string, args []any, byID map[int64]*FeedMessage) error {
	//nolint:gosec // G202: in is "?,?,…" placeholders only
	rows, err := tx.QueryContext(ctx, `SELECT id, message_id, name, mime, size FROM chat_attachments
		WHERE message_id IN (`+in+`) ORDER BY id`, args...)
	if err != nil {
		return fmt.Errorf("reading chat attachments: %w", err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var a FeedAttachment
		var msg int64
		if err := rows.Scan(&a.ID, &msg, &a.Name, &a.Mime, &a.Size); err != nil {
			return fmt.Errorf("reading chat attachments: %w", err)
		}
		a.Name, _ = clipText(a.Name, maxLabel)
		if m := byID[msg]; m != nil {
			m.Attachments = append(m.Attachments, a)
		}
	}
	return rows.Err()
}

func chatFeedStepsTx(ctx context.Context, tx *sql.Tx, in string, args []any, byID map[int64]*FeedMessage) error {
	//nolint:gosec // G202: in is "?,?,…" placeholders only
	rows, err := tx.QueryContext(ctx, `SELECT message_id, name, ok, summary, sources_json FROM chat_turn_steps
		WHERE message_id IN (`+in+`) ORDER BY message_id, seq, id`, args...)
	if err != nil {
		return fmt.Errorf("reading chat steps: %w", err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var (
			msg     int64
			s       FeedStep
			ok      sql.NullBool
			sources string
		)
		if err := rows.Scan(&msg, &s.Name, &ok, &s.Summary, &sources); err != nil {
			return fmt.Errorf("reading chat steps: %w", err)
		}
		if ok.Valid {
			s.OK = &ok.Bool
		}
		if json.Unmarshal([]byte(sources), &s.Sources) != nil || s.Sources == nil {
			s.Sources = []chat.Source{}
		}
		if m := byID[msg]; m != nil {
			m.Steps = append(m.Steps, s)
		}
	}
	return rows.Err()
}

// applyLiveText puts a hub-run turn's live text and steps on its assistant
// message.
func applyLiveText(msgs []FeedMessage, turnID, text string, steps []chatstore.Step) {
	for i := range msgs {
		m := &msgs[i]
		if m.Role != "assistant" || m.turnID != turnID {
			continue
		}
		m.setText(text)
		m.Steps = make([]FeedStep, 0, len(steps))
		for _, st := range steps {
			s := FeedStep{Name: st.Name, Summary: st.Summary, Sources: st.Sources}
			switch st.State {
			case chatstore.StepSucceeded:
				s.OK = boolPtr(true)
			case chatstore.StepFailed:
				s.OK = boolPtr(false)
			case chatstore.StepRunning, chatstore.StepWaiting:
			}
			if s.Sources == nil {
				s.Sources = []chat.Source{}
			}
			m.Steps = append(m.Steps, s)
		}
	}
}

func boolPtr(v bool) *bool { return &v }

// chatFeedArtifactsTx is the latest version of each artifact key of conv,
// in creation order; titles clipped at maxLabel graphemes, a key over it
// left out.
func chatFeedArtifactsTx(ctx context.Context, tx *sql.Tx, conv int64) ([]FeedArtifact, error) {
	rows, err := tx.QueryContext(ctx, `SELECT a.artifact_key, a.kind, a.title, a.version, a.content FROM chat_artifacts a
		WHERE a.conversation_id = ? AND a.version = (SELECT MAX(b.version) FROM chat_artifacts b
			WHERE b.conversation_id = a.conversation_id AND b.artifact_key = a.artifact_key)
		ORDER BY a.id`, conv)
	if err != nil {
		return nil, fmt.Errorf("reading chat artifacts: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []FeedArtifact{}
	for rows.Next() {
		var a FeedArtifact
		var content string
		if err := rows.Scan(&a.Key, &a.Kind, &a.Title, &a.Version, &content); err != nil {
			return nil, fmt.Errorf("reading chat artifacts: %w", err)
		}
		// The labels the cap's cuts never shrink are bounded here, so one
		// oversized value cannot keep the record over MaxChatFeedBytes. The
		// key stays exact (the phone finds an artifact by its fence's key):
		// a row whose key is over maxLabel is left out, and the phone
		// shows the fence's draft.
		if uniseg.GraphemeClusterCount(a.Key) > maxLabel {
			continue
		}
		a.Title, _ = clipText(a.Title, maxLabel)
		a.Content = &content
		out = append(out, a)
	}
	return out, rows.Err()
}

// chatFeedActionsTx is the agent_actions of window's turns, oldest first:
// the pending ones the phone may answer and the decided ones it shows.
func chatFeedActionsTx(ctx context.Context, tx *sql.Tx, conv int64, window []chatNode) ([]FeedAction, error) {
	out := []FeedAction{}
	if len(window) == 0 {
		return out, nil
	}
	ids := make([]int64, len(window))
	for i, n := range window {
		ids[i] = n.id
	}
	in, args := inList(ids)
	//nolint:gosec // G202: in is "?,?,…" placeholders only
	rows, err := tx.QueryContext(ctx, `SELECT id, tool, args_json, status, reason, turn_id FROM agent_actions
		WHERE conversation_id = ? AND turn_id <> ''
		  AND turn_id IN (SELECT turn_id FROM chat_messages WHERE id IN (`+in+`))
		ORDER BY id`, append([]any{conv}, args...)...)
	if err != nil {
		return nil, fmt.Errorf("reading chat actions: %w", err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var a FeedAction
		var argsJSON, reason string
		if err := rows.Scan(&a.ID, &a.Tool, &argsJSON, &a.Status, &reason, &a.turnID); err != nil {
			return nil, fmt.Errorf("reading chat actions: %w", err)
		}
		a.Title = actionTitle(a.Tool)
		a.ArgsDisplay = argsDisplay(argsJSON)
		a.ArgsSHA256 = tools.ArgsSHA256(argsJSON)
		if reason != "" {
			a.Reason = &reason
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// actionTitle is a tool's name in words: "create_jira_issue" → "Create jira
// issue".
func actionTitle(tool string) string {
	s := strings.Join(strings.Fields(strings.ReplaceAll(tool, "_", " ")), " ")
	if s == "" {
		return "Action"
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

// argsDisplay is an action's args as the phone shows them: indented JSON
// (the stored text when it is not JSON), cut at 4000 characters. The
// approval hash is over the stored bytes, never this text.
func argsDisplay(argsJSON string) string {
	var buf bytes.Buffer
	text := argsJSON
	if json.Indent(&buf, []byte(argsJSON), "", "  ") == nil {
		text = buf.String()
	}
	out, _ := clipText(text, maxActionArgsBytes)
	return out
}
