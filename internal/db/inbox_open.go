package db

import (
	"cmp"
	"context"
	"fmt"
	"slices"
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
	return db.openInboxItems(ctx, now, "", limit)
}

// WaitingKind splits the open attention items: people (Waiting for me) and
// mail (Mail waiting).
type WaitingKind string

const (
	WaitingPeople WaitingKind = "people"
	WaitingMail   WaitingKind = "mail"
)

// WaitingKindOf is a feed trigger's kind: email_received is mail, every
// other feed trigger is people.
func WaitingKindOf(trigger string) WaitingKind {
	if trigger == "email_received" {
		return WaitingMail
	}
	return WaitingPeople
}

// MuteScopePrefix prefixes a mail sender's key in a source_mute learned
// rule's scope_key: 'email:' || MailSenderKey(address).
const MuteScopePrefix = "email:"

// MailSenderKey is the one spelling of a mail sender: spaces trimmed from
// both ends and ASCII letters lowered, other characters unchanged — exactly
// SQLite's lower(trim(x)).
func MailSenderKey(raw string) string {
	b := []byte(strings.Trim(raw, " "))
	for i, c := range b {
		if 'A' <= c && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	return string(b)
}

// MailSubject is a mail item's subject: its snippet before " — " (the
// whole snippet when it has none).
func MailSubject(snippet string) string {
	subject, _, _ := strings.Cut(snippet, " — ")
	return subject
}

// mutedMailClause keeps an item whose sender has no source_mute rule on its
// MailSenderKey (any weight, any pipeline). It applies to mail only.
const mutedMailClause = `NOT EXISTS (SELECT 1 FROM inbox_learned_rules r WHERE r.rule_type = 'source_mute'
	AND r.scope_key = '` + MuteScopePrefix + `' || lower(trim(inbox_items.sender_user_id)))`

// waitingKindClause narrows openInboxClause to kind: people is every feed
// trigger but email_received; mail is email_received from an unmuted sender.
func waitingKindClause(kind WaitingKind) (string, error) {
	switch kind {
	case WaitingPeople:
		return ` AND trigger_type != 'email_received'`, nil
	case WaitingMail:
		return ` AND trigger_type = 'email_received' AND ` + mutedMailClause, nil
	}
	return "", fmt.Errorf("unknown waiting kind %q", kind)
}

// OpenInboxItemsOfKind returns at most limit open items of kind, in
// OpenInboxItems's order; mail leaves muted senders out.
func (db *DB) OpenInboxItemsOfKind(ctx context.Context, now time.Time, kind WaitingKind, limit int) ([]OpenInboxItem, error) {
	clause, err := waitingKindClause(kind)
	if err != nil {
		return nil, err
	}
	return db.openInboxItems(ctx, now, clause, limit)
}

func (db *DB) openInboxItems(ctx context.Context, now time.Time, kindClause string, limit int) ([]OpenInboxItem, error) {
	rows, err := db.QueryContext(ctx, `SELECT `+inboxItemColumns+`, MAX(created_at, mentioned_at) AS stamp,
		COALESCE((SELECT COALESCE(NULLIF(u.display_name, ''), NULLIF(u.real_name, ''), NULLIF(u.name, ''), u.id)
			FROM users u WHERE u.id = inbox_items.sender_user_id), ''),
		COALESCE((SELECT c.name FROM channels c WHERE c.id = inbox_items.channel_id), '')
		FROM inbox_items
		WHERE `+openInboxClause+kindClause+`
		ORDER BY stamp DESC, id DESC
		LIMIT ?`, sqlStamp(now), limit)
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

// sqlStamp is t in the stored timestamp layout (RFC 3339 UTC, seconds).
func sqlStamp(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

// PeopleWaitingCounts counts the open people items by WaitingSectionOf.
type PeopleWaitingCounts struct{ Open, Today, Week, Older int }

// OpenPeopleCounts counts every open people item (no cap) by section, the
// SQL form of WaitingSectionOf on MAX(created_at, mentioned_at): Today from
// StartOfToday(now), Older at or before now − WaitingOlderAfter, Week the
// rest.
func (db *DB) OpenPeopleCounts(ctx context.Context, now time.Time) (PeopleWaitingCounts, error) {
	clause, _ := waitingKindClause(WaitingPeople)
	today := sqlStamp(StartOfToday(now))
	var c PeopleWaitingCounts
	err := db.QueryRowContext(ctx, `SELECT COUNT(*),
		COALESCE(SUM(stamp >= ?), 0),
		COALESCE(SUM(stamp < ? AND stamp <= ?), 0)
		FROM (SELECT MAX(created_at, mentioned_at) AS stamp FROM inbox_items WHERE `+openInboxClause+clause+`)`,
		today, today, sqlStamp(now.Add(-WaitingOlderAfter)), sqlStamp(now)).Scan(&c.Open, &c.Today, &c.Older)
	if err != nil {
		return PeopleWaitingCounts{}, fmt.Errorf("counting open people items: %w", err)
	}
	c.Week = c.Open - c.Today - c.Older
	return c, nil
}

// MailSender is one sender of open, unmuted mail.
type MailSender struct {
	// Address is the sender's MailSenderKey; "" for mail with no address.
	Address string
	// Open and Today count the sender's open mail and its mail from today.
	Open, Today int
	// Subject, At and Permalink are the sender's newest item's subject
	// (MailSubject), MAX(created_at, mentioned_at) and link.
	Subject, At, Permalink string
}

// MailWaiting is the sender view of the open, unmuted mail.
type MailWaiting struct {
	// Open, Today and SenderCount are over every sender; TopTenShare is the
	// top ten senders' share of Open in whole percent, rounded half up.
	Open, Today, SenderCount, TopTenShare int
	// Senders lists the busiest senders first, at most the limit asked.
	Senders []MailSender
}

// OpenMailSenders groups the open, unmuted mail by MailSenderKey, ordered by
// open count DESC, newest item DESC, address ASC; Senders is capped at limit,
// the totals are not. Mail with no sender address ("" after the key rule)
// groups into one "" sender on purpose — the Desktop's twin does the same.
func (db *DB) OpenMailSenders(ctx context.Context, now time.Time, limit int) (MailWaiting, error) {
	clause, _ := waitingKindClause(WaitingMail)
	rows, err := db.QueryContext(ctx, `SELECT lower(trim(sender_user_id)), MAX(created_at, mentioned_at) AS stamp,
		snippet, permalink
		FROM inbox_items
		WHERE `+openInboxClause+clause+`
		ORDER BY stamp DESC, id DESC`, sqlStamp(now))
	if err != nil {
		return MailWaiting{}, fmt.Errorf("reading open mail: %w", err)
	}
	defer rows.Close()
	today := sqlStamp(StartOfToday(now))
	var w MailWaiting
	var senders []MailSender
	index := map[string]int{}
	for rows.Next() {
		var addr, stamp, snippet, permalink string
		if err := rows.Scan(&addr, &stamp, &snippet, &permalink); err != nil {
			return MailWaiting{}, fmt.Errorf("scanning open mail: %w", err)
		}
		i, seen := index[addr]
		if !seen {
			// Rows come newest first: the first row of a sender is its newest.
			i = len(senders)
			index[addr] = i
			senders = append(senders, MailSender{Address: addr, Subject: MailSubject(snippet), At: stamp, Permalink: permalink})
		}
		senders[i].Open++
		w.Open++
		if stamp >= today {
			senders[i].Today++
			w.Today++
		}
	}
	if err := rows.Err(); err != nil {
		return MailWaiting{}, fmt.Errorf("reading open mail: %w", err)
	}
	slices.SortStableFunc(senders, func(a, b MailSender) int {
		if a.Open != b.Open {
			return cmp.Compare(b.Open, a.Open)
		}
		if a.At != b.At {
			return cmp.Compare(b.At, a.At)
		}
		return cmp.Compare(a.Address, b.Address)
	})
	w.SenderCount = len(senders)
	if w.Open > 0 {
		top := 0
		for _, s := range senders[:min(10, len(senders))] {
			top += s.Open
		}
		w.TopTenShare = (100*top + w.Open/2) / w.Open
	}
	w.Senders = senders[:min(max(limit, 0), len(senders))]
	return w, nil
}

// extraScan scans the standard inbox columns, then extra.
type extraScan struct {
	row   interface{ Scan(...any) error }
	extra []any
}

func (e extraScan) Scan(dest ...any) error { return e.row.Scan(append(dest, e.extra...)...) }
