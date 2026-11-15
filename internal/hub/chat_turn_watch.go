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
// partial one) and `approval` (an action of the turn waits for the owner) —
// for the hub's own turns (the runner's OnTurnEnd) and the Mac app's (found
// on the data_version watch: a desktop lease disappears and its turn's
// assistant row is final; a new pending action of a chat turn). The pusher's
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
	leases  map[int64]string // desktop-owned leases: conversation → turn
	pending map[int64]bool   // pending chat actions seen
	// unresolved are vanished leases whose assistant row was not final yet
	// (turn → tries left): looked at again on the next checks, then dropped.
	unresolved map[string]unresolvedTurn
}

// chatUnresolvedChecks bounds how many checks wait for a vanished lease's
// final assistant row.
const chatUnresolvedChecks = 6

type unresolvedTurn struct {
	conv  int64
	tries int
}

func newChatPushWatch(d *sql.DB, w *sources.ChatWatches, onRelay func() bool, now func() time.Time,
	enqueue func(string, secure.WorkAlertFields, time.Time),
) *chatPushWatch {
	return &chatPushWatch{db: d, watches: w, enqueue: enqueue, onRelay: onRelay, now: now,
		kickCh: make(chan struct{}, 1), leases: map[int64]string{}, pending: map[int64]bool{}, unresolved: map[string]unresolvedTurn{}}
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

// turnEnded is the hub runner's OnTurnEnd: the push of a turn the hub ran.
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
// chat or the hub is not on the relay.
func (c *chatPushWatch) send(ctx context.Context, conv int64, turnID, kind string) {
	if turnID == "" || c.enqueue == nil || (c.onRelay != nil && !c.onRelay()) {
		return
	}
	now := c.now()
	if c.watches != nil && c.watches.Open(conv, now.Add(-chatLookingWindow)) {
		return
	}
	var title string
	err := c.db.QueryRowContext(ctx, `SELECT title FROM chat_conversations WHERE id = ?`, conv).Scan(&title)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) { // a deleted conversation has nothing to push
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

// check compares the database with the last look: a desktop lease that
// disappeared with its turn's assistant row final, and a chat action newly
// pending. The first look only records.
func (c *chatPushWatch) check(ctx context.Context) {
	leases, err := c.desktopLeases(ctx)
	if err != nil {
		log.Printf("hub: chat push watch: leases unreadable (%s)", errClass(err))
		return
	}
	pending, err := c.pendingActions(ctx)
	if err != nil {
		log.Printf("hub: chat push watch: actions unreadable (%s)", errClass(err))
		return
	}
	c.mu.Lock()
	primed, oldLeases, oldPending := c.primed, c.leases, c.pending
	c.primed, c.leases = true, leases
	c.pending = map[int64]bool{}
	for id := range pending {
		c.pending[id] = true
	}
	c.mu.Unlock()
	if !primed {
		return
	}
	c.mu.Lock()
	for conv, turn := range oldLeases {
		if leases[conv] != turn {
			c.unresolved[turn] = unresolvedTurn{conv: conv}
		}
	}
	waiting := make(map[string]unresolvedTurn, len(c.unresolved))
	for turn, u := range c.unresolved {
		waiting[turn] = u
	}
	c.mu.Unlock()
	for turn, u := range waiting {
		status, ok, err := c.assistantStatus(ctx, u.conv, turn)
		if err != nil {
			log.Printf("hub: chat push watch: turn %s unreadable (%s)", turn, errClass(err))
		}
		c.mu.Lock()
		switch {
		case err == nil && ok:
			delete(c.unresolved, turn)
		case u.tries+1 >= chatUnresolvedChecks:
			delete(c.unresolved, turn) // the row never became final
		default:
			c.unresolved[turn] = unresolvedTurn{conv: u.conv, tries: u.tries + 1}
		}
		c.mu.Unlock()
		if err == nil && ok {
			c.send(ctx, u.conv, turn, endKind(status))
		}
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

// desktopLeases is the conversations the Mac app runs a turn in.
func (c *chatPushWatch) desktopLeases(ctx context.Context) (map[int64]string, error) {
	rows, err := c.db.QueryContext(ctx, `SELECT conversation_id, turn_id FROM chat_turn_leases WHERE owner = 'desktop'`)
	if err != nil {
		return nil, fmt.Errorf("reading desktop chat leases: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := map[int64]string{}
	for rows.Next() {
		var conv int64
		var turn string
		if err := rows.Scan(&conv, &turn); err != nil {
			return nil, fmt.Errorf("reading desktop chat leases: %w", err)
		}
		out[conv] = turn
	}
	return out, rows.Err()
}

// pendingActions is the chat actions waiting for the owner (asked, not
// executed on their own).
func (c *chatPushWatch) pendingActions(ctx context.Context) (map[int64]pendingChatAction, error) {
	rows, err := c.db.QueryContext(ctx, `SELECT id, conversation_id, turn_id FROM agent_actions
		WHERE status = 'pending' AND trust_at_create = 'ask' AND conversation_id > 0 AND turn_id <> ''`)
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

// assistantStatus is the stored status of the turn's newest assistant row.
func (c *chatPushWatch) assistantStatus(ctx context.Context, conv int64, turn string) (string, bool, error) {
	var status string
	err := c.db.QueryRowContext(ctx, `SELECT status FROM chat_messages
		WHERE conversation_id = ? AND turn_id = ? AND role = 'assistant' ORDER BY id DESC LIMIT 1`, conv, turn).Scan(&status)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return status, err == nil, err
}
