package hub

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"watchtower/internal/chatstore"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/slices/sources"
)

// chatLookingWindow is how long an open chat_feed_request keeps the phone
// "looking" at a chat (iPhone chat spec §4.7): a turn ending inside it does
// not push.
const chatLookingWindow = 90 * time.Second

// chatPushWatch sends the chat_answer pushes (iPhone chat spec §4.7): one per
// (turn, event) — `answer` (a complete turn), `stopped` (an error or a
// partial one) and `approval` (an action of the turn waits for the owner).
// Every turn runs on the daemon's one chat engine, whoever started it (the
// phone over the relay, the Mac app over chat.sock), so a turn's end is the
// engine's OnTurnEnd; a new pending action of a chat turn is found on the
// agent_actions kick (the session's MCP process writes it). The pusher's
// ledger (`alert_pushes`, key chat:<turn_id>:<event>) keeps each at once
// per phone across restarts, and its away and paying-slot rules apply as to
// every work alert. Logs carry ids only (FILES-01).
type chatPushWatch struct {
	db      *sql.DB
	watches *sources.ChatWatches
	// enqueue hands a push to the alert pusher (nil pusher = none).
	enqueue func(key string, f secure.WorkAlertFields, at time.Time)
	onRelay func() bool
	now     func() time.Time

	kickCh chan struct{}

	mu      sync.Mutex
	primed  bool
	pending map[int64]bool // pending chat actions seen
}

func newChatPushWatch(d *sql.DB, w *sources.ChatWatches, onRelay func() bool, now func() time.Time,
	enqueue func(string, secure.WorkAlertFields, time.Time),
) *chatPushWatch {
	return &chatPushWatch{db: d, watches: w, enqueue: enqueue, onRelay: onRelay, now: now,
		kickCh: make(chan struct{}, 1), pending: map[int64]bool{}}
}

// kick asks for a check (the data_version watch saw a write).
func (c *chatPushWatch) kick() {
	select {
	case c.kickCh <- struct{}{}:
	default:
	}
}

// run checks on every kick and every chatTickEvery (the backstop when there
// is no data_version watch) until ctx ends.
func (c *chatPushWatch) run(ctx context.Context) {
	t := time.NewTicker(chatTickEvery)
	defer t.Stop()
	for {
		c.check(ctx)
		select {
		case <-ctx.Done():
			return
		case <-c.kickCh:
		case <-t.C:
		}
	}
}

// turnEnded is the engine's OnTurnEnd: the push of every turn it ran.
func (c *chatPushWatch) turnEnded(conv int64, turnID, status string) {
	c.send(context.Background(), conv, turnID, endKind(status))
}

// endKind is the event of a finalized turn's status.
func endKind(status string) string {
	if status == chatstore.StatusComplete {
		return sources.ChatAlertAnswer
	}
	return sources.ChatAlertStopped
}

// send pushes one (turn, event) unless the owner's phone is looking at the
// chat or the hub is not on the relay. A Discuss chat (context_type set) is
// not a main chat and never pushes (iPhone chat spec §1).
func (c *chatPushWatch) send(ctx context.Context, conv int64, turnID, kind string) {
	if turnID == "" || c.enqueue == nil || (c.onRelay != nil && !c.onRelay()) {
		return
	}
	now := c.now()
	if c.watches != nil && c.watches.Open(conv, now.Add(-chatLookingWindow)) {
		return
	}
	var title string
	err := c.db.QueryRowContext(ctx, `SELECT title FROM chat_conversations WHERE id = ? AND context_type IS NULL`, conv).Scan(&title)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) { // a deleted or Discuss conversation has nothing to push
			log.Printf("hub: chat push of conversation %d dropped: title unreadable (%s)", conv, errClass(err))
		}
		return
	}
	key, f, ok := sources.ChatAlert(conv, turnID, kind, title)
	if !ok {
		return
	}
	c.enqueue(key, f, now)
}

// check compares the chat actions pending now with the last look and
// pushes each newly pending one. The first look only records.
func (c *chatPushWatch) check(ctx context.Context) {
	pending, err := c.pendingActions(ctx)
	if err != nil {
		log.Printf("hub: chat push watch: actions unreadable (%s)", errClass(err))
		return
	}
	c.mu.Lock()
	primed, oldPending := c.primed, c.pending
	c.primed = true
	c.pending = map[int64]bool{}
	for id := range pending {
		c.pending[id] = true
	}
	c.mu.Unlock()
	if !primed {
		return
	}
	for id, p := range pending {
		if !oldPending[id] {
			c.send(ctx, p.conv, p.turn, sources.ChatAlertApproval)
		}
	}
}

type pendingChatAction struct {
	conv int64
	turn string
}

// pendingActions is the main chats' actions waiting for the owner (asked,
// not executed on their own).
func (c *chatPushWatch) pendingActions(ctx context.Context) (map[int64]pendingChatAction, error) {
	rows, err := c.db.QueryContext(ctx, `SELECT a.id, a.conversation_id, a.turn_id FROM agent_actions a
		JOIN chat_conversations c ON c.id = a.conversation_id
		WHERE a.status = 'pending' AND a.trust_at_create = 'ask' AND a.turn_id <> '' AND c.context_type IS NULL`)
	if err != nil {
		return nil, fmt.Errorf("reading pending chat actions: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := map[int64]pendingChatAction{}
	for rows.Next() {
		var id int64
		var p pendingChatAction
		if err := rows.Scan(&id, &p.conv, &p.turn); err != nil {
			return nil, fmt.Errorf("reading pending chat actions: %w", err)
		}
		out[id] = p
	}
	return out, rows.Err()
}
