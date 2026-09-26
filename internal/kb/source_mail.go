package kb

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// changedByColumn returns the distinct keys whose marker column is at or past
// cursor, and the new cursor (the max marker seen, never below cursor).
// Markers have one-second resolution, so every Changed query compares with
// >= : a row written in the same second as the stored cursor, after the
// previous run read it, is still picked up. Rows at exactly the cursor are
// re-rendered each run, which the content-hash gate keeps write-free.
func changedByColumn(ctx context.Context, q Queryer, cursor, query string, args ...any) ([]string, string, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, cursor, err
	}
	defer rows.Close()
	set := map[string]bool{}
	next := cursor
	for rows.Next() {
		var key, marker string
		if err := rows.Scan(&key, &marker); err != nil {
			return nil, cursor, err
		}
		set[key] = true
		next = maxString(next, marker)
	}
	if err := rows.Err(); err != nil {
		return nil, cursor, err
	}
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys, next, nil
}

// mailHeader renders the shared Gmail/IMAP message header + body shape:
// "From <name> <email> · <internal_date first 16 chars>\nSubject: <subject>\n<body>".
func mailHeader(fromName, fromEmail, internalDate, subject, body, snippet string) string {
	stamp := internalDate
	if len(stamp) > 16 {
		stamp = stamp[:16]
	}
	if body == "" {
		body = snippet
	}
	return fmt.Sprintf("From %s %s · %s\nSubject: %s\n%s", fromName, fromEmail, stamp, subject, body)
}

// jsonEmails unmarshals a JSON string array; malformed or empty JSON yields nil.
func jsonEmails(raw string) []string {
	var out []string
	_ = json.Unmarshal([]byte(raw), &out)
	return out
}

// addDistinct appends s to list if non-empty and not already present.
func addDistinct(list []string, seen map[string]bool, s string) []string {
	if s == "" || seen[s] {
		return list
	}
	seen[s] = true
	return append(list, s)
}

// gmailSource renders Gmail thread documents (one per thread_id, or a single
// threadless message under "m:<id>").
type gmailSource struct{}

func (gmailSource) Name() string { return "gmail" }

const gmailKeyExpr = `'gmail:' || account_id || ':' || CASE WHEN thread_id = '' THEN 'm:' || id ELSE thread_id END`

func (gmailSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	keys, next, err := changedByColumn(ctx, q, cursor,
		`SELECT `+gmailKeyExpr+`, updated_at FROM gmail_messages WHERE updated_at >= ?`, cursor)
	return keys, next, true, err
}

func (gmailSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT DISTINCT `+gmailKeyExpr+` FROM gmail_messages`)
}

type gmailRow struct {
	id, fromEmail, fromName, toJSON, ccJSON, subject, snippet, bodyText, internalDate, permalink, updatedAt string
}

func loadGmailRows(ctx context.Context, q Queryer, query string, args ...any) ([]gmailRow, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []gmailRow
	for rows.Next() {
		var r gmailRow
		if err := rows.Scan(&r.id, &r.fromEmail, &r.fromName, &r.toJSON, &r.ccJSON, &r.subject, &r.snippet, &r.bodyText, &r.internalDate, &r.permalink, &r.updatedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// gmailThreadQuery and gmailMessageQuery are split so each hits its own
// index: thread_id = ? uses idx_gmail_messages_thread, id = ? uses the
// (account_id, id) primary-key autoindex. A single combined WHERE with an
// expression on the bind param ('m:' || id = ?) defeated both and forced a
// full per-account table scan (SEARCH ... USING INDEX
// sqlite_autoindex_gmail_messages_1 (account_id=?) alone) — see EXPLAIN
// QUERY PLAN in TestGmail_QueryPlan.
const gmailSelectCols = `id, from_email, from_name, to_json, cc_json, subject, snippet, body_text, internal_date, permalink, updated_at`

const gmailThreadQuery = `SELECT ` + gmailSelectCols + `
	FROM gmail_messages WHERE account_id = ? AND thread_id = ?
	ORDER BY internal_date, id`

const gmailMessageQuery = `SELECT ` + gmailSelectCols + `
	FROM gmail_messages WHERE account_id = ? AND id = ?
	ORDER BY internal_date, id`

func (gmailSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	rest, ok := splitRef(key, "gmail:")
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	i := strings.Index(rest, ":")
	if i <= 0 || i == len(rest)-1 {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	accountID, tid := rest[:i], rest[i+1:]

	query, matchArg := gmailThreadQuery, tid
	if id, isMessage := splitRef(tid, "m:"); isMessage {
		query, matchArg = gmailMessageQuery, id
	}
	msgs, err := loadGmailRows(ctx, q, query, accountID, matchArg)
	if err != nil {
		return nil, fmt.Errorf("kb gmail %s: %w", key, err)
	}
	if len(msgs) == 0 {
		return nil, nil
	}

	doc := &Doc{ID: key, Source: "gmail", Anchor: map[string]string{"account_id": accountID, "thread_id": tid}}
	var metaNames []string
	seen := map[string]bool{}
	var latest time.Time
	for _, m := range msgs {
		doc.Sections = append(doc.Sections, Section{
			Text:   mailHeader(m.fromName, m.fromEmail, m.internalDate, m.subject, m.bodyText, m.snippet),
			Anchor: m.id,
		})
		if doc.Title == "" && m.subject != "" {
			doc.Title = m.subject
		}
		if m.permalink != "" {
			doc.Link = m.permalink
		}
		metaNames = addDistinct(metaNames, seen, m.fromName)
		metaNames = addDistinct(metaNames, seen, m.fromEmail)
		for _, e := range jsonEmails(m.toJSON) {
			metaNames = addDistinct(metaNames, seen, e)
		}
		for _, e := range jsonEmails(m.ccJSON) {
			metaNames = addDistinct(metaNames, seen, e)
		}
		t := parseTime(m.internalDate)
		if t.IsZero() {
			t = parseTime(m.updatedAt)
		}
		if t.After(latest) {
			latest = t
		}
	}
	if doc.Title == "" {
		doc.Title = "(no subject)"
	}
	doc.Meta = strings.Join(metaNames, " ")
	doc.Time = latest
	return doc, nil
}

// imapSource renders one document per synced IMAP/Outlook message.
type imapSource struct{}

func (imapSource) Name() string { return "imap" }

const imapKeyExpr = `'imap:' || account_id || ':' || uidvalidity || ':' || uid`

func (imapSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	keys, next, err := changedByColumn(ctx, q, cursor,
		`SELECT `+imapKeyExpr+`, updated_at FROM imap_messages WHERE updated_at >= ?`, cursor)
	return keys, next, true, err
}

func (imapSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT `+imapKeyExpr+` FROM imap_messages`)
}

func (imapSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	rest, ok := splitRef(key, "imap:")
	if !ok {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	parts := strings.SplitN(rest, ":", 3)
	if len(parts) != 3 {
		return nil, nil //nolint:nilerr // malformed ref: treat as missing doc, not an error
	}
	accountID, uidvalidity, uid := parts[0], parts[1], parts[2]

	var fromEmail, fromName, subject, snippet, bodyText, internalDate, permalink, updatedAt string
	err := q.QueryRowContext(ctx, `SELECT from_email, from_name, subject, snippet, body_text, internal_date, permalink, updated_at
		FROM imap_messages WHERE account_id = ? AND uidvalidity = ? AND uid = ?`, accountID, uidvalidity, uid).
		Scan(&fromEmail, &fromName, &subject, &snippet, &bodyText, &internalDate, &permalink, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb imap %s: %w", key, err)
	}

	title := subject
	if title == "" {
		title = "(no subject)"
	}
	t := parseTime(internalDate)
	if t.IsZero() {
		t = parseTime(updatedAt)
	}
	var metaNames []string
	seen := map[string]bool{}
	metaNames = addDistinct(metaNames, seen, fromName)
	metaNames = addDistinct(metaNames, seen, fromEmail)
	return &Doc{
		ID:     key,
		Source: "imap",
		Title:  title,
		Meta:   strings.Join(metaNames, " "),
		Link:   permalink,
		Time:   t,
		Anchor: map[string]string{"account_id": accountID, "uidvalidity": uidvalidity, "uid": uid},
		Sections: []Section{{
			Text:   mailHeader(fromName, fromEmail, internalDate, subject, bodyText, snippet),
			Anchor: uid,
		}},
	}, nil
}
