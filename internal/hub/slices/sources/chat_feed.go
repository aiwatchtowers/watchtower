package sources

import (
	"bytes"
	"cmp"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rivo/uniseg"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
	"watchtower/internal/tools"
)

// The chat_feed, chat_page and chat_search caps (iPhone chat spec §4.6).
const (
	MaxChatFeedBytes       = 600_000
	MaxChatFeedMessages    = 60
	MaxChatMessageText     = 40_000
	MaxChatSearchHits      = 50
	MaxChatSearchSnippet   = 200
	maxChatActionArgsBytes = 4000
)

// LiveText is the hub runner's memory of the turn it runs
// (chatrun.Runner.Live): the assistant text and steps so far and whether
// the turn waits for a free session slot; ok is false when the runner runs
// no turn of conv. A hub-run turn's feed shows it instead of the last
// flush in the database.
type LiveText interface {
	Live(conv int64) (text string, steps []chatstore.Step, waitingSlot bool, ok bool)
}

// ChatFeedOptions wires the chat_feed, chat_page and chat_search sources.
// Watches and Grant are required; Live nil is no hub runner; Now nil is
// time.Now and must be the clock the handlers stamp the requests with.
type ChatFeedOptions struct {
	Watches *ChatWatches
	Grant   ChatGrant
	Live    LiveText
	Now     func() time.Time
}

func (o *ChatFeedOptions) fill() {
	if o.Now == nil {
		o.Now = time.Now
	}
}

// granted is the chat sources' gate: without a phone holding the chat
// grant every watch, page and search is dropped (the publisher deletes
// their records), so a phone granted later never sees an old request.
func (o *ChatFeedOptions) granted() (bool, error) {
	ok, err := o.Grant()
	if err != nil {
		return false, err
	}
	if !ok {
		o.Watches.DropAll()
	}
	return ok, nil
}

// ChatFeedSource is the `chat_feed` slice, record `chat_feed-<conversation
// id>`: the watched conversations' last 60 active-branch messages, the
// latest version of each artifact and the actions of those turns, capped at
// 600 000 bytes (iPhone chat spec §4.6). A feed is published while its
// watch lasts (open: 5 min, repeated by the phone; prefetch: 2 min) and is
// read anew on every data_version change; a hub-run turn's text and steps
// come from the runner's memory (LiveText). Urgent.
type ChatFeedSource struct {
	d *db.DB
	o ChatFeedOptions
}

// ChatFeed builds the chat_feed source.
func ChatFeed(d *db.DB, o ChatFeedOptions) *ChatFeedSource {
	o.fill()
	return &ChatFeedSource{d: d, o: o}
}

// Kind is "chat_feed".
func (s *ChatFeedSource) Kind() hubslices.Kind { return hubslices.KindChatFeed }

// Items is one record per watched conversation that still exists.
func (s *ChatFeedSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	if ok, err := s.o.granted(); err != nil || !ok {
		return nil, err
	}
	var items []hubslices.Item
	for _, conv := range s.o.Watches.activeFeeds(s.o.Now()) {
		b, ok, err := s.feed(ctx, conv)
		if err != nil {
			return nil, err
		}
		if ok {
			items = append(items, hubslices.Item{ID: strconv.FormatInt(conv, 10), Payload: b})
		}
	}
	return items, nil
}

// feed is one conversation's payload; ok is false when it is gone.
func (s *ChatFeedSource) feed(ctx context.Context, conv int64) ([]byte, bool, error) {
	var out []byte
	found := false
	now := s.o.Now()
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		meta, leaf, ok, err := chatFeedConversationTx(ctx, tx, conv, now)
		if err != nil || !ok {
			return err
		}
		found = true
		path, err := chatBranchTx(ctx, tx, conv, leaf)
		if err != nil {
			return err
		}
		window := path.nodes[max(len(path.nodes)-MaxChatFeedMessages, 0):]
		msgs, err := chatFeedMessagesTx(ctx, tx, path, window)
		if err != nil {
			return err
		}
		if meta.Lease != nil && meta.Lease.Owner == string(db.ChatLeaseHub) && s.o.Live != nil {
			if text, steps, waiting, ok := s.o.Live.Live(conv); ok {
				meta.Lease.WaitingSlot = waiting
				applyLiveText(msgs, meta.Lease.TurnID, text, steps)
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
		out, err = encodeChatFeed(chatFeedPayload{
			Conversation: meta, Messages: msgs, HasMore: len(window) < len(path.nodes), Artifacts: artifacts, Actions: actions,
		})
		return err
	})
	return out, found && err == nil, err
}

// ChatPageSource is the `chat_page` slice, record `chat_page-<conversation
// id>-<before message id>`: the 60 active-branch messages before that
// message, with has_more, in the feed's per-message shape and caps. Built
// once on its request (Watches.Pages) and kept for 5 minutes; a message no
// longer on the active branch gives an empty page.
type ChatPageSource struct {
	d     *db.DB
	o     ChatFeedOptions
	mu    sync.Mutex
	cache map[ChatPageKey]cachedRecord
}

// ChatPage builds the chat_page source.
func ChatPage(d *db.DB, o ChatFeedOptions) *ChatPageSource {
	o.fill()
	return &ChatPageSource{d: d, o: o, cache: map[ChatPageKey]cachedRecord{}}
}

// Kind is "chat_page".
func (s *ChatPageSource) Kind() hubslices.Kind { return hubslices.KindChatPage }

// ChatPageID is a chat_page record's id.
func ChatPageID(k ChatPageKey) string {
	return strconv.FormatInt(k.Conversation, 10) + "-" + strconv.FormatInt(k.Before, 10)
}

// Items is the requested pages.
func (s *ChatPageSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	if ok, err := s.o.granted(); err != nil || !ok {
		s.prune(nil)
		return nil, err
	}
	keys := s.o.Watches.Pages.Active(s.o.Now())
	s.prune(keys)
	slices.SortFunc(keys, func(a, b ChatPageKey) int {
		return cmp.Or(cmp.Compare(a.Conversation, b.Conversation), cmp.Compare(a.Before, b.Before))
	})
	items := make([]hubslices.Item, 0, len(keys))
	for _, k := range keys {
		b, err := cached(&s.mu, s.cache, k, s.o.Watches.Pages.Gen(k), func() ([]byte, error) { return s.buildChatPage(ctx, k) })
		if err != nil {
			return nil, err
		}
		items = append(items, hubslices.Item{ID: ChatPageID(k), Payload: b})
	}
	return items, nil
}

func (s *ChatPageSource) prune(keep []ChatPageKey) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k := range s.cache {
		if !slices.Contains(keep, k) {
			delete(s.cache, k)
		}
	}
}

func (s *ChatPageSource) buildChatPage(ctx context.Context, k ChatPageKey) ([]byte, error) {
	var out []byte
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		var leaf sql.NullInt64
		err := tx.QueryRowContext(ctx, `SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?`, k.Conversation).Scan(&leaf)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("reading a chat page: %w", err)
		}
		page := chatPagePayload{Messages: []chatFeedMessage{}}
		if err == nil {
			path, err := chatBranchTx(ctx, tx, k.Conversation, leaf)
			if err != nil {
				return err
			}
			if at := slices.IndexFunc(path.nodes, func(n chatNode) bool { return n.id == k.Before }); at > 0 {
				window := path.nodes[max(at-MaxChatFeedMessages, 0):at]
				if page.Messages, err = chatFeedMessagesTx(ctx, tx, path, window); err != nil {
					return err
				}
				page.HasMore = at > MaxChatFeedMessages
			}
		}
		out, err = encodeChatPage(page)
		return err
	})
	return out, err
}

// ChatSearchSource is the `chat_search` slice, record `chat_search-<query
// hash>` (ChatSearchID): up to 50 hits of the Mac's chat search
// (db.SearchChats) with titles and snippets of at most 200 characters,
// within MaxChatFeedBytes. Built once on
// its request (Watches.Searches) and kept for 5 minutes.
type ChatSearchSource struct {
	d     *db.DB
	o     ChatFeedOptions
	mu    sync.Mutex
	cache map[string]cachedRecord
}

// ChatSearch builds the chat_search source.
func ChatSearch(d *db.DB, o ChatFeedOptions) *ChatSearchSource {
	o.fill()
	return &ChatSearchSource{d: d, o: o, cache: map[string]cachedRecord{}}
}

// Kind is "chat_search".
func (s *ChatSearchSource) Kind() hubslices.Kind { return hubslices.KindChatSearch }

// ChatSearchID is a chat_search record's id: the first 16 hex digits of the
// sha256 of the query's UTF-8 bytes, as the phone sent it (the Kit's
// ChatSearch.recordName).
func ChatSearchID(query string) string {
	sum := sha256.Sum256([]byte(query))
	return hex.EncodeToString(sum[:8])
}

// Items is the requested searches.
func (s *ChatSearchSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	if ok, err := s.o.granted(); err != nil || !ok {
		s.prune(nil)
		return nil, err
	}
	queries := s.o.Watches.Searches.Active(s.o.Now())
	s.prune(queries)
	slices.Sort(queries)
	items := make([]hubslices.Item, 0, len(queries))
	for _, q := range queries {
		b, err := cached(&s.mu, s.cache, q, s.o.Watches.Searches.Gen(q), func() ([]byte, error) { return s.search(q) })
		if err != nil {
			return nil, err
		}
		items = append(items, hubslices.Item{ID: ChatSearchID(q), Payload: b})
	}
	return items, nil
}

func (s *ChatSearchSource) prune(keep []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k := range s.cache {
		if !slices.Contains(keep, k) {
			delete(s.cache, k)
		}
	}
}

type chatSearchHit struct {
	ConversationID int64     `json:"conversation_id"`
	Title          string    `json:"title"`
	Snippet        string    `json:"snippet"`
	MessageID      *int64    `json:"message_id,omitempty"`
	Date           wire.Time `json:"date"`
}

type chatSearchPayload struct {
	Query string          `json:"query"`
	Hits  []chatSearchHit `json:"hits"`
}

func (s *ChatSearchSource) search(q string) ([]byte, error) {
	hits, err := s.d.SearchChats(q, MaxChatSearchHits)
	if err != nil {
		return nil, err
	}
	payload := chatSearchPayload{Query: q, Hits: make([]chatSearchHit, 0, len(hits))}
	for _, h := range hits {
		title, _ := clipText(h.Title, maxChatLabel)
		out := chatSearchHit{ConversationID: h.ConversationID, Title: title, Snippet: clipSnippet(h.Snippet), Date: secondsTime(h.Date)}
		if h.MessageID != 0 {
			out.MessageID = int64Ptr(h.MessageID)
		}
		payload.Hits = append(payload.Hits, out)
	}
	// Titles and snippets are capped, so 50 hits fit; the weakest hits go
	// should a query's echo ever not leave them room.
	for {
		b, err := wire.Marshal(payload)
		if err != nil || len(b) <= MaxChatFeedBytes || len(payload.Hits) == 0 {
			return b, err
		}
		payload.Hits = payload.Hits[:len(payload.Hits)-1]
	}
}

// clipSnippet cuts a snippet to MaxChatSearchSnippet characters, closing a
// match marker the cut left open.
func clipSnippet(s string) string {
	out, _ := clipText(s, MaxChatSearchSnippet)
	if strings.Count(out, db.ChatSearchMarkStart) > strings.Count(out, db.ChatSearchMarkEnd) {
		out, _ = clipText(s, MaxChatSearchSnippet-1)
		out += db.ChatSearchMarkEnd
	}
	return out
}

// cachedRecord is a built page or search and the request (Gen) it answers.
type cachedRecord struct {
	gen uint64
	b   []byte
}

// cached is cache[k] while it answers request gen, else built anew by build:
// the phone asked again (a Retry, a reopened screen), so it gets what the
// database holds now.
func cached[K comparable](mu *sync.Mutex, cache map[K]cachedRecord, k K, gen uint64, build func() ([]byte, error)) ([]byte, error) {
	mu.Lock()
	c, ok := cache[k]
	mu.Unlock()
	if ok && c.gen == gen {
		return bytes.Clone(c.b), nil
	}
	b, err := build()
	if err != nil {
		return nil, err
	}
	mu.Lock()
	cache[k] = cachedRecord{gen: gen, b: b}
	mu.Unlock()
	return bytes.Clone(b), nil
}

// --- the shared payload builder ---

type chatRouting struct {
	Mode     string  `json:"mode"`
	Provider *string `json:"provider,omitempty"`
	Model    *string `json:"model,omitempty"`
}

type chatFeedLease struct {
	Owner       string `json:"owner"`
	TurnID      string `json:"turn_id"`
	WaitingSlot bool   `json:"waiting_slot"`
}

type chatFeedConversation struct {
	ID             int64            `json:"id"`
	Title          string           `json:"title"`
	Project        *chatListProject `json:"project,omitempty"`
	Routing        chatRouting      `json:"routing"`
	ActualProvider string           `json:"actual_provider"`
	ActualModel    string           `json:"actual_model"`
	LiveSlackSince *int64           `json:"live_slack_since,omitempty"`
	Lease          *chatFeedLease   `json:"lease,omitempty"`
}

type chatSiblings struct {
	Index int `json:"index"`
	Count int `json:"count"`
	// IDs are the siblings' message ids in order, only when there is more
	// than one: the phone's ‹ i/n › names the sibling it selects
	// (chat_branch_select).
	IDs []int64 `json:"ids,omitempty"`
}

type chatFeedAttachment struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
	Mime string `json:"mime"`
	Size int64  `json:"size"`
}

type chatFeedStep struct {
	Name    string        `json:"name"`
	OK      *bool         `json:"ok,omitempty"`
	Summary string        `json:"summary"`
	Sources []chat.Source `json:"sources"`
}

type chatFeedMessage struct {
	ID           int64                `json:"id"`
	Role         string               `json:"role"`
	Text         string               `json:"text"`
	TextCut      bool                 `json:"text_cut"`
	Status       string               `json:"status"`
	ErrorCode    *string              `json:"error_code,omitempty"`
	ErrorMessage *string              `json:"error_message,omitempty"`
	CreatedAt    wire.Time            `json:"created_at"`
	Siblings     chatSiblings         `json:"siblings"`
	Attachments  []chatFeedAttachment `json:"attachments"`
	Steps        []chatFeedStep       `json:"steps"`

	turnID string
}

type chatFeedArtifact struct {
	Key        string  `json:"key"`
	Kind       string  `json:"kind"`
	Title      string  `json:"title"`
	Version    int     `json:"version"`
	Content    *string `json:"content,omitempty"`
	ContentCut bool    `json:"content_cut"`
}

type chatFeedAction struct {
	ID          int64   `json:"id"`
	Tool        string  `json:"tool"`
	Title       string  `json:"title"`
	ArgsDisplay string  `json:"args_display"`
	ArgsSHA256  string  `json:"args_sha256"`
	Status      string  `json:"status"`
	Reason      *string `json:"reason,omitempty"`

	turnID string
}

type chatFeedPayload struct {
	Conversation chatFeedConversation `json:"conversation"`
	Messages     []chatFeedMessage    `json:"messages"`
	HasMore      bool                 `json:"has_more"`
	Artifacts    []chatFeedArtifact   `json:"artifacts"`
	Actions      []chatFeedAction     `json:"actions"`
}

type chatPagePayload struct {
	Messages []chatFeedMessage `json:"messages"`
	HasMore  bool              `json:"has_more"`
}

// chatFeedConversationTx is the feed's conversation meta and its leaf; ok
// is false when the conversation is gone. The lease is shown only while
// its heartbeat is less than 60 s old.
func chatFeedConversationTx(ctx context.Context, tx *sql.Tx, conv int64, now time.Time) (chatFeedConversation, sql.NullInt64, bool, error) {
	var (
		c                       chatFeedConversation
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
WHERE c.id = ?`, conv).Scan(&c.ID, &c.Title, &leaf, &projectID, &project, &mode, &provider, &mdl,
		&c.ActualProvider, &c.ActualModel, &slack, &leaseOwner, &leaseTurnID, &heartbeat)
	if errors.Is(err, sql.ErrNoRows) {
		return c, leaf, false, nil
	}
	if err != nil {
		return c, leaf, false, fmt.Errorf("reading a chat conversation: %w", err)
	}
	if projectID.Valid {
		c.Project = &chatListProject{ID: projectID.Int64, Name: project.String}
	}
	c.Routing = chatRouting{Mode: "auto"}
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
		c.Lease = &chatFeedLease{Owner: leaseOwner.String, TurnID: leaseTurnID.String}
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
	siblings map[int64]chatSiblings
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
	b := chatBranch{siblings: map[int64]chatSiblings{}}
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
			b.siblings[n.id] = chatSiblings{Index: 1, Count: 1}
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
		sib := chatSiblings{Index: max(slices.Index(sibs, n.id), 0) + 1, Count: len(sibs)}
		if len(sibs) > 1 {
			sib.IDs = slices.Clone(sibs)
		}
		b.siblings[n.id] = sib
	}
	return b, nil
}

// chatFeedMessagesTx reads window's messages with their attachments and
// steps; every text is cut at MaxChatMessageText.
func chatFeedMessagesTx(ctx context.Context, tx *sql.Tx, b chatBranch, window []chatNode) ([]chatFeedMessage, error) {
	out := []chatFeedMessage{}
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
func chatFeedMessageRowsTx(ctx context.Context, tx *sql.Tx, b chatBranch, in string, args []any) (map[int64]*chatFeedMessage, error) {
	//nolint:gosec // G202: in is "?,?,…" placeholders only
	rows, err := tx.QueryContext(ctx, `SELECT id, role, text, status, error_code, error_message, created_at, turn_id
		FROM chat_messages WHERE id IN (`+in+`) ORDER BY id`, args...)
	if err != nil {
		return nil, fmt.Errorf("reading chat messages: %w", err)
	}
	defer func() { _ = rows.Close() }()
	byID := map[int64]*chatFeedMessage{}
	for rows.Next() {
		var (
			m             chatFeedMessage
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
			m.ErrorMessage = &message.String
		}
		m.CreatedAt = secondsTime(created)
		m.Siblings = b.siblings[m.ID]
		m.Attachments, m.Steps = []chatFeedAttachment{}, []chatFeedStep{}
		byID[m.ID] = &m
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading chat messages: %w", err)
	}
	return byID, nil
}

func (m *chatFeedMessage) setText(text string) {
	cut, clipped := clipText(text, MaxChatMessageText)
	m.Text, m.TextCut = cut, clipped != nil
}

func chatFeedAttachmentsTx(ctx context.Context, tx *sql.Tx, in string, args []any, byID map[int64]*chatFeedMessage) error {
	//nolint:gosec // G202: in is "?,?,…" placeholders only
	rows, err := tx.QueryContext(ctx, `SELECT id, message_id, name, mime, size FROM chat_attachments
		WHERE message_id IN (`+in+`) ORDER BY id`, args...)
	if err != nil {
		return fmt.Errorf("reading chat attachments: %w", err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var a chatFeedAttachment
		var msg int64
		if err := rows.Scan(&a.ID, &msg, &a.Name, &a.Mime, &a.Size); err != nil {
			return fmt.Errorf("reading chat attachments: %w", err)
		}
		if m := byID[msg]; m != nil {
			m.Attachments = append(m.Attachments, a)
		}
	}
	return rows.Err()
}

func chatFeedStepsTx(ctx context.Context, tx *sql.Tx, in string, args []any, byID map[int64]*chatFeedMessage) error {
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
			s       chatFeedStep
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
func applyLiveText(msgs []chatFeedMessage, turnID, text string, steps []chatstore.Step) {
	for i := range msgs {
		m := &msgs[i]
		if m.Role != "assistant" || m.turnID != turnID {
			continue
		}
		m.setText(text)
		m.Steps = make([]chatFeedStep, 0, len(steps))
		for _, st := range steps {
			s := chatFeedStep{Name: st.Name, Summary: st.Summary, Sources: st.Sources}
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
// in creation order.
func chatFeedArtifactsTx(ctx context.Context, tx *sql.Tx, conv int64) ([]chatFeedArtifact, error) {
	rows, err := tx.QueryContext(ctx, `SELECT a.artifact_key, a.kind, a.title, a.version, a.content FROM chat_artifacts a
		WHERE a.conversation_id = ? AND a.version = (SELECT MAX(b.version) FROM chat_artifacts b
			WHERE b.conversation_id = a.conversation_id AND b.artifact_key = a.artifact_key)
		ORDER BY a.id`, conv)
	if err != nil {
		return nil, fmt.Errorf("reading chat artifacts: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []chatFeedArtifact{}
	for rows.Next() {
		var a chatFeedArtifact
		var content string
		if err := rows.Scan(&a.Key, &a.Kind, &a.Title, &a.Version, &content); err != nil {
			return nil, fmt.Errorf("reading chat artifacts: %w", err)
		}
		a.Content = &content
		out = append(out, a)
	}
	return out, rows.Err()
}

// chatFeedActionsTx is the agent_actions of window's turns, oldest first:
// the pending ones the phone may answer and the decided ones it shows.
func chatFeedActionsTx(ctx context.Context, tx *sql.Tx, conv int64, window []chatNode) ([]chatFeedAction, error) {
	out := []chatFeedAction{}
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
		var a chatFeedAction
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
	out, _ := clipText(text, maxChatActionArgsBytes)
	return out
}

// encodeChatFeed encodes p within MaxChatFeedBytes, always: the oldest
// messages go first (has_more then true; the newest one always stays) with
// the actions of their turns, then the artifacts' contents, largest first
// (content_cut: "Open on your Mac"), then fitFeed's last resort.
func encodeChatFeed(p chatFeedPayload) ([]byte, error) {
	msgSizes, err := sizes(p.Messages)
	if err != nil {
		return nil, err
	}
	envelope := p
	envelope.Messages, envelope.HasMore = []chatFeedMessage{}, false
	base, err := wire.Marshal(envelope)
	if err != nil {
		return nil, err
	}
	total := len(base) + sum(msgSizes) + commas(len(msgSizes))
	drop := 0
	for total > MaxChatFeedBytes && len(msgSizes)-drop > 1 {
		total -= msgSizes[drop] + min(1, len(msgSizes)-drop-1)
		drop++
	}
	if drop > 0 {
		p.Messages, p.HasMore = p.Messages[drop:], true
		turns := map[string]bool{}
		for _, m := range p.Messages {
			turns[m.turnID] = true
		}
		p.Actions = slices.DeleteFunc(slices.Clone(p.Actions), func(a chatFeedAction) bool { return !turns[a.turnID] })
	}
	b, err := wire.Marshal(p)
	if err != nil || len(b) <= MaxChatFeedBytes {
		return b, err
	}
	artSizes, err := sizes(p.Artifacts)
	if err != nil {
		return nil, err
	}
	over := len(b) - MaxChatFeedBytes
	order := make([]int, len(p.Artifacts))
	for i := range order {
		order[i] = i
	}
	slices.SortStableFunc(order, func(a, b int) int { return cmp.Compare(artSizes[b], artSizes[a]) })
	p.Artifacts = slices.Clone(p.Artifacts)
	for _, i := range order {
		if over <= 0 {
			break
		}
		a := &p.Artifacts[i]
		a.Content, a.ContentCut = nil, true
		cut, err := wire.Marshal(*a)
		if err != nil {
			return nil, err
		}
		over -= artSizes[i] - len(cut)
	}
	return fitFeed(p)
}

// fitFeed is the hard ceiling: while the record is over MaxChatFeedBytes
// (a newest message of wide graphemes or escaped control characters, many
// large actions or steps), it cuts the largest message text by encoded
// bytes (text_cut stays true), then empties the messages' steps, then
// drops actions, oldest first, then clips the title. The result always
// fits unless the envelope alone does not, which no field allows.
func fitFeed(p chatFeedPayload) ([]byte, error) {
	p.Messages = slices.Clone(p.Messages)
	p.Actions = slices.Clone(p.Actions)
	for {
		b, err := wire.Marshal(p)
		if err != nil || len(b) <= MaxChatFeedBytes {
			return b, err
		}
		over := len(b) - MaxChatFeedBytes
		switch {
		case shrinkLargestText(p.Messages, over):
		case clearSteps(p.Messages):
		case len(p.Actions) > 0:
			p.Actions = p.Actions[1:]
		case uniseg.GraphemeClusterCount(p.Conversation.Title) > maxChatLabel:
			p.Conversation.Title, _ = clipText(p.Conversation.Title, maxChatLabel)
		default:
			return b, nil
		}
	}
}

// encodeChatPage is encodeChatFeed for a page: the oldest messages go
// first, then fitPage's last resort.
func encodeChatPage(p chatPagePayload) ([]byte, error) {
	msgSizes, err := sizes(p.Messages)
	if err != nil {
		return nil, err
	}
	base, err := wire.Marshal(chatPagePayload{Messages: []chatFeedMessage{}})
	if err != nil {
		return nil, err
	}
	total := len(base) + sum(msgSizes) + commas(len(msgSizes))
	drop := 0
	for total > MaxChatFeedBytes && len(msgSizes)-drop > 1 {
		total -= msgSizes[drop] + min(1, len(msgSizes)-drop-1)
		drop++
	}
	if drop > 0 {
		p.Messages, p.HasMore = p.Messages[drop:], true
	}
	p.Messages = slices.Clone(p.Messages)
	for {
		b, err := wire.Marshal(p)
		if err != nil || len(b) <= MaxChatFeedBytes {
			return b, err
		}
		if !shrinkLargestText(p.Messages, len(b)-MaxChatFeedBytes) && !clearSteps(p.Messages) {
			return b, nil
		}
	}
}

// shrinkLargestText cuts the message text that encodes largest by at least
// over encoded bytes (by graphemes, ellipsis included; text_cut set); false
// when every text is already empty.
func shrinkLargestText(msgs []chatFeedMessage, over int) bool {
	best, bestLen := -1, 2 // `""`
	for i := range msgs {
		if n := jsonLen(msgs[i].Text); n > bestLen {
			best, bestLen = i, n
		}
	}
	if best < 0 {
		return false
	}
	m := &msgs[best]
	target := bestLen - over
	lo, hi := 0, uniseg.GraphemeClusterCount(m.Text)-1 // hi: cut by at least one
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if t, _ := clipText(m.Text, mid); jsonLen(t) <= target {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	m.Text, _ = clipText(m.Text, lo)
	m.TextCut = true
	return true
}

// clearSteps empties the steps of the message whose steps are largest;
// false when no message has steps.
func clearSteps(msgs []chatFeedMessage) bool {
	best, bestLen := -1, 0
	for i := range msgs {
		if len(msgs[i].Steps) == 0 {
			continue
		}
		b, _ := wire.Marshal(msgs[i].Steps)
		if len(b) > bestLen {
			best, bestLen = i, len(b)
		}
	}
	if best < 0 {
		return false
	}
	msgs[best].Steps = []chatFeedStep{}
	return true
}

// jsonLen is a string's encoded length on the wire.
func jsonLen(s string) int {
	b, err := wire.Marshal(s)
	if err != nil {
		return len(s)
	}
	return len(b)
}

func sizes[T any](items []T) ([]int, error) {
	out := make([]int, len(items))
	for i, it := range items {
		b, err := wire.Marshal(it)
		if err != nil {
			return nil, err
		}
		out[i] = len(b)
	}
	return out, nil
}

func sum(xs []int) int {
	n := 0
	for _, x := range xs {
		n += x
	}
	return n
}

// commas is the separators of an n-element JSON array.
func commas(n int) int { return max(n-1, 0) }
