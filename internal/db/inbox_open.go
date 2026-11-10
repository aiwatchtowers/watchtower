package db

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// InboxFeedTriggers are the triggers of an open message, the Go twin of the
// Desktop's HomeFeedQueries.feedTriggers.
var InboxFeedTriggers = []string{
	"mention", "dm", "thread_reply", "reaction",
	"jira_assigned", "jira_comment_mention", "linear_assigned", "linear_comment_mention",
	"email_received",
}

// openInboxClause is the Go twin of the Desktop's
// HomeFeedQueries.openMessageClause: pending actionable rows of the feed
// triggers that are not archived or snoozed past now, and whose Jira issue
// was not deleted at the source. One `?`: now (RFC 3339 UTC). The shared
// fixture internal/inbox/testdata/open_items.json pins that both agree.
var openInboxClause = `status = 'pending' AND item_class = 'actionable' AND archived_at IS NULL
	AND trigger_type IN ('` + strings.Join(InboxFeedTriggers, "', '") + `')
	AND (snooze_until = '' OR snooze_until <= ?)
	AND (substr(trigger_type, 1, 5) != 'jira_' OR EXISTS (
	  SELECT 1 FROM jira_issues j WHERE j.key = inbox_items.channel_id AND j.is_deleted = 0))`

// OpenInboxItem is one open attention item with what its row shows.
type OpenInboxItem struct {
	InboxItem
	// At is MAX(created_at, mentioned_at): when the item last got news.
	At string
	// SenderName is the sender's display, real or user name (its id when
	// the user row has none); "" when no user row matches.
	SenderName string
	// ChannelName is the channel's name; "" when no channel row matches.
	ChannelName string
}

// OpenInboxItems returns at most limit open attention items (openInboxClause
// at now), newest first by MAX(created_at, mentioned_at), then id — the
// order and rows of the Desktop's InboxQueries.fetchOpenMessages. A
// channel-folded item (INBOX-09) is one row.
func (db *DB) OpenInboxItems(ctx context.Context, now time.Time, limit int) ([]OpenInboxItem, error) {
	rows, err := db.QueryContext(ctx, `SELECT `+inboxItemColumns+`, MAX(created_at, mentioned_at) AS stamp,
		COALESCE((SELECT COALESCE(NULLIF(u.display_name, ''), NULLIF(u.real_name, ''), NULLIF(u.name, ''), u.id)
			FROM users u WHERE u.id = inbox_items.sender_user_id), ''),
		COALESCE((SELECT c.name FROM channels c WHERE c.id = inbox_items.channel_id), '')
		FROM inbox_items
		WHERE `+openInboxClause+`
		ORDER BY stamp DESC, id DESC
		LIMIT ?`, now.UTC().Format("2006-01-02T15:04:05Z"), limit)
	if err != nil {
		return nil, fmt.Errorf("reading open inbox items: %w", err)
	}
	defer rows.Close()
	var out []OpenInboxItem
	for rows.Next() {
		var o OpenInboxItem
		it, err := scanInboxItem(extraScan{rows, []any{&o.At, &o.SenderName, &o.ChannelName}})
		if err != nil {
			return nil, fmt.Errorf("scanning an open inbox item: %w", err)
		}
		o.InboxItem = *it
		out = append(out, o)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading open inbox items: %w", err)
	}
	return out, nil
}

// extraScan scans the standard inbox columns, then extra.
type extraScan struct {
	row   interface{ Scan(...any) error }
	extra []any
}

func (e extraScan) Scan(dest ...any) error { return e.row.Scan(append(dest, e.extra...)...) }
